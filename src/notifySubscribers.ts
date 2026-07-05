import { Subscriber, System, SendLog, IRequest, ISubscriber, Request as MealRequest } from "../models/db.js";
import { sendNewRequestAlert } from "./emailHelpers.js";

// Helper to select and notify up to 2 eligible subscribers in round-robin fashion
export async function notifySubscribersForRequest(request: IRequest) {
  console.log(`[notify] called for request ${request._id} vendor=${request.vendor} pickupWindow=${request.pickupWindowText}`);

  // Idempotency: only skip if there's already a successful send for this request.
  // This allows retries when previous attempts failed while still preventing duplicate
  // notifications once a send has succeeded.
  const hasSuccessfulSend = await SendLog.exists({ requestId: request._id, status: 'sent' });
  if (hasSuccessfulSend) {
    console.log(`[notify] already sent for request ${request._id}, skipping`);
    return;
  } else {
    console.log(`[notify] no successful SendLog for request ${request._id}, proceeding`);
  }

  // Find eligible subscribers (caps: 1/hour, 4/day). Be tolerant of missing fields.
  const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);
  const eligible = await Subscriber.find({
    $and: [
      { status: "confirmed" },
      { bounced: false },
      { $or: [ { dailyCount: { $lt: 4 } }, { dailyCount: { $exists: false } } ] },
      { $or: [ { lastSentAt: { $lt: oneHourAgo } }, { lastSentAt: null }, { lastSentAt: { $exists: false } } ] },
    ]
  }).sort({ _id: 1 });

  console.log(`[notify] eligible subscribers found: ${eligible.length} for request ${request._id}`);

  if (!eligible.length) {
    console.log(`[notify] no eligible subscribers for request ${request._id}, exiting`);
    return;
  }

  // Get round-robin cursor
  const cursorDoc = await System.findOne({ key: "notify_cursor" });
  const cursor = (cursorDoc?.value?.index ?? 0) % eligible.length;

  // Pick up to 2, wrapping around
  const picks = [eligible[cursor]];
  if (eligible.length > 1) picks.push(eligible[(cursor + 1) % eligible.length]);
  const actualPicks = picks.filter(Boolean);

  // Send and update
  let notified = 0;
  for (const sub of actualPicks) {
    console.log(`[notify] processing subscriber ${String(sub._id)} <${sub.email}> for request ${request._id}`);
    // Atomic claim: try to insert a pending SendLog to claim this (request,subscriber).
    // If another process already claimed it, skip to avoid duplicate sends.
    try {
      await SendLog.create({
        subscriberId: sub._id,
        requestId: request._id,
        sentAt: new Date(),
        status: "fail", // placeholder - will be updated after send
      });
      console.log(`[notify] SendLog claim created for request ${request._id} subscriber ${String(sub._id)}`);
    } catch (claimErr: unknown) {
      // Duplicate key means another process has claimed this subscriber for this request.
      const claimMsg = String((claimErr as any)?.message || '');
      if (claimMsg.includes('E11000') || (claimErr as any)?.code === 11000) {
        console.log(`[notify] SendLog claim already exists for request ${request._id} subscriber ${String(sub._id)}, skipping`);
        continue; // skip this subscriber
      }
      // Unexpected error creating claim - log and skip
      console.error('[notify] Error creating SendLog claim:', claimErr);
      continue;
    }

    try {
      await sendNewRequestAlert(sub, request);
      console.log(`[notify] sendNewRequestAlert success for ${String(sub._id)} <${sub.email}> request ${request._id}`);
      // Update subscriber counters only on success
      await Subscriber.updateOne(
        { _id: sub._id },
        {
          $set: { lastSentAt: new Date() },
          $inc: { dailyCount: 1 },
        }
      );
      // Mark SendLog as sent
      await SendLog.updateOne(
        { requestId: request._id, subscriberId: sub._id },
        { $set: { status: 'sent', sentAt: new Date(), error: undefined } }
      );
      notified++;
    } catch (err: unknown) {
      const errText = err instanceof Error ? err.message : String(err);
      console.error(`[notify] sendNewRequestAlert failed for ${String(sub._id)} <${sub.email}> request ${request._id}:`, errText);
      // Update SendLog with failure details
      await SendLog.updateOne(
        { requestId: request._id, subscriberId: sub._id },
        { $set: { status: 'fail', sentAt: new Date(), error: errText } }
      );
      // If hard error, mark bounced
      if (errText.match(/invalid|bounce|not found|recipient/i)) {
        await Subscriber.updateOne({ _id: sub._id }, { $set: { bounced: true } });
      }
    }
  }

  // Advance cursor
  if (notified) {
    const newCursor = (cursor + notified) % eligible.length;
    await System.updateOne(
      { key: "notify_cursor" },
      { $set: { value: { index: newCursor } } },
      { upsert: true }
    );
    console.log(`[notify] advanced notify_cursor to ${newCursor}`);
  }
}

// Notify a single subscriber about recent un-notified requests (used after double-opt-in)
export async function notifySubscriberAboutRecentRequests(subscriber: ISubscriber) {
  if (!subscriber) return;
  console.log(`[notify:on-confirm] called for subscriber ${String(subscriber._id)} <${subscriber.email}>`);
  try {
    // Respect confirmed status and bounced flag
    if (subscriber.status !== 'confirmed') {
      console.log(`[notify:on-confirm] subscriber ${String(subscriber._id)} not confirmed, skipping`);
      return;
    }
    if (subscriber.bounced) {
      console.log(`[notify:on-confirm] subscriber ${String(subscriber._id)} is bounced, skipping`);
      return;
    }

    // Enforce daily cap and 1/hour rule
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);
    if ((subscriber.dailyCount || 0) >= 4) {
      console.log(`[notify:on-confirm] subscriber ${String(subscriber._id)} reached daily cap, skipping`);
      return;
    }
    if (subscriber.lastSentAt && subscriber.lastSentAt > oneHourAgo) {
      console.log(`[notify:on-confirm] subscriber ${String(subscriber._id)} sent within last hour, skipping`);
      return;
    }

    // Find recent open requests (within TTL — 24 hours)
    const since = new Date(Date.now() - 24 * 60 * 60 * 1000);
    const recentRequests = await MealRequest.find({ status: 'requested', createdAt: { $gte: since } }).sort({ createdAt: -1 }).limit(50).lean();
    if (!recentRequests.length) {
      console.log(`[notify:on-confirm] no recent requests to notify ${String(subscriber._id)}`);
      return;
    }

    let sentCount = 0;
    for (const req of recentRequests) {
      // skip if already sent
      const already = await SendLog.exists({ requestId: req._id, subscriberId: subscriber._id, status: 'sent' });
      if (already) continue;

      // Claim the SendLog slot atomically
      try {
        await SendLog.create({ requestId: req._id, subscriberId: subscriber._id, sentAt: new Date(), status: 'fail' });
        console.log(`[notify:on-confirm] SendLog claim created for request ${req._id} subscriber ${String(subscriber._id)}`);
        } catch (claimErr: unknown) {
          const claimMsg = String((claimErr as any)?.message || '');
          if (claimMsg.includes('E11000') || (claimErr as any)?.code === 11000) {
            console.log(`[notify:on-confirm] SendLog claim already exists for request ${req._id} subscriber ${String(subscriber._id)}, skipping`);
            continue;
          }
          console.error('[notify:on-confirm] Failed to create SendLog claim', claimErr);
        continue;
      }

      try {
        await sendNewRequestAlert(subscriber as any, req as any);
        console.log(`[notify:on-confirm] sendNewRequestAlert success for subscriber ${String(subscriber._id)} request ${req._id}`);
        // update subscriber counters
        await Subscriber.updateOne({ _id: subscriber._id }, { $set: { lastSentAt: new Date() }, $inc: { dailyCount: 1 } });
        // mark sendlog sent
        await SendLog.updateOne({ requestId: req._id, subscriberId: subscriber._id }, { $set: { status: 'sent', sentAt: new Date(), error: undefined } });
        sentCount++;
        // stop if we've hit daily cap
  const latest: any = await Subscriber.findById(subscriber._id).lean();
  if (latest && (latest.dailyCount >= 4)) break;
      } catch (err: unknown) {
        const errText = err instanceof Error ? err.message : String(err);
        await SendLog.updateOne({ requestId: req._id, subscriberId: subscriber._id }, { $set: { status: 'fail', sentAt: new Date(), error: errText } });
        if (errText.match(/invalid|bounce|not found|recipient/i)) {
          await Subscriber.updateOne({ _id: subscriber._id }, { $set: { bounced: true } });
          break; // stop further sends to this subscriber
        }
      }
    }
    if (sentCount) console.log(`[notify:on-confirm] Sent ${sentCount} notifications to ${subscriber.email}`);
  } catch (err) {
    console.error('[notify:on-confirm] unexpected error', err);
  }
}
