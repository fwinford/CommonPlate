# Milestone 04

Repository Link
---
https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford

Demo URLs
---
 - Home: <(https://commonplatenyu.org/)>
- New Request: <https://commonplatenyu.org/request/new>
- Fulfill Request: See Notes Below <https://commonplatenyu.org/request/REQUESTID/fulfill>
- fulfill requests are based on the specific request id of that order, to get a specific link put in a sample new request
- Subscribe UI: (homepage, "Get Meal Request Alerts" button)

Overview / Progress
---
Since Milestone 3, I have implemented a full email notification system for meal swipe requests, including:
- Email subscription with double opt-in (confirmation link)
- Unsubscribe flow (one-click link in every email)
- Real-time notifications to up to 2 subscribers per new request, using round-robin distribution
- Per-subscriber notification limits (max 1/hour, 4/day)
- Hourly digest fallback for unnotified requests
- All notification logic is robust, idempotent, and production-ready

Features / Functionality
---
- **Email subscription and double opt-in**: Users can subscribe for meal request alerts by email, must confirm via a unique link ([code](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/src/emailHelpers.ts#L33-L52)).
- **Unsubscribe flow**: Every email includes a one-click unsubscribe link ([code](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/src/emailHelpers.ts#L55-L68)).
- **Real-time notifications**: When a new request is created, up to 2 eligible subscribers are notified immediately ([code](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/src/notifySubscribers.ts#L5-L77)).
- **Round-robin distribution**: Subscribers are selected in round-robin order, with a persistent cursor ([code](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/src/notifySubscribers.ts#L25-L77)).
- **Per-subscriber limits**: Each subscriber can receive at most 1 notification per hour and 4 per day ([code](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/src/notifySubscribers.ts#L11-L17)).
- **Hourly digest fallback**: If a request is not notified in real-time, it is included in an hourly digest ([code](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/blob/main/src/sendDigestEmail.ts#L4-L32)).
- **All notification emails use Resend API** ([code](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/src/emailHelpers.ts#L8-L31)).
- **All notification logic is robust and idempotent** (SendLog prevents duplicate notifications).

Research Topics (with code links)
---
- **Round-robin notification distribution**: Implements a persistent cursor in the database to rotate through eligible subscribers, ensuring fair distribution ([notifySubscribers.ts](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/src/notifySubscribers.ts#L25-L77)).
- **Per-subscriber notification limits**: Enforces 1/hour and 4/day caps for each subscriber ([notifySubscribers.ts](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/src/notifySubscribers.ts#L11-L17)).
- **Double opt-in and unsubscribe**: Secure confirmation and unsubscribe flows for all subscribers ([emailHelpers.ts](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/src/emailHelpers.ts#L33-L68)).
- **Resend email API**: All transactional emails are sent via Resend, with robust error handling ([emailHelpers.ts](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/src/emailHelpers.ts#L8-L31)).
- **Hourly digest fallback**: Uses a cron job to send a digest of unnotified requests ([sendDigestEmail.ts](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/src/sendDigestEmail.ts#L4-L32)).
- **express-rate-limit**: Used to prevent abuse of form endpoints ([app.ts](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/blob/main/app.ts#L65-L110)).
- **node-cron for scheduled jobs**: Used for digest and daily reset ([app.ts](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/blob/main/app.ts#L1-L55)).


What changed since Milestone 3
---
Since Milestone 3, I have implemented:
- A full email subscription and notification system (subscribe, confirm, unsubscribe)
- Real-time notifications to up to 2 subscribers per request, with round-robin and per-user limits
- Hourly digest fallback for unnotified requests
- Robust error handling and idempotency for all notifications
- New UI for subscribing to alerts on the homepage
- All notification logic is covered by new code in `src/notifySubscribers.ts`, `src/emailHelpers.ts`, and `src/sendDigestEmail.ts`

### New scripts for local testing and admin/debug flows
- `scripts/trigger-notify.ts`: Manually triggers notification logic for the most recent request and prints SendLogs and subscriber samples. Useful for local or admin testing.
- `scripts/check-notify.ts`: Prints the latest request, its SendLogs, and a sample of confirmed subscribers for debugging notification state.
- `scripts/confirm-test.ts`: Confirms a subscriber by token for testing double opt-in flows.
- `scripts/migrate-sendlog-index.ts`: Ensures the unique index on SendLog (requestId+subscriberId) exists in the database. Run once in prod/staging for safety.

### PR 2: Fulfillment form and contact flow
- The fulfillment form now requires a Grubhub order number (with validation and clear error messages).
- Fulfillers can optionally send a private message to the requester via email, with an optional reply-to address. This is handled by a new backend helper and UI fields.
- All changes are robust, user-friendly, and privacy-respecting.

### PR 3: Display active subscriber count on homepage
- The homepage now shows a real-time count of active subscribers (status: confirmed, not bounced) ready to fulfill requests.
- If no active subscribers, a friendly fallback message is shown.
- This is powered by a new backend API (`/api/active-subscriber-count`) and a helper in the Subscriber model.

References / Annotations
---
- [Resend Email API docs](https://resend.com/docs/send-with-nodejs)
- [express-rate-limit npm](https://www.npmjs.com/package/express-rate-limit)
- [node-cron npm](https://www.npmjs.com/package/node-cron)
- [Double opt-in pattern](https://en.wikipedia.org/wiki/Opt-in_email)
- [MongoDB TTL Indexes](https://www.mongodb.com/docs/manual/core/index-ttl/)
