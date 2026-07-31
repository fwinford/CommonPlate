// (removed unused helper) Use `Subscriber.countDocuments({ status: "confirmed", bounced: false })`
// directly where needed (keeps a single canonical implementation in the route layer).
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
  confirmToken?: string;
  unsubToken?: string;
  lastSentAt?: Date;
  dailyCount: number;
  bounced: boolean;
}

const SubscriberSchema = new Schema<ISubscriber>({
  email: { type: String, required: true, unique: true, trim: true, lowercase: true },
  status: { type: String, enum: ["pending", "confirmed", "unsubscribed"], default: "pending" },
  confirmToken: { type: String, required: function(this: ISubscriber) { return this.status === "pending"; } },
  unsubToken: { type: String, required: function(this: ISubscriber) { return this.status === "confirmed"; } },
  lastSentAt: { type: Date, default: null },
  dailyCount: { type: Number, default: 0 },
  bounced: { type: Boolean, default: false },
});

export const Subscriber = mongoose.models.Subscriber || mongoose.model<ISubscriber>("Subscriber", SubscriberSchema);

// SendLog model (optional, for debugging)
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

// `expiresAt` is the availability deadline. `deleteAt` is private retention
// state and owns physical TTL deletion. For every unplaced request both values
// are identical. Day 5 may move only `deleteAt` when placement is authoritative.
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
