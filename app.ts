// ...existing code...
// ...existing code...
// ...existing code...

// ...existing code...
// Hourly cron job: send digest emails for requests with no real-time notifications
cron.schedule("5 * * * *", async () => {
  try {
    const { isPublicActionsPaused, logPausedSkip } = await import("./src/publicActionsPause.js");
    // Checked before any query or send so a suppressed digest writes no
    // SendLog at all — a skipped notification must never look delivered.
    if (isPublicActionsPaused()) {
      logPausedSkip("hourly subscriber digest");
      return;
    }
    const { Request: MealRequest, Subscriber, SendLog } = await import("./models/db.js");
    const { sendDigestEmail } = await import("./src/sendDigestEmail.js");
    const { buildEffectiveAvailabilityFilter } = await import("./src/requestAvailability.js");
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);
    const digestNow = new Date();
    // Find requests created in the last hour with no SendLog
    const recentRequests = await MealRequest.find({
      createdAt: { $gte: oneHourAgo },
      ...buildEffectiveAvailabilityFilter(digestNow),
    }).lean();
    const notifiedRequestIds = new Set((await SendLog.find({ requestId: { $in: recentRequests.map(r => r._id) } }).lean()).map(l => String(l.requestId)));
    const unnotified = recentRequests.filter(r => !notifiedRequestIds.has(String(r._id)));
    if (!unnotified.length) return;
    // Find eligible subscribers (under caps)
    const eligible = await Subscriber.find({
      status: "confirmed",
      bounced: false,
      dailyCount: { $lt: 4 },
      $or: [
        { lastSentAt: { $lt: oneHourAgo } },
        { lastSentAt: null },
      ],
    });
    for (const sub of eligible) {
      try {
  await sendDigestEmail(sub, unnotified as any);
        await Subscriber.updateOne(
          { _id: sub._id },
          { $set: { lastSentAt: new Date() }, $inc: { dailyCount: 1 } }
        );
        // Log one SendLog per request for this digest
        for (const req of unnotified) {
          await SendLog.create({
            subscriberId: sub._id,
            requestId: req._id,
            sentAt: new Date(),
            status: "sent",
            error: "digest"
          });
        }
      } catch (err) {
        console.error("[digest] Failed to send to", sub.email, err);
      }
    }
    console.log(`[digest] Sent digest to ${eligible.length} subscribers for ${unnotified.length} requests at ${new Date().toISOString()}`);
  } catch (err) {
    console.error("[digest] Hourly digest job failed:", err);
  }
});
// Daily cron job: reset dailyCount for all confirmed subscribers
cron.schedule("0 3 * * *", async () => {
  try {
    const { Subscriber } = await import("./models/db.js");
    const result = await Subscriber.updateMany({ status: "confirmed" }, { $set: { dailyCount: 0 } });
    console.log(`[cron] Reset dailyCount for ${result.modifiedCount} subscribers at ${new Date().toISOString()}`);
  } catch (err) {
    console.error("[cron] Failed to reset dailyCount:", err);
  }
});

// Monitoring cron: check SendLog.fail spikes and notify operators if configured
cron.schedule("*/10 * * * *", async () => {
  try {
    const { SendLog } = await import("./models/db.js");
    const monitorEmails = (process.env.MONITOR_EMAILS || '').split(',').map(s => s.trim()).filter(Boolean);
    const threshold = parseInt(process.env.MONITOR_THRESHOLD || '10', 10);
    if (!monitorEmails.length) return; // nothing to notify
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);
    const failCount = await SendLog.countDocuments({ status: 'fail', sentAt: { $gte: oneHourAgo } });
    if (failCount >= threshold) {
      try {
        await resend.emails.send({
          from: process.env.FROM_EMAIL || 'CommonPlate <noreply@commonplatenyu.org>',
          to: monitorEmails,
          subject: `CommonPlate alert: ${failCount} failed sends in last hour`,
          html: `<p>Detected ${failCount} failed send attempts in the last hour. Please investigate send logs in the database.</p>`,
        });
        console.log(`[monitor] Alert sent to ${monitorEmails.join(',')} (${failCount} fails)`);
      } catch (err) {
        console.error('[monitor] Failed to send alert email', err);
      }
    }
  } catch (err) {
    console.error('[monitor] Monitor job failed', err);
  }
});
import express, { Request, Response, NextFunction } from "express";
import helmet from "helmet";

import mongoose from "mongoose";
import "dotenv/config";
import path from "path";
import { fileURLToPath } from "url";
import {
  Fulfillment,
  Request as MealRequest,
  Subscriber,
} from "./models/db.js";
import rateLimit from "express-rate-limit";
import cron from "node-cron";
import { Resend } from "resend";
import {
  buildPublicRequestListResponse,
  RequestListDocument,
} from "./src/requestListResponse.js";
import { getPublicRequestDetail } from "./src/requestDetailRoute.js";
import { createRequest } from "./src/createRequestRoute.js";
import {
  FULFILLMENT_ROUTE_PATH,
  fulfillRequest,
  fulfillmentRateLimiter,
} from "./src/fulfillmentRoute.js";
import { assertMongoTransactionsSupported } from "./src/mongoTransactions.js";
import { getStats } from "./src/statsRoute.js";
import {
  CLAIM_EXTENSION_ROUTE_PATH,
  CLAIM_ROUTE_PATH,
  claimExtensionRateLimiter,
  claimRateLimiter,
  claimRequest,
  extendClaim,
  pauseDay4Mutation,
} from "./src/claimRoute.js";
import { readClaimTokenHmacSecret } from "./src/claimToken.js";
import { buildEffectiveAvailabilityFilter } from "./src/requestAvailability.js";
import {
  CREATE_UNAVAILABLE_MESSAGE,
  SUBSCRIBE_UNAVAILABLE_MESSAGE,
  isPublicActionsPaused,
  pausePublicAction,
} from "./src/publicActionsPause.js";

// --- Environment validation (fail fast with clear message) ---
const { MONGO_URI, RESEND_API_KEY } = process.env;
if (!MONGO_URI) {
  console.error("Missing required environment variable: MONGO_URI");
  process.exit(1);
}
if (!RESEND_API_KEY) {
  console.error("Missing required environment variable: RESEND_API_KEY");
  process.exit(1);
}
try {
  readClaimTokenHmacSecret();
} catch (error) {
  console.error(
    error instanceof Error ? error.message : "Invalid claim-token HMAC secret"
  );
  process.exit(1);
}

// init Resend (email API)
const resendApiKey = process.env.RESEND_API_KEY;
const resend = new Resend(resendApiKey);

// init express
const app = express();
// Security headers
app.use(helmet());
// If the app is running behind a proxy (Render, Heroku, etc.) we should
// enable Express's `trust proxy` so middleware like express-rate-limit can
// correctly identify the client's IP from the X-Forwarded-For header.
// Control via env var TRUST_PROXY (set to '1' or 'true'). Default: enable
// in production environments.
const trustProxyEnv = (process.env.TRUST_PROXY || '').toLowerCase();
if (trustProxyEnv === '1' || trustProxyEnv === 'true' || process.env.NODE_ENV === 'production') {
  app.set('trust proxy', 1);
  console.log('[config] express trust proxy = 1');
}
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// middleware to parse JSON and serve static files
app.use(express.json({ limit: '100kb' }));
app.use(express.urlencoded({ extended: true, limit: '100kb' }));
app.use(express.static(path.join(process.cwd(), "public")));

// rate limiting middleware - apply only to form endpoints
const limiter = rateLimit({ windowMs: 60_000, max: 5 }); // up to 5/min/IP

// health check
app.get("/health", (req: Request, res: Response) => res.send("ok"));

// serve home page
app.get("/", (req: Request, res: Response) => {
  res.sendFile(path.join(process.cwd(), "public", "home.html"));
});

// serve new request form
app.get("/request/new", (req: Request, res: Response) => {
  res.sendFile(path.join(process.cwd(), "public", "new-request.html"));
});

// Read-only pause state for the web pages, which cannot read server
// environment values. Carries no configuration detail beyond the decision
// itself; the pages fail closed if this request does not succeed.
app.get("/api/public-actions", (req: Request, res: Response) => {
  res.json({ paused: isPublicActionsPaused() });
});

// api: subscribe to digest emails (creates a pending Subscriber and sends confirmation)
// The pause runs ahead of the limiter so no subscriber is created or confirmed,
// no confirmation email is sent, and no recent-request alerts are dispatched.
app.post('/api/subscribe', pausePublicAction(SUBSCRIBE_UNAVAILABLE_MESSAGE), limiter, async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { email } = req.body || {};
    if (!email || typeof email !== 'string') return res.status(400).json({ error: 'missing email' });

    const normalized = String(email).trim().toLowerCase();

    // simple local validation (require an @ sign)
    if (!normalized.includes('@')) return res.status(400).json({ error: 'invalid email' });

    // generate a lightweight confirm token
    const token = new mongoose.Types.ObjectId().toString();

    // upsert a pending subscriber
    const sub = await Subscriber.findOneAndUpdate(
      { email: normalized },
      { $set: { email: normalized, status: 'pending', confirmToken: token, bounced: false } , $setOnInsert: { dailyCount: 0 } },
      { upsert: true, new: true }
    );

    // send confirmation email (non-blocking failures will still return 200 to avoid UX breakage)
    try {
      const requestBase = req.protocol + '://' + req.get('host');
      const BASE_URL = process.env.BASE_URL || requestBase;
      const confirmUrl = `${BASE_URL}/api/subscribe/confirm?token=${encodeURIComponent(token)}`;
      await resend.emails.send({
        from: 'CommonPlate <noreply@commonplatenyu.org>',
        to: normalized,
        subject: 'Confirm your CommonPlate subscription',
        html: `<p>Please confirm your subscription to CommonPlate alerts by clicking the link below:</p><p><a href="${confirmUrl}">${confirmUrl}</a></p><p>If you didn't request this, you can ignore this email.</p>`,
      });
    } catch (emailErr) {
      console.error('[email] Subscribe confirmation send failed:', emailErr);
    }
    if (!sub) return res.status(404).send('token not found');
  sub.status = 'confirmed';
  sub.confirmToken = undefined as any;
  // ensure unsubToken exists (schema requires unsubToken when status is 'confirmed')
  if (!sub.unsubToken) sub.unsubToken = new mongoose.Types.ObjectId().toString();
  await sub.save();
    // Fire-and-forget: notify this newly-confirmed subscriber about recent open requests
    (async () => {
      try {
        const { notifySubscriberAboutRecentRequests } = await import("./src/notifySubscribers.js");
        await notifySubscriberAboutRecentRequests(sub as any);
      } catch (err) {
        console.error('[notify] notify-on-confirm failed', err);
      }
    })();

    // respond with a tiny confirmation page
    res.send(`<html><body><h3>Subscription confirmed</h3><p>Thanks — you'll receive alerts from CommonPlate.</p></body></html>`);
  } catch (err) {
    next(err);
  }
});

// serve fulfill page for a specific request
app.get("/request/:id/fulfill", (req: Request, res: Response) => {
  res.sendFile(path.join(process.cwd(), "public", "fulfill.html"));
});

// Admin: send a test fulfillment email to fcw2020@nyu.edu
// Protected by ADMIN_TOKEN env var (use header 'x-admin-token'). If ADMIN_TOKEN is
// not set and NODE_ENV === 'production' the endpoint is disabled.
app.post('/admin/test-fulfillment', async (req: Request, res: Response) => {
  try {
    const token = (req.get('x-admin-token') || '').toString();
    if (process.env.ADMIN_TOKEN) {
      if (!token || token !== process.env.ADMIN_TOKEN) return res.status(403).json({ error: 'Forbidden' });
    } else if (process.env.NODE_ENV === 'production') {
      return res.status(503).json({ error: 'Admin token not configured' });
    }

    const { sendFulfillmentEmail } = await import('./src/emailHelpers.js');
    const testRequest = {
      _id: new mongoose.Types.ObjectId(),
      vendor: 'Test Vendor',
      pickupName: 'Test Pickup',
      pickupWindowText: 'ASAP (test)',
      email: 'fcw2020@nyu.edu',
    } as any;

    await sendFulfillmentEmail(testRequest, 'TEST26', '15 minutes', 'Test message from admin tester', 'donor@example.org');
    res.json({ ok: true });
  } catch (err) {
    console.error('[admin] test-fulfillment failed', err);
    res.status(500).json({ error: 'failed' });
  }
});

// api: get all active requests
app.get("/api/requests", async (req: Request, res: Response, next: NextFunction) => {
  try {
    // Fetch available requests and order them by timing:
    // - ASAP items (no windowStart or windowStart within next hour) come first, ordered by createdAt ascending (earliest first)
    // - Scheduled items come after, ordered by windowStart ascending
    const now = new Date();
    const docs = await MealRequest.find(buildEffectiveAvailabilityFilter(now))
      .limit(200)
      .lean()
      .exec();

    res.json(
      buildPublicRequestListResponse(
        docs as unknown as RequestListDocument[],
        now
      )
    );
  } catch (err) {
    next(err);
  }
});

// api: get single request by id
app.get("/api/request/:id", getPublicRequestDetail);

// api: get stats (total meals shared)
app.get("/api/stats", getStats);

// api: get count of active (confirmed, not bounced) subscribers
app.get("/api/active-subscriber-count", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const count = await Subscriber.countDocuments({ status: "confirmed", bounced: false });
    res.json({ count });
  } catch (err) {
    next(err);
  }
});

// api: create a new meal request
// The pause runs ahead of the limiter and the handler so a paused create
// performs no validation side effect, sends no confirmation email, writes no
// request, and notifies no subscribers. Nobody may post a meal that nobody
// can fulfill while the fulfillment path is unavailable.
app.post("/api/request", pausePublicAction(CREATE_UNAVAILABLE_MESSAGE, "PUBLIC_ACTIONS_PAUSED"), limiter, createRequest);

// Claim mutations are paused before their independent rate-limit buckets and
// before token generation or database work.
app.post(
  CLAIM_ROUTE_PATH,
  pauseDay4Mutation,
  claimRateLimiter,
  claimRequest
);
app.post(
  CLAIM_EXTENSION_ROUTE_PATH,
  pauseDay4Mutation,
  claimExtensionRateLimiter,
  extendClaim
);

// A valid active claim is the only authorization for placement. This route is
// intentionally not exposed through the disabled legacy web ordering UI.
app.post(
  FULFILLMENT_ROUTE_PATH,
  fulfillmentRateLimiter,
  fulfillRequest
);


// ---- node-cron: cleanup expired documents (backup to TTL) ----
// Runs every hour to delete expired requests
if (process.env.CRON_ENABLED === 'true') {
  cron.schedule("0 * * * *", async () => {
    try {
      const now = new Date();
      const result = await MealRequest.deleteMany({ deleteAt: { $lte: now } });
      console.log(`[cron] Deleted ${result.deletedCount} expired requests at ${now.toISOString()}`);
    } catch (err) {
      console.error("[cron] Cleanup failed:", err);
    }
  });
} else {
  console.log('[cron] disabled — set CRON_ENABLED=true to enable scheduled cleanup');
}

// ---- error handler (must be last) ----
app.use((err: Error, req: Request, res: Response, _next: NextFunction) => {
  console.error("Error:", err);
  res.status(500).json({ error: "Internal server error" });
});

// connect to db and start server
await mongoose.connect(MONGO_URI);
await assertMongoTransactionsSupported(mongoose.connection);
// Do not accept placement traffic until the database has established the
// one-request/one-ledger-record uniqueness guarantee. Existing duplicates make
// this fail visibly at startup instead of weakening the contract.
await Fulfillment.createIndexes();
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  const PUBLIC_BASE = process.env.BASE_URL || `http://localhost:${PORT}`;
  console.log(PUBLIC_BASE);
});
