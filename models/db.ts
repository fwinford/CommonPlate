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
export interface IRequest extends Document {
  vendor: string;
  food: string;
  pickupName: string;
  pickupWindowText: string;
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
  expiresAt?: Date;
  deleteAt?: Date;
  claimedAt?: Date;
  claimExpiresAt?: Date;
  claimExtendedAt?: Date | null;
  claimTokenDigest?: string;
  installationId?: Types.ObjectId | null;
  createdAt: Date;
  updatedAt: Date;
}

const RequestSchema = new Schema<IRequest>({
  vendor: { type: String, required: true, trim: true },
  food: { type: String, required: true, trim: true },
  pickupName: { type: String, required: true, trim: true },
  pickupWindowText: { type: String, required: true, trim: true },
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
