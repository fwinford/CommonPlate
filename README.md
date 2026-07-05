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
