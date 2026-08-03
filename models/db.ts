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
  unsubscribeTokenDigest?: string;
  unsubscribedAt?: Date;
  // Legacy raw-token fields remain readable for exact rollback of old rows.
  confirmToken?: string;
  unsubToken?: string;
  lastSentAt?: Date;
  dailyCount: number;
  bounced: boolean;
}

// The stored unsubscribe credential is a SHA-256 hex digest.
const UNSUBSCRIBE_TOKEN_DIGEST_PATTERN = /^[a-f0-9]{64}$/;

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
  unsubscribeTokenDigest: {
    type: String,
    select: false,
    match: [
      UNSUBSCRIBE_TOKEN_DIGEST_PATTERN,
      "unsubscribeTokenDigest must be a 64-character lowercase hexadecimal SHA-256 digest",
    ],
  },
  unsubscribedAt: { type: Date },
  confirmToken: { type: String, select: false },
  // A confirmed subscriber must hold a revocable unsubscribe credential.
  // Legacy confirmed rows carry a raw `unsubToken`; rows confirmed by the
  // digest lifecycle carry a well-formed `unsubscribeTokenDigest` and never
  // persist a raw one. A malformed digest is not a credential, so it does not
  // satisfy the invariant on its own.
  unsubToken: { type: String, required: function(this: ISubscriber) { return this.status === "confirmed" && !UNSUBSCRIBE_TOKEN_DIGEST_PATTERN.test(this.unsubscribeTokenDigest ?? ""); } },
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
