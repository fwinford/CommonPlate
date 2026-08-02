# CommonPlate

CommonPlate is a campus mutual-aid web app for sharing meal requests, extra meal swipes, and free-food events.

I built it around a simple idea: students often have extra food resources, and other students need discreet, low-friction ways to ask for help. CommonPlate keeps the flow temporary, simple, and privacy-conscious.

## what it does

- students can post meal requests with a vendor, food item, pickup name, email, and time window
- students with extra meal swipes can claim a request, place the order, and mark it as fulfilled
- CommonPlate attempts requester confirmation and fulfillment emails; request creation and provider submission do not guarantee delivery
- old requests automatically expire
- rate limiting helps reduce spam
- daily request limits are best-effort abuse control; concurrent requests may exceed the limit

## tech stack

- **frontend:** HTML, CSS, TypeScript
- **backend:** Node.js, Express
- **database:** MongoDB
- **email:** Resend
- **automation:** MongoDB TTL indexes, node-cron
- **other:** express-rate-limit, dotenv, esbuild

## data model

CommonPlate uses these collections:

- **requests** — meal requests posted by students
- **fulfillments** — order details linked to a request
- **subscribers** — students signed up for new-request email alerts
- **sendlogs** — helper-alert/digest send-attempt ledger and duplicate-send guard for a request/subscriber pair; not a delivery, reading, or pickup receipt
- **system** — small key/value store (currently the round-robin alert cursor)

A request can have at most one fulfillment, enforced by both a unique index and
the transaction that records placement. Requests are automatically deleted after
their retention window.

## technical decisions

- **temporary data:** requests expire so the board stays current and private
- **email over accounts:** requesters get updates without needing a full login system
- **rate limiting:** form submissions are limited to reduce spam
- **typescript:** used to make the codebase easier to maintain as it grew

## running locally

```bash
npm install
cp .env.example .env
# Set MONGO_URI, RESEND_API_KEY, and a unique CLAIM_TOKEN_HMAC_SECRET
# containing at least 32 UTF-8 bytes.
npm run dev
```

### Local MongoDB must be a replica set

Day 5 placement commits the request transition and its durable fulfillment
record in one MongoDB transaction, and transactions are unavailable on a
standalone `mongod`. The app checks this at startup and **exits rather than
starting** against a standalone, so a plain `mongod` will not run CommonPlate.

A single-member replica set is enough for local development. If a standalone
`mongod` is already running on port 27017, stop it first — `rs.initiate()`
against a node started without `--replSet` fails with *"This node was not
started with replication enabled."*

```bash
# 1. Start mongod as a replica set member (use your own --dbpath).
mongod --dbpath /usr/local/var/mongodb --replSet rs0 --bind_ip 127.0.0.1

# 2. Initialize the set once per data directory, in a second terminal.
mongosh --quiet --eval 'rs.initiate({_id: "rs0", members: [{_id: 0, host: "127.0.0.1:27017"}]})'
```

Then point `MONGO_URI` at the set — the `replicaSet` parameter is required, not
optional:

```env
MONGO_URI=mongodb://127.0.0.1:27017/commonplate_development?replicaSet=rs0
```

`npm run test:mongo` is unaffected: it starts and initializes its own
throwaway replica set on a free port and does not use `MONGO_URI`.

Claim and claim-extension mutations fail closed unless
`CLAIM_TOKEN_HMAC_SECRET` is configured. The raw 32-byte base64url claim token
is returned only to the winning claimant; MongoDB stores only its
HMAC-SHA-256 digest. Do not reuse a sample or checked-in value as the secret.

### Day 4 rollout order

Pre-Day-4 request records are disposable. There is no backfill and no
compatibility layer, so these steps must run in this order, once per database:

1. **Configure the HMAC secret.** Set `CLAIM_TOKEN_HMAC_SECRET` to at least 32
   UTF-8 bytes of unique random material. The process exits at startup without
   it.
2. **Clear the disposable old requests.** Anything with `status: "requested"`
   or without `deleteAt` predates Day 4 and must go.

   ```bash
   mongosh "$MONGO_URI" --eval 'db.requests.deleteMany({})'
   ```
3. **Deploy and run the Day 4 code**, so every new record is written in the new
   format (`status: "open"`, `deleteAt` set alongside `expiresAt`).
4. **Run the TTL migration**, moving TTL responsibility from `expiresAt` to
   private `deleteAt`.

   ```bash
   npm run migrate:request-ttl
   ```
5. **Reseed local UI data** where needed: `npm run seed:ui`.

The migration refuses, exits non-zero, and changes no index if any request
still has `status: "requested"` or is missing `deleteAt` — the existing
`expiresAt` TTL protection stays intact so no record is left with no deletion
path. Once the collection is clean it creates `request_deleteAt_ttl` first,
then removes only single-field TTL indexes on `expiresAt`.

## public actions pause

While the create → claim → fulfill path is incomplete, the deployed site must
not accept a meal request nobody can fulfill, must not invite helpers into a
paused flow, and must not accept a subscriber before confirmation and
unsubscribe work. One environment value carries that decision:

```env
PUBLIC_ACTIONS_PAUSED=true
```

When on, these are unavailable:

- `POST /api/request` — refused before validation, email, database write, and
  subscriber notification
- `POST /api/request/:id/claim` and `/api/request/:id/claim/extend` — refused
  before token generation, rate limiting, or database work
- `POST /api/subscribe` — refused before any subscriber is created or confirmed
- real-time new-request alerts, post-subscription recent-request alerts, and
  the hourly digest — skipped without recording a delivery
- the web request form's submit action and the homepage alerts signup control

Public meal browsing (`GET /api/requests`, `GET /api/request/:id`) stays
available in both states.

Rules:

- set `true` on the deployed site until the full flow is restored;
- local Days 3–5 development may set `false` to keep the create and
  subscription APIs available;
- a missing, empty, or unrecognized value is treated as **paused**, so a
  forgotten deployment variable cannot silently re-open posting. Only `false`
  or `0` resumes public actions;
- this is a temporary rollout safety control, not a product feature. Removing
  it requires the create → claim → fulfill path to be truthful and working;
- the legacy web fulfillment UI remains disabled. `POST /api/request/:id/fulfill`
  is active only with a valid, active claim token; `PUBLIC_ACTIONS_PAUSED` does
  not disable that valid-claim fulfillment path.

## UI test fixture

The database selected by `MONGO_URI` must itself have an explicit
development/test-style name, such as `test`, `commonplate_dev`,
`commonplate_test`, or `commonplate_local`. An arbitrary MongoDB URI is not
acceptable: `NODE_ENV=development` or a development-labeled cluster alone does
not make its selected database safe. Generic or production-like database names
such as `commonplate`, `prod`, `production`, and `commonplate-production` are
refused.

Prerequisites:

```env
NODE_ENV=development
ALLOW_LOCAL_SEED=true
MONGO_URI=<URI selecting a clearly named development/test database>
```

Commands:

```bash
npm run seed:ui
npm run dev
curl http://localhost:3000/api/requests
npm run seed:ui:cleanup
```

The seed command replaces any prior matching fixture with one short-lived fake
meal request for local web and iOS UI testing. It writes through the existing
Request model without calling the application POST route, so it sends no email
or subscriber alert. The cleanup command removes only the fixture matching the
dedicated QA vendor, food, email, pickup name, and pickup-window values.

Never run this tool against a production database. The script requires
`ALLOW_LOCAL_SEED=true`, rejects production mode and production-like database
names, and prints only the selected database name rather than the MongoDB URI.
The local `.env` file remains untracked and must not contain committed
credentials.
