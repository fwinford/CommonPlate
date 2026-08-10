// System model for key/value store (e.g. round-robin cursor)
export interface ISystem extends Document {
  key: string;
  value: any;
}

const SystemSchema = new Schema<ISystem>({
  key: { type: String, required: true, unique: true },
  value: { type: Schema.Types.Mixed, required: true },
});

export const System = mongoose.models.System || mongoose.model<ISystem>("System", SystemSchema);
// db.ts
// Mongoose schemas for CommonPlate
// - Request: meal requests (TTL-deleted at private `deleteAt`)
// - Fulfillment: log when an order is placed

import mongoose, { Schema, Document, Types } from "mongoose";
import {
  INITIAL_PARTICIPANT_AUTHORITY_VERSION,
  MAXIMUM_PARTICIPANT_AUTHORITY_VERSION,
} from "../src/participantCredentials.js";
import {
  INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION,
  MAXIMUM_UNSUBSCRIBE_CREDENTIAL_VERSION,
} from "../src/unsubscribeCredential.js";

// Subscriber model
export interface ISubscriber extends Document {
  email: string;
  status: "pending" | "confirmed" | "unsubscribed";
  confirmationTokenDigest?: string;
  confirmationExpiresAt?: Date;
  confirmationSendAttemptId?: string;
  confirmationSendAttemptAt?: Date;
  lastConfirmedTokenDigest?: string;
  lastConfirmedTokenExpiresAt?: Date;
  unsubscribeCredentialVersion?: number;
  unsubscribedAt?: Date;
  // Legacy raw-token fields remain readable for exact rollback of old rows.
  confirmToken?: string;
  unsubToken?: string;
  lastSentAt?: Date;
  dailyCount: number;
  bounced: boolean;
}

const SubscriberSchema = new Schema<ISubscriber>({
  email: { type: String, required: true, unique: true, trim: true, lowercase: true },
  status: { type: String, enum: ["pending", "confirmed", "unsubscribed"], default: "pending" },
  confirmationTokenDigest: {
    type: String,
    required: function(this: ISubscriber) { return this.status === "pending"; },
    select: false,
  },
  confirmationExpiresAt: {
    type: Date,
    required: function(this: ISubscriber) { return this.status === "pending"; },
    select: false,
  },
  // This private owner serializes rotation with provider submission. It is
  // cleared after success and removed by digest-matched compensation on error.
  // Its timestamp bounds the claim: an attempt that dies mid-flight leaves the
  // owner behind, so ownership is honoured only inside a short lease and the
  // lifecycle stays recoverable instead of becoming permanently unconfirmable.
  confirmationSendAttemptId: { type: String, select: false },
  confirmationSendAttemptAt: { type: Date, select: false },
  // Receipt of the confirmation token that won the transition, kept only until
  // that token's original expiry. Reopening the same confirmation link is
  // ordinary user behaviour, so the redeemed digest must stay recognisable for
  // an idempotent success instead of degrading into an invalid-token answer.
  lastConfirmedTokenDigest: { type: String, select: false },
  lastConfirmedTokenExpiresAt: { type: Date, select: false },
  // The revocation counter behind the emailed unsubscribe link. No unsubscribe
  // credential is stored: it is signed on demand from `_id` and this version,
  // so every subscriber holds a revocable credential by construction and an
  // issued link stays valid until this number moves. Signup and confirmation
  // must never touch it, or an old emailed link would stop working.
  unsubscribeCredentialVersion: {
    type: Number,
    default: INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION,
    min: INITIAL_UNSUBSCRIBE_CREDENTIAL_VERSION,
    max: MAXIMUM_UNSUBSCRIBE_CREDENTIAL_VERSION,
    validate: {
      validator: Number.isInteger,
      message: "unsubscribeCredentialVersion must be an integer",
    },
  },
  unsubscribedAt: { type: Date },
  confirmToken: { type: String, select: false },
  // Legacy raw credential from pre-digest rows. Nothing issues or requires
  // one — the current unsubscribe credential is derived, never stored — so it
  // stays out of ordinary projections like every other private credential
  // field. Existing values are left in place; confirmation still clears the
  // field when it transitions a row that carries one.
  unsubToken: { type: String, select: false },
  lastSentAt: { type: Date, default: null },
  dailyCount: { type: Number, default: 0 },
  bounced: { type: Boolean, default: false },
});

export const Subscriber = mongoose.models.Subscriber || mongoose.model<ISubscriber>("Subscriber", SubscriberSchema);

// Notification delivery ledger and duplicate-send guard.
export interface ISendLog extends Document {
  subscriberId: Types.ObjectId;
  requestId?: Types.ObjectId;
  sentAt: Date;
  status: "sent" | "fail";
  error?: string;
}

const SendLogSchema = new Schema<ISendLog>({
  subscriberId: { type: Schema.Types.ObjectId, ref: "Subscriber", required: true },
  requestId: { type: Schema.Types.ObjectId, ref: "Request" },
  sentAt: { type: Date, default: Date.now },
  status: { type: String, enum: ["sent", "fail"], required: true },
  error: { type: String },
});

// Prevent duplicate SendLog entries for the same request+subscriber pair.
// This also enables an atomic 'claim' pattern where a process inserts a
// pending log before sending and updates it after the send completes.
SendLogSchema.index({ requestId: 1, subscriberId: 1 }, { unique: true });

export const SendLog = mongoose.models.SendLog || mongoose.model<ISendLog>("SendLog", SendLogSchema);


// ========================== Installation ============================
// One record per app installation that has ever synchronized push state
// (Week 3 Day 6 Slice 6A.1). Deliberately separate from Subscriber: an
// installation identity is not a person, account, or email address, and
// email delivery must stay wholly independent of push delivery.
export interface IInstallation extends Document {
  installationCredentialDigest: string;
  pushEnabled: boolean;
  apnsToken?: string | null;
  apnsEnvironment?: "development" | "production" | null;
  tokenUpdatedAt?: Date | null;
  invalidatedAt?: Date | null;
  createdAt: Date;
  updatedAt: Date;
}

const InstallationSchema = new Schema<IInstallation>(
  {
    // SHA-256 digest of the opaque credential the app generates for itself.
    // Only the digest is ever persisted; the raw credential is never stored
    // or logged.
    installationCredentialDigest: {
      type: String,
      required: true,
      unique: true,
      select: false,
    },
    pushEnabled: { type: Boolean, required: true, default: false },
    // Left set (not cleared) when push is turned off, so a later
    // provider-invalidation notice for this exact token can still recognize
    // it as this installation's current token. See the Slice 6A APNs
    // invalidation boundary in the Week 3 spec.
    apnsToken: { type: String, select: false },
    apnsEnvironment: { type: String, enum: ["development", "production"] },
    tokenUpdatedAt: { type: Date },
    invalidatedAt: { type: Date },
  },
  { timestamps: true }
);

// At most one installation may be the eligible current owner of a given APNs
// token in a given environment. Enforced with a partial unique index, not a
// read-then-write check, so two installations registering the same token at
// once cannot both end up eligible: MongoDB itself rejects the second write,
// and the route demotes the prior owner and retries.
InstallationSchema.index(
  { apnsToken: 1, apnsEnvironment: 1 },
  {
    unique: true,
    partialFilterExpression: {
      pushEnabled: true,
      apnsToken: { $type: "string" },
    },
    name: "installation_push_eligible_token_unique",
  }
);

export const Installation =
  (mongoose.models.Installation as mongoose.Model<IInstallation>) ||
  mongoose.model<IInstallation>("Installation", InstallationSchema);


// ============================ Request =============================
/**
 * Which path owns starting this request's helper new-request notification, and
 * whether that has happened yet (W3-N3). The product event that initiates
 * helper notification is *the request becoming helper-eligible*, which for an
 * ASAP request is its creation instant and for a future Later request is its
 * `visibleFrom` — an instant that can arrive hours after `createdAt`.
 *
 * - `"initiated"`: helper email and push dispatch have been started for this
 *   request. Nothing may start them again.
 * - `"awaiting-eligibility"`: the request was not helper-eligible when it was
 *   created, so creation-time dispatch deliberately did nothing and the
 *   eligibility sweep (`src/eligibilityNotificationSweep.ts`) owns it.
 *
 * Absent is a third, deliberate state: rows persisted before this field existed
 * were dispatched for (or not) at creation exactly as they always were, and the
 * sweep never selects them. Nothing migrates them, for the same reason nothing
 * migrates `visibleFrom`.
 */
export type HelperNotificationState = "awaiting-eligibility" | "initiated";

export interface IRequest extends Document {
  vendor: string;
  food: string;
  pickupName: string;
  pickupWindowText: string;
  /**
   * V1 meal-swipe requirement (W3-C1): the exact integer count of meal swipes
   * this request needs, 1 through 5. Requester-owned truth, required by every
   * accepted `POST /api/request` shape (enforced in `createRequestRoute.ts`,
   * the authoritative validator) and written once at creation, never
   * recomputed or defaulted. Not `required` at the schema level so that
   * fixtures and Mongo suites unrelated to this slice, across many
   * pre-existing Request documents and test files, are not forced to supply
   * it; existing database contents are disposable test data, not a migration
   * target.
   */
  mealSwipes?: number;
  email: string;
  windowStart?: Date;
  windowEnd?: Date;
  status: "open" | "claimed" | "placed";
  orderNumber?: string;
  eta?: Date;
  etaText?: string;
  placedAt?: Date;
  fulfillerEmail?: string;
  contactMessage?: string;
  notificationStatus?: "pending" | "sent" | "failed";
  notificationAttemptedAt?: Date;
  visibleFrom?: Date;
  helperNotification?: HelperNotificationState;
  expiresAt?: Date;
  deleteAt?: Date;
  claimedAt?: Date;
  claimExpiresAt?: Date;
  claimExtendedAt?: Date | null;
  claimTokenDigest?: string;
  installationId?: Types.ObjectId | null;
  requesterParticipantId?: Types.ObjectId | null;
  helperParticipantId?: Types.ObjectId | null;
  createdAt: Date;
  updatedAt: Date;
}

const RequestSchema = new Schema<IRequest>({
  vendor: { type: String, required: true, trim: true },
  food: { type: String, required: true, trim: true },
  pickupName: { type: String, required: true, trim: true },
  pickupWindowText: { type: String, required: true, trim: true },
  mealSwipes: {
    type: Number,
    min: 1,
    max: 5,
    validate: {
      validator: Number.isInteger,
      message: "mealSwipes must be an integer",
    },
  },
  email: { type: String, required: true, trim: true, lowercase: true },
  windowStart: { type: Date },
  windowEnd: { type: Date },
  status: {
    type: String,
    enum: ["open", "claimed", "placed"],
    default: "open",
  },
  orderNumber: { type: String, trim: true },
  eta: { type: Date },
  etaText: { type: String, trim: true },
  placedAt: { type: Date },
  fulfillerEmail: { type: String, trim: true, lowercase: true },
  contactMessage: { type: String, trim: true },
  notificationStatus: {
    type: String,
    enum: ["pending", "sent", "failed"],
  },
  notificationAttemptedAt: { type: Date },
  // When helpers begin seeing this request: the backend creation instant for
  // ASAP, the accepted scheduled start for Later. Written explicitly at
  // creation and never by a client. Requests persisted before this field
  // existed carry no value, and availability treats that absence as "visible
  // from creation" rather than migrating them.
  visibleFrom: { type: Date },
  // Written explicitly at creation from the same visibility rule the
  // dispatchers apply, and never by a client. Internal lifecycle bookkeeping
  // like `notificationStatus`, kept out of responses by the allowlisted public
  // projection rather than by a projection default. See
  // `HelperNotificationState` above. No schema default: an absent value is the
  // legacy meaning, not a new request's meaning.
  helperNotification: {
    type: String,
    enum: ["awaiting-eligibility", "initiated"],
  },
  expiresAt: { type: Date },
  deleteAt: {
    type: Date,
    index: {
      expireAfterSeconds: 0,
      name: "request_deleteAt_ttl",
    },
  },
  claimedAt: { type: Date },
  claimExpiresAt: { type: Date },
  claimExtendedAt: { type: Date, default: null },
  claimTokenDigest: { type: String, select: false },
  // The originating app installation, when the request was created from iOS
  // with an installation credential (Week 3 Day 6 Slice 6E). Notification-
  // routing identity only — never a person, account, or auth identity — and
  // never exposed through any public projection, so it stays out of ordinary
  // reads like every other private lifecycle field.
  installationId: { type: Schema.Types.ObjectId, ref: "Installation", select: false },
  // The verified participant who created this request (W3-I1). Written from
  // backend-resolved participant authority, never from the payload, and paired
  // with `email`, which is written from the same principal in the same call.
  // Person identity, unlike `installationId` above — which is notification
  // routing and nothing else — so it is `select: false` like every other
  // private field and never reaches a public projection.
  requesterParticipantId: {
    type: Schema.Types.ObjectId,
    ref: "Participant",
    select: false,
  },
  // The verified participant holding the current reservation (W3-I1). Written
  // by the claim mutation from resolved participant authority and retained
  // through placement, because it is who actually placed the order: fulfillment
  // derives `fulfillerEmail` from this binding instead of accepting a helper
  // address from the caller.
  helperParticipantId: {
    type: Schema.Types.ObjectId,
    ref: "Participant",
    select: false,
  },
}, { timestamps: true });

// `expiresAt` is the availability deadline; `deleteAt` owns physical retention.
// They match until placement, after which fulfillment moves only `deleteAt` to
// the placed-request retention deadline.
RequestSchema.pre("save", function (next) {
  if (!this.expiresAt) {
    const dayMs = 24 * 60 * 60 * 1000;
    this.expiresAt = new Date(Date.now() + dayMs);
  }
  if (this.status !== "placed" && !this.deleteAt) {
    this.deleteAt = this.expiresAt;
  }
  next();
});

// Index to support fast per-email daily count queries
RequestSchema.index({ email: 1, createdAt: 1 });

// The eligibility sweep's candidate set: requests whose helper notification has
// not been initiated yet, ordered by the instant it becomes due. Partial on the
// awaiting state, so the index holds only the future Later requests still
// waiting — never the ASAP requests that are the overwhelming majority — and
// disappears from it the moment one is initiated or TTL-deleted.
//
// This is a selection index, not a correctness guarantee: exactly-once
// initiation comes from the conditional update the sweep writes, not from here.
RequestSchema.index(
  { visibleFrom: 1 },
  {
    name: "request_helper_notification_awaiting",
    partialFilterExpression: { helperNotification: "awaiting-eligibility" },
  }
);

// Supports W3-H1 continuation: "does this verified participant currently hold
// an active reservation, and which request". Partial on `status: "claimed"`
// for the same reason as the index above — only the requests this lookup can
// ever match belong in it.
RequestSchema.index(
  { helperParticipantId: 1, status: 1 },
  {
    name: "request_helper_active_reservation",
    partialFilterExpression: { status: "claimed" },
  }
);

/* ============================ Fulfillment ============================= */
export interface IFulfillment extends Document {
  requestId: mongoose.Types.ObjectId;
  orderNumber: string;
  eta?: Date;
  etaText?: string;
  note?: string;
  placedAt: Date;
  createdAt: Date;
  updatedAt: Date;
}

const FulfillmentSchema = new Schema<IFulfillment>(
  {
    requestId: { type: Schema.Types.ObjectId, ref: "Request", required: true },
    orderNumber: { type: String, trim: true, required: true },
    eta: { type: Date },
    etaText: { type: String, trim: true },
  note: { type: String, trim: true },
    placedAt: { type: Date, default: Date.now },
  },
  { timestamps: true }
);

// The durable fulfillment record is the all-time counting ledger. The Request
// transition and this insert commit in one transaction, while this index is the
// final database-level guard against counting one request more than once.
FulfillmentSchema.index(
  { requestId: 1 },
  { unique: true, name: "fulfillment_request_unique" }
);


/* ================================ Export ============================== */
// Guard against OverwriteModelError in development

export const Request = 
  (mongoose.models.Request as mongoose.Model<IRequest>) || 
  mongoose.model<IRequest>("Request", RequestSchema);

export const Fulfillment = 
  (mongoose.models.Fulfillment as mongoose.Model<IFulfillment>) || 
  mongoose.model<IFulfillment>("Fulfillment", FulfillmentSchema);


/* =========================== PushDelivery ============================ */
// One row per intentional APNs submission for a (request, installation,
// purpose) triple (Week 3 Day 6 Slice 6D). Deliberately not `SendLog`: that
// collection requires a `subscriberId` and is uniquely indexed on
// (requestId, subscriberId), so push rows would need a subscriber that does
// not exist, and it would entangle the two channels this contract requires to
// fail independently.
//
// `"requester-fulfillment"` (Slice 6E) shares this same collection and unique
// index rather than widening it — the collection was shaped for exactly this
// from the start (see `purpose` below).
export type PushDeliveryPurpose = "helper-new-request" | "requester-fulfillment";
export type PushDeliveryStatus = "claimed" | "accepted" | "rejected" | "failed";

export interface IPushDelivery extends Document {
  installationId: Types.ObjectId;
  requestId: Types.ObjectId;
  purpose: PushDeliveryPurpose;
  status: PushDeliveryStatus;
  submittedAt?: Date | null;
  apnsId?: string | null;
  deleteAt: Date;
  createdAt: Date;
  updatedAt: Date;
}

const PushDeliverySchema = new Schema<IPushDelivery>(
  {
    installationId: {
      type: Schema.Types.ObjectId,
      ref: "Installation",
      required: true,
    },
    requestId: { type: Schema.Types.ObjectId, ref: "Request", required: true },
    // Present from the start so a later requester-fulfillment purpose shares
    // this collection without widening the uniqueness key afterwards.
    purpose: {
      type: String,
      enum: ["helper-new-request", "requester-fulfillment"],
      required: true,
    },
    // `status: "accepted"` means exactly "APNs returned 200 for this
    // submission". It is never delivery, display, opening, or reading.
    status: {
      type: String,
      enum: ["claimed", "accepted", "rejected", "failed"],
      required: true,
      default: "claimed",
    },
    submittedAt: { type: Date },
    apnsId: { type: String },
    // TTL. Set to the request's expiration plus a day, so the duplicate guard
    // outlives every window in which a second dispatch is plausible and
    // nothing accumulates indefinitely.
    deleteAt: {
      type: Date,
      required: true,
      index: {
        expireAfterSeconds: 0,
        name: "push_delivery_deleteAt_ttl",
      },
    },
  },
  { timestamps: true }
);

// Claim-before-submit: the dispatcher inserts a `claimed` row and treats a
// duplicate-key error as "another dispatch owns this triple". A row in ANY
// state blocks a second submission — unlike SendLog, which permits a retry
// after a failure — because V1 has no push retry path, so a `failed` or
// `rejected` row is terminal and re-submitting would be a duplicate rather
// than a recovery.
PushDeliverySchema.index(
  { requestId: 1, installationId: 1, purpose: 1 },
  { unique: true, name: "push_delivery_identity_unique" }
);

export const PushDelivery =
  (mongoose.models.PushDelivery as mongoose.Model<IPushDelivery>) ||
  mongoose.model<IPushDelivery>("PushDelivery", PushDeliverySchema);


/* ============================ Participant ============================= */
// One record per NYU address that has proved control of its mailbox (W3-I1).
//
// Deliberately separate from Subscriber and from Installation, and not derived
// from either. A Subscriber is an address that asked for alerts — its whole
// lifecycle is about delivery consent and it is never proof of anything. An
// Installation is a copy of the app — notification-routing identity, replaced
// by a reinstall, and never a person. A Participant is the one thing neither of
// them is: a human who demonstrated they can read mail at an allowed NYU
// address, and therefore the only identity a request or a reservation may be
// bound to.
//
// This still verifies control of an eligible NYU-domain address. It is not
// authentication, not NetID, and not proof of enrollment, and two addresses
// belonging to one human remain two participants.
export interface IParticipant extends Document {
  email: string;
  authorityVersion: number;
  verifiedAt: Date;
  activeReservationRequestId?: Types.ObjectId | null;
  activeReservationClaimExpiresAt?: Date | null;
  createdAt: Date;
  updatedAt: Date;
}

const ParticipantSchema = new Schema<IParticipant>(
  {
    // The principal itself: the exact normalized verified address. Unique, so
    // one address is one participant no matter how many times it verifies.
    email: {
      type: String,
      required: true,
      unique: true,
      trim: true,
      lowercase: true,
    },
    // The revocation lever behind every issued authority credential. No
    // credential is stored: it is signed on demand from `_id` and this number,
    // so raising it invalidates every credential already on every device that
    // holds this identity, and nothing else does.
    authorityVersion: {
      type: Number,
      required: true,
      default: INITIAL_PARTICIPANT_AUTHORITY_VERSION,
      min: INITIAL_PARTICIPANT_AUTHORITY_VERSION,
      max: MAXIMUM_PARTICIPANT_AUTHORITY_VERSION,
      validate: {
        validator: Number.isInteger,
        message: "authorityVersion must be an integer",
      },
    },
    // The most recent successful verification. History, not authority: it never
    // expires the identity, because the accepted contract has no routine
    // periodic reverification while usable authority remains.
    verifiedAt: { type: Date, required: true },
    // The one-active-reservation-per-verified-helper lock (W3-H1). Not
    // participant-facing state — `select: false` like every other private
    // field — and deliberately kept on this single, already-unique-by-`_id`
    // document rather than a new collection: MongoDB's per-document write
    // conflict detection is what makes the claim transaction's conditional
    // update here safe against two concurrent claims by the same principal on
    // two *different* Request documents, which a cross-collection query alone
    // could not serialize. Absence (from a Participant that predates this
    // field, or one that has never held a reservation) matches a `null`
    // query the same way every other legacy-absent field in this file does.
    // `activeReservationClaimExpiresAt` in the past means the lock is stale
    // and does not block a new reservation, without any explicit cleanup step
    // — the same passive-expiry meaning `claimExpiresAt` already carries on
    // `Request`.
    activeReservationRequestId: {
      type: Schema.Types.ObjectId,
      ref: "Request",
      select: false,
      default: null,
    },
    activeReservationClaimExpiresAt: {
      type: Date,
      select: false,
      default: null,
    },
  },
  { timestamps: true }
);

export const Participant =
  (mongoose.models.Participant as mongoose.Model<IParticipant>) ||
  mongoose.model<IParticipant>("Participant", ParticipantSchema);


/* ====================== ParticipantVerification ======================= */
// The live emailed-code challenge for one address (W3-I1). At most one exists
// per address at a time — that is what makes a resend *supersede* the previous
// code rather than leave two working codes in two inboxes — and it is enforced
// by the unique index below, not by reading first and deciding.
export interface IParticipantVerification extends Document {
  email: string;
  codeDigest: string;
  issuedAt: Date;
  expiresAt: Date;
  attemptsRemaining: number;
  redeemedAt?: Date | null;
  deleteAt: Date;
  createdAt: Date;
  updatedAt: Date;
}

const ParticipantVerificationSchema = new Schema<IParticipantVerification>(
  {
    email: {
      type: String,
      required: true,
      unique: true,
      trim: true,
      lowercase: true,
    },
    // HMAC-SHA256 of the emailed code, keyed by the participant signing secret
    // and bound to this address (`src/participantCredentials.ts`). The raw code
    // exists only in the email; nothing persists or logs it, and `select: false`
    // keeps the digest out of ordinary reads like every other credential field.
    codeDigest: { type: String, required: true, select: false },
    // When this challenge was issued. The resend cooldown is measured from it,
    // so a supersede cannot be used to mail an address repeatedly.
    issuedAt: { type: Date, required: true },
    expiresAt: { type: Date, required: true },
    // Counts down on each wrong code, by conditional atomic decrement, so
    // concurrent guesses cannot both spend the same remaining attempt.
    attemptsRemaining: { type: Number, required: true, min: 0 },
    // Set by the one mutation that wins redemption. The row survives to its
    // original expiry afterwards so a duplicate submission of the same code —
    // a double tap, a retried request — is answered as the success it already
    // was rather than as an invalid code.
    redeemedAt: { type: Date },
    // TTL. Set past `expiresAt`, so a spent or lapsed challenge stops being
    // matchable long before it stops existing, and nothing accumulates.
    deleteAt: {
      type: Date,
      required: true,
      index: {
        expireAfterSeconds: 0,
        name: "participant_verification_deleteAt_ttl",
      },
    },
  },
  { timestamps: true }
);

export const ParticipantVerification =
  (mongoose.models.ParticipantVerification as mongoose.Model<IParticipantVerification>) ||
  mongoose.model<IParticipantVerification>(
    "ParticipantVerification",
    ParticipantVerificationSchema
  );
