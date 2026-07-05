// ...existing code...
// ...existing code...
// ...existing code...

// ...existing code...
// Hourly cron job: send digest emails for requests with no real-time notifications
cron.schedule("5 * * * *", async () => {
  try {
    const { Request: MealRequest, Subscriber, SendLog } = await import("./models/db.js");
    const { sendDigestEmail } = await import("./src/sendDigestEmail.js");
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);
    // Find requests created in the last hour with no SendLog
    const recentRequests = await MealRequest.find({ createdAt: { $gte: oneHourAgo } }).lean();
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
import { Request as MealRequest, Fulfillment, Subscriber } from "./models/db.js";
import rateLimit from "express-rate-limit";
import cron from "node-cron";
import { Resend } from "resend";

// small helpers
function isValidId(id: any) {
  try {
    return mongoose.Types.ObjectId.isValid(String(id));
  } catch (_) {
    return false;
  }
}

function escapeHtml(str: any) {
  if (str == null) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/\"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

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

// api: subscribe to digest emails (creates a pending Subscriber and sends confirmation)
app.post('/api/subscribe', limiter, async (req: Request, res: Response, next: NextFunction) => {
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
    // Fetch open requests. We'll compute an "isAsap" flag and order by timing:
    // - ASAP items (no windowStart or windowStart within next hour) come first, ordered by createdAt ascending (earliest first)
    // - Scheduled items come after, ordered by windowStart ascending
    const docs = await MealRequest.find({ status: "requested" }).limit(200).lean().exec();

    const now = new Date();
    const hourLater = new Date(now.getTime() + 60 * 60 * 1000);

    const processed = docs.map((d: any) => {
      const windowStart = d.windowStart ? new Date(d.windowStart) : null;
      const isAsap = !windowStart || (windowStart && windowStart <= hourLater);
      return { ...d, isAsap };
    });

    const asapList = processed
      .filter((r: any) => r.isAsap)
      .sort((a: any, b: any) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime());

    const scheduledList = processed
      .filter((r: any) => !r.isAsap)
      .sort((a: any, b: any) => {
        const aStart = a.windowStart ? new Date(a.windowStart).getTime() : new Date(a.createdAt).getTime();
        const bStart = b.windowStart ? new Date(b.windowStart).getTime() : new Date(b.createdAt).getTime();
        return aStart - bStart;
      });

    const ordered = asapList.concat(scheduledList).slice(0, 20);
    res.json(ordered);
  } catch (err) {
    next(err);
  }
});

// api: get single request by id
app.get("/api/request/:id", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { id } = req.params;
    if (!isValidId(id)) return res.status(400).json({ error: 'Invalid request id' });
    const doc = await MealRequest.findById(id).lean().exec();
    if (!doc) return res.status(404).json({ error: 'Request not found' });

    const now = new Date();
    const hourLater = new Date(now.getTime() + 60 * 60 * 1000);
    const windowStart = doc.windowStart ? new Date(doc.windowStart) : null;
    const isAsap = !windowStart || (windowStart && windowStart <= hourLater);

    res.json({ ...doc, isAsap });
  } catch (err) {
    next(err);
  }
});

// api: get stats (total meals shared)
app.get("/api/stats", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const totalShared = await Fulfillment.countDocuments();
    res.json({ totalShared });
  } catch (err) {
    next(err);
  }
});

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
app.post("/api/request", limiter, async (req: Request, res: Response, next: NextFunction) => {
  try {
    // ---- basic required fields ----
    const { vendor, food, pickupName, pickupWindowText, email, windowStart, windowEnd } = req.body || {};
    if (!vendor || !food || !pickupName || !pickupWindowText || !email)
      return res.status(400).json({ error: "missing fields" });

    // Enforce max 3 requests per email per calendar day (server local date)
    try {
      const now = new Date();
      const startOfDay = new Date(now);
      startOfDay.setHours(0, 0, 0, 0);
      const todaysCount = await MealRequest.countDocuments({
        email: email,
        createdAt: { $gte: startOfDay },
      });
      if (todaysCount >= 3) {
        return res.status(429).json({ error: 'You have reached the limit of 3 requests today' });
      }
    } catch (countErr) {
      console.error('Failed to enforce daily limit:', countErr);
      // fall through — don't block request creation on a count error
    }

    // parse structured window times when provided
    const parsedWindowStart = windowStart ? new Date(windowStart) : undefined;
    const parsedWindowEnd = windowEnd ? new Date(windowEnd) : undefined;

    // Reserve an _id so we can reference it in the confirmation email before creating the DB record.
    const reservedId = new mongoose.Types.ObjectId();

    // ---- send confirmation email first. If the email fails, do NOT create the request.
    try {
      const sVendor = escapeHtml(vendor);
      const sFood = escapeHtml(food);
      const sPickupName = escapeHtml(pickupName);
      const sPickupWindow = escapeHtml(pickupWindowText);
      await resend.emails.send({
        from: "CommonPlate <noreply@commonplatenyu.org>",
        to: email,
        subject: "Request Confirmed - CommonPlate",
        html: `
          <h2>Your meal request has been submitted!</h2>
          <p><strong>Vendor:</strong> ${sVendor}</p>
          <p><strong>Food:</strong> ${sFood}</p>
          <p><strong>Pickup Name:</strong> ${sPickupName}</p>
          <p><strong>Pickup Window:</strong> ${sPickupWindow}</p>
          <p>We'll notify you when someone fulfills your request.</p>
          <p>Request ID: ${reservedId.toString()}</p>
        `,
        text: `Your meal request has been submitted!\nVendor: ${vendor}\nFood: ${food}\nPickup Name: ${pickupName}\nPickup Window: ${pickupWindowText}\nRequest ID: ${reservedId.toString()}`,
      });
    } catch (emailErr) {
      console.error("[email] Confirmation email send failed:", emailErr);
      return res.status(502).json({ error: 'Failed to send confirmation email; request not created' });
    }

    // ---- create the document (expiration defaults to 24 hours via schema) ----
    const doc = await MealRequest.create({
      _id: reservedId,
      vendor,
      food,
      pickupName,
      email,
      pickupWindowText,
      windowStart: parsedWindowStart,
      windowEnd: parsedWindowEnd,
    });

    // Trigger real-time notifications to subscribers and await completion (do not fail the request on notify errors)
    try {
      const { notifySubscribersForRequest } = await import("./src/notifySubscribers.js");
      await notifySubscribersForRequest(doc as any);
    } catch (err) {
      console.error('[route] notifySubscribersForRequest failed for request', doc._id, err);
      // notification failures are logged but do not affect the request creation response
    }

    return res.status(201).json({ id: doc._id });
  } catch (err) {
    next(err);
  }
});

// api: delete a meal request (temporary for testing)
app.delete("/api/request/:id", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { id } = req.params;
    if (!isValidId(id)) return res.status(400).json({ error: 'Invalid request id' });
    const result = await MealRequest.findByIdAndDelete(id);
    
    if (!result) {
      return res.status(404).json({ error: "Request not found" });
    }
    
    res.json({ success: true, message: "Request deleted" });
  } catch (err) {
    next(err);
  }
});

// api: mark a request as fulfilled (create Fulfillment, update Request, notify requester)
app.post("/api/request/:id/fulfill", limiter, async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { id } = req.params;
    if (!isValidId(id)) return res.status(400).json({ error: 'Invalid request id' });
    const { orderNumber, eta, note, fulfillerEmail, contactMessage } = req.body || {};

    const sOrderNumber = typeof orderNumber === 'string' ? orderNumber.trim() : '';
    const sFulfillerEmail = typeof fulfillerEmail === 'string' ? fulfillerEmail.trim() : '';
    if (!sOrderNumber) {
      return res.status(400).json({ error: 'Please enter the Grubhub order number.' });
    }
    // Enforce a donor email is provided so requester can reply
    if (!sFulfillerEmail) {
      return res.status(400).json({ error: 'Please provide your email so the requester can contact you.' });
    }
    // Accept short numeric or alphanumeric order numbers (some providers use short ids).
    // Validate for 1-50 chars containing letters, numbers, dashes or underscores.
    if (!/^[A-Za-z0-9_-]{1,50}$/.test(sOrderNumber)) {
      return res.status(400).json({ error: "That doesn't look like a valid Grubhub order number. Please check and try again." });
    }

  const mealReq = await MealRequest.findById(id);
    if (!mealReq) return res.status(404).json({ error: 'Request not found' });
    if (mealReq.status === 'placed') return res.status(400).json({ error: 'Request already placed' });

    // Always use the ETA as provided by the requester (free text or ISO string)
    let etaText: string | undefined = undefined;
    if (typeof eta === 'string' && eta.trim()) {
      etaText = eta.trim();
    } else if (eta) {
      // fallback: stringify non-string values
      etaText = String(eta);
    }

    // Send the fulfillment email via the centralized helper. If the email fails, do not create the Fulfillment or update the Request.
    const suppliedMessage = contactMessage && String(contactMessage).trim() ? String(contactMessage).trim() : undefined;
    try {
      const { sendFulfillmentEmail } = await import("./src/emailHelpers.js");
      await sendFulfillmentEmail(mealReq as any, sOrderNumber, etaText, suppliedMessage, sFulfillerEmail);
    } catch (emailErr) {
      console.error('[email] Fulfillment email send failed:', emailErr);
      return res.status(502).json({ error: 'Failed to send fulfillment email; fulfillment not recorded' });
    }

    // Create the fulfillment and update the request only after email succeeded.
    const fulfillment = await Fulfillment.create({
      requestId: mealReq._id,
      orderNumber: sOrderNumber,
      etaText,
      note: note ? String(note).trim() : undefined,
    });

    // update request
    mealReq.status = 'placed';
    mealReq.orderNumber = sOrderNumber;
    if (etaText) (mealReq as any).etaText = etaText;
    await mealReq.save();

    // Contact message was sent (if provided) as part of the single fulfillment email above.

    return res.json({ success: true, fulfillmentId: fulfillment._id });
  } catch (err) {
    next(err);
  }
});


// ---- node-cron: cleanup expired documents (backup to TTL) ----
// Runs every hour to delete expired requests
if (process.env.CRON_ENABLED === 'true') {
  cron.schedule("0 * * * *", async () => {
    try {
      const now = new Date();
      const result = await MealRequest.deleteMany({ expiresAt: { $lte: now } });
      console.log(`[cron] Deleted ${result.deletedCount} expired requests at ${now.toISOString()}`);
    } catch (err) {
      console.error("[cron] Cleanup failed:", err);
    }
  });
} else {
  console.log('[cron] disabled — set CRON_ENABLED=true to enable scheduled cleanup');
}

// ---- error handler (must be last) ----
app.use((err: Error, req: Request, res: Response, next: NextFunction) => {
  console.error("Error:", err);
  res.status(500).json({ error: "Internal server error" });
});

// connect to db and start server
await mongoose.connect(MONGO_URI);
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  const PUBLIC_BASE = process.env.BASE_URL || `http://localhost:${PORT}`;
  console.log(PUBLIC_BASE);
});
