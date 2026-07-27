# CommonPlate

CommonPlate is a campus mutual-aid web app for sharing meal requests, extra meal swipes, and free-food events.

I built it around a simple idea: students often have extra food resources, and other students need discreet, low-friction ways to ask for help. CommonPlate keeps the flow temporary, simple, and privacy-conscious.

## what it does

- students can post meal requests with a vendor, food item, pickup name, email, and time window
- students with extra meal swipes can claim a request, place the order, and mark it as fulfilled
- requesters get confirmation and fulfillment emails
- old requests and events automatically expire
- rate limiting helps reduce spam

## tech stack

- **frontend:** HTML, CSS, TypeScript
- **backend:** Node.js, Express
- **database:** MongoDB
- **email:** Resend
- **automation:** MongoDB TTL indexes, node-cron
- **other:** express-rate-limit, dotenv, esbuild

## data model

CommonPlate uses three main collections:

- **requests** — meal requests posted by students
- **fulfillments** — order details linked to a request
- **events** — free-food events posted separately

Requests can have one fulfillment. Events and requests are automatically deleted after their expiration window.

## technical decisions

- **temporary data:** requests and events expire so the board stays current and private
- **email over accounts:** requesters get updates without needing a full login system
- **rate limiting:** form submissions are limited to reduce spam
- **typescript:** used to make the codebase easier to maintain as it grew

## running locally

```bash
npm install
npm run dev
```

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
