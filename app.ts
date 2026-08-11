
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
    const recentRequests = await MealRequest.find({
      createdAt: { $gte: oneHourAgo },
      ...buildEffectiveAvailabilityFilter(digestNow),
    }).lean();
    const notifiedRequestIds = new Set((await SendLog.find({ requestId: { $in: recentRequests.map(r => r._id) } }).lean()).map(l => String(l.requestId)));
    const unnotified = recentRequests.filter(r => !notifiedRequestIds.has(String(r._id)));
    if (!unnotified.length) return;
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
    if (!monitorEmails.length) return;
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
  Installation,
  Participant,
  ParticipantVerification,
  PushDelivery,
  Request as MealRequest,
  RequestParticipation,
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
import {
  filterRequestListForParticipant,
  resolveOptionalParticipantAuthority,
} from "./src/requestParticipation.js";
import {
  createRequest,
  createRequestRateLimiter,
} from "./src/createRequestRoute.js";
import { scheduleEligibilityNotificationSweep } from "./src/eligibilityNotificationSweep.js";
import {
  FULFILLMENT_ROUTE_PATH,
  fulfillRequest,
  fulfillmentRateLimiter,
} from "./src/fulfillmentRoute.js";
import { assertMongoTransactionsSupported } from "./src/mongoTransactions.js";
import { getStats } from "./src/statsRoute.js";
import {
  CLAIM_EXTENSION_ROUTE_PATH,
  CLAIM_RELEASE_ROUTE_PATH,
  CLAIM_ROUTE_PATH,
  claimExtensionRateLimiter,
  claimRateLimiter,
  claimReleaseRateLimiter,
  claimRequest,
  extendClaim,
  pauseDay4Mutation,
  releaseClaim,
} from "./src/claimRoute.js";
import {
  ACTIVE_RESERVATION_ROUTE_PATH,
  activeReservationRateLimiter,
  getActiveReservation,
} from "./src/reservationRoute.js";
import { readClaimTokenHmacSecret } from "./src/claimToken.js";
import { assertUnsubscribeSigningSecretForActivation } from "./src/unsubscribeCredential.js";
import { assertApnsConfigurationForActivation } from "./src/apnsConfig.js";
import { assertParticipantSigningSecretForActivation } from "./src/participantCredentials.js";
import { registerParticipantVerificationRoutes } from "./src/participantVerificationRoutes.js";
import { registerParticipantEmailUnsubscribeRoute } from "./src/participantEmailUnsubscribeRoute.js";
import { buildEffectiveAvailabilityFilter } from "./src/requestAvailability.js";
import {
  CREATE_UNAVAILABLE_MESSAGE,
  SUBSCRIBE_UNAVAILABLE_MESSAGE,
  isPublicActionsPaused,
  pausePublicAction,
} from "./src/publicActionsPause.js";
import { subscribe } from "./src/subscribeRoute.js";
import {
  INSTALLATION_PUSH_ROUTE_PATH,
  INSTALLATION_PUSH_UNAVAILABLE_MESSAGE,
  installationPushRateLimiter,
  synchronizeInstallationPush,
} from "./src/installationPushRoute.js";
import {
  CONFIRMATION_ROUTE_PATH,
  confirmSubscriptionPage,
  confirmationBodyParser,
  confirmationParserError,
  confirmationRateLimiter,
  confirmationSecurityHeaders,
  pauseConfirmationPage,
  showConfirmationPage,
} from "./src/confirmSubscriptionRoute.js";
import {
  UNSUBSCRIBE_ROUTE_PATH,
  pauseUnsubscribePage,
  showUnsubscribePage,
  unsubscribeBodyParser,
  unsubscribePage,
  unsubscribeParserError,
  unsubscribeRateLimiter,
  unsubscribeSecurityHeaders,
} from "./src/unsubscribeRoute.js";

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
// Required only once public actions are unpaused, and checked here — before the
// Express app exists, before any route is registered, before the database
// connection, and before this process listens — so an unpaused deployment
// cannot accept a signup, confirm an address, send an alert, deliver a digest,
// or serve an unsubscribe link without being able to sign one. The scheduled
// digest is registered above but cannot deliver: its callback needs the event
// loop, and this exit is synchronous. Paused startup reads nothing, so local
// and test processes still start without the secret.
try {
  assertUnsubscribeSigningSecretForActivation();
} catch (error) {
  console.error(
    error instanceof Error
      ? error.message
      : "Invalid unsubscribe signing secret"
  );
  process.exit(1);
}
// Also required only once public actions are unpaused, and checked in the same
// place for the same reason: an installation can already turn push on, and
// "push alerts are on" means this deployment is configured to submit through
// APNs. Without provider configuration that on-state would be true for nobody,
// so provider configuration gates activation instead of being discovered at
// the first send. Paused startup reads none of the four variables.
try {
  assertApnsConfigurationForActivation();
} catch (error) {
  console.error(
    error instanceof Error
      ? error.message
      : "Invalid APNs provider configuration"
  );
  process.exit(1);
}
// Required only once public actions are unpaused, checked in the same place
// for the same reason as the two above (W3-I1). Unpaused means requests can be
// created and claimed, and both now require a participant credential this
// process must be able to sign and verify. Without the secret every
// participant action would fail at its first attempt instead of at boot, and
// nobody could verify an address to begin with. Paused startup reads nothing.
try {
  assertParticipantSigningSecretForActivation();
} catch (error) {
  console.error(
    error instanceof Error
      ? error.message
      : "Invalid participant signing secret"
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

// Browser confirmation flow for the emailed link. Both halves answer in HTML
// behind route-owned security headers and an HTML pause guard. The GET only
// renders a form and never mutates a Subscriber, because inbox scanners and
// prefetchers fetch links without a person acting; the explicit POST carries
// its own limiter bucket so confirming cannot spend the signup allowance.
//
// Registered ahead of the global body parsers deliberately. A global parser
// runs before route middleware, so a body it rejected would be answered by the
// global JSON error handler — bypassing these headers, the pause guard, and the
// HTML contract, and logging a parser error that can quote the raw token. This
// route parses its own body instead, after the pause and the limiter.
app.get(
  CONFIRMATION_ROUTE_PATH,
  confirmationSecurityHeaders,
  pauseConfirmationPage,
  showConfirmationPage
);
app.post(
  CONFIRMATION_ROUTE_PATH,
  confirmationSecurityHeaders,
  pauseConfirmationPage,
  confirmationRateLimiter,
  confirmationBodyParser,
  confirmSubscriptionPage,
  confirmationParserError
);

// Browser unsubscribe flow for the emailed link, registered alongside the
// confirmation flow, ahead of the global parsers, and for the same reasons.
// Opening the link only renders a form: inbox scanners and prefetchers fetch
// emailed links with nobody acting, so unsubscribing anyone on a GET would
// silence people who merely received an alert. The explicit POST owns the
// mutation and carries its own limiter bucket.
app.get(
  UNSUBSCRIBE_ROUTE_PATH,
  unsubscribeSecurityHeaders,
  pauseUnsubscribePage,
  showUnsubscribePage
);
app.post(
  UNSUBSCRIBE_ROUTE_PATH,
  unsubscribeSecurityHeaders,
  pauseUnsubscribePage,
  unsubscribeRateLimiter,
  unsubscribeBodyParser,
  unsubscribePage,
  unsubscribeParserError
);

// api: participant verification (W3-I1). Registered here, ahead of the global
// parsers, alongside the two emailed-link flows above and for a stricter
// version of the same reason: this route's body is the one place in the service
// where a raw verification code arrives from the wire, and a body the global
// parser rejected would be answered by the global error handler, which logs the
// parser error — and a parser error quotes the body. The focused production
// registration function owns both complete middleware chains; the real-byte
// HTTP tests invoke that same function.
//
// Both halves are paused ahead of their limiters, parsers, and handlers, so a
// paused deployment mails no code, writes no challenge, and issues no
// participant authority — nobody may become verified for actions that are
// themselves refused. Separate limiter buckets keep submitting a code from
// spending the allowance for requesting one.
registerParticipantVerificationRoutes(app);

// api: participant-authorized email-alert unsubscribe (W3-N2). Registered
// alongside participant verification, ahead of the global parsers, for the
// same body-shape reason: there is no body to parse for this route, but pause
// and the participant-authority gate must still run before any global
// middleware could otherwise see the request.
registerParticipantEmailUnsubscribeRoute(app);

// middleware to parse JSON and serve static files
app.use(express.json({ limit: '100kb' }));
app.use(express.urlencoded({ extended: true, limit: '100kb' }));
app.use(express.static(path.join(process.cwd(), "public")));

// rate limiting middleware - apply only to form endpoints
// Request creation has its own bucket (`createRequestRateLimiter`) so that its
// refusal can carry the structured error envelope iOS needs; this one now
// covers subscribe alone.
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
app.post('/api/subscribe', pausePublicAction(SUBSCRIBE_UNAVAILABLE_MESSAGE), limiter, subscribe);

// api: synchronize one app installation's complete current push state
// (Week 3 Day 6 Slice 6A.1). This declares on/off and, when on, the current
// APNs token; it sends no notification. The pause runs ahead of the limiter
// and the handler so a paused request performs no credential hashing,
// installation lookup, or mutation.
app.put(
  INSTALLATION_PUSH_ROUTE_PATH,
  pausePublicAction(INSTALLATION_PUSH_UNAVAILABLE_MESSAGE, "PUBLIC_ACTIONS_PAUSED"),
  installationPushRateLimiter,
  synchronizeInstallationPush
);

// serve fulfill page for a specific request
app.get("/request/:id/fulfill", (req: Request, res: Response) => {
  res.sendFile(path.join(process.cwd(), "public", "fulfill.html"));
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

    // W3-H2 marketplace presentation: a request this verified participant has
    // ever successfully held must no longer appear in their own eligible
    // list once they no longer hold it. Browsing stays open to anyone
    // (W3-I1), so an absent or unusable credential here degrades to the
    // unfiltered anonymous list rather than refusing the read; every other
    // eligible participant's own list is unaffected, because the filter is
    // always scoped to exactly the resolved caller's own participant id.
    const participant = await resolveOptionalParticipantAuthority(req);
    const visibleDocs = await filterRequestListForParticipant(
      docs as unknown as RequestListDocument[],
      participant
    );

    res.json(buildPublicRequestListResponse(visibleDocs, now));
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
// The limiter refuses before validation, email, and the write, so a throttled
// attempt is a definitive no-write outcome. It answers with the structured
// `RATE_LIMITED` envelope rather than a plain-string body, because iOS must be
// able to tell that refusal apart from an unreadable response on a
// non-idempotent POST — see "Definitive versus ambiguous create failures".
app.post("/api/request", pausePublicAction(CREATE_UNAVAILABLE_MESSAGE, "PUBLIC_ACTIONS_PAUSED"), createRequestRateLimiter, createRequest);

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
app.post(
  CLAIM_RELEASE_ROUTE_PATH,
  pauseDay4Mutation,
  claimReleaseRateLimiter,
  releaseClaim
);

// A read of the caller's own already-granted reservation truth (W3-H1
// continuation), not a new mutation, so it is not paused by
// `PUBLIC_ACTIONS_PAUSED` — matching `GET /api/request/:id` above.
app.get(
  ACTIVE_RESERVATION_ROUTE_PATH,
  activeReservationRateLimiter,
  getActiveReservation
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

// A request whose helper eligibility begins after its creation — a future Later
// request (W3-R1) — is deliberately not dispatched for at creation. This is
// what starts the existing helper email and push lifecycle at its `visibleFrom`
// instead. Registered independently of `CRON_ENABLED`, like the digest and the
// other notification jobs, because it is not a cleanup backup: without it those
// requests are never notified about at all.
scheduleEligibilityNotificationSweep();

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
// Do not accept installation push-state traffic until the database has
// established the single-eligible-owner-per-token guarantee that the
// installation push route relies on instead of a race-prone read-then-write.
await Installation.createIndexes();
// Do not submit a push notification until the database has established the
// (requestId, installationId, purpose) uniqueness the dispatcher claims
// against: without it, two concurrent dispatches would both submit for the
// same installation, and V1 has no retry path that could repair a duplicate.
await PushDelivery.createIndexes();
// Do not accept participant traffic until the database has established the
// one-participant-per-address and one-live-challenge-per-address guarantees
// (W3-I1). Without them two concurrent verifications could create two
// Participant rows for one principal, and a resend could leave two working
// codes live for one inbox instead of superseding the first.
await Participant.createIndexes();
await ParticipantVerification.createIndexes();
// Do not accept claim traffic until the database has established the
// one-successful-participation-per-(request, participant) uniqueness
// guarantee (W3-H2). Without it, `claimRequest`'s pre-check and insert are
// only a best-effort race guard, not a durable invariant.
await RequestParticipation.createIndexes();
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  const PUBLIC_BASE = process.env.BASE_URL || `http://localhost:${PORT}`;
  console.log(PUBLIC_BASE);
});
