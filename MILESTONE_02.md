Milestone 02
===

Repository Link
---
https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford

URL for form 
---
http://localhost:3000/request/new

(For deployed version: `final-project-fwinford.onrender.com/request/new`)

URL for form result
---

**Confirmation email after form submission:**
![request-confirmation](request-confirmation.png)

**Homepage displaying active requests:**
- All submitted requests appear on the homepage at http://localhost:3000
- Requests displayed as cards with pickup window (purple text), pickup name, and "Order This" button
- Real-time stats showing "X active requests right now" and "X total meals shared"
- Cards feature hover effect (subtle purple glow and lift animation)
- Click card to view full details in modal (vendor, food description, pickup info)
- Requests automatically expire after 24 hours (TTL index + cron cleanup)

Research Topics Implementation (10 points)
---

### 1. TypeScript (2 points)
**Server-side TypeScript:**
- Express server with type safety: [app.ts](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/app.ts) (151 lines)
- Database models with interfaces: [models/db.ts](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/models/db.ts) (120 lines)

**Client-side TypeScript:**
- Homepage logic: [src/client/home.ts](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/src/client/home.ts) (190 lines)
- Request form logic: [src/client/new-request.ts](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/src/client/new-request.ts) (115 lines)

**Build tooling:**
- TypeScript config: [tsconfig.json](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/tsconfig.json)
- Build script using esbuild: [build-client.mjs](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/build-client.mjs)

### 2. express-rate-limit (2 points)
- Import: [app.ts#L8](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/app.ts#L8)
- Configuration (5 requests/minute per IP): [app.ts#L26-L27](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/app.ts#L26-L27)
- Applied to POST `/api/request` endpoint to prevent spam

### 3. node-cron + MongoDB TTL Indexes (3 points)
**node-cron:**
- Hourly cleanup job as backup to TTL: [app.ts#L135-L142](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/app.ts#L135-L142)

**Request Model TTL (24-hour expiration):**
- TTL index on `expiresAt` field: [models/db.ts#L35](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/models/db.ts#L35)
- Pre-save hook setting expiration: [models/db.ts#L40-L46](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/models/db.ts#L40-L46)

**Event Model TTL (2 hours after event):**
- TTL index on `expiresAt` field: [models/db.ts#L80](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/models/db.ts#L80)
- Pre-save hook setting expiration: [models/db.ts#L85-L92](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/models/db.ts#L85-L92)

### 4. Resend Email API (3 points)
- Import & initialization: [app.ts#L10-L13](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/app.ts#L10-L13)
- Confirmation email on request submission: [app.ts#L81-L97](https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/app.ts#L81-L97)
- Email includes: vendor, food, pickup name, time window, request ID
- Error handling: continues if email fails (non-blocking)

---

## Project Architecture

### Tech Stack
- **Backend**: Express.js + TypeScript + MongoDB (Mongoose)
- **Frontend**: Vanilla TypeScript compiled with esbuild (no framework)
- **Database**: MongoDB with 3 collections (requests, fulfillments, events)
- **Email**: Resend API for transactional emails
- **Cleanup**: MongoDB TTL indexes + node-cron backup

### API Endpoints (7 total)
1. `GET /` - Serves homepage
2. `GET /request/new` - Serves request form
3. `GET /resources` - Serves NYU food resources page
4. `GET /api/requests` - Returns active meal requests (status: "requested", limit 20)
5. `GET /api/stats` - Returns total meals shared count (fulfillments)
6. `POST /api/request` - Creates new meal request (rate-limited to 5/min)
7. `GET /api/events` - Returns upcoming food events (limit 10)
8. `DELETE /api/request/:id` - Deletes request (temporary test endpoint)

### Database Schema
**Request Collection:**
- Fields: vendor, food, pickupName, email, pickupWindowText, status, orderNumber, eta, expiresAt
- TTL: Auto-deletes 24 hours after creation
- Status: "requested" | "placed"

**Fulfillment Collection:**
- Fields: requestId (ref), orderNumber, eta, placedAt
- Purpose: Track completed orders for stats

**Event Collection:**
- Fields: where, when, foodType, notes, expiresAt
- TTL: Auto-deletes 2 hours after event time

### Features Implemented
**Request Form:**
- ASAP or custom time range selection
- Dynamic datetime inputs (show/hide)
- Client-side validation
- Human-readable time window formatting

**Homepage:**
- Dynamic request cards with 3-level hierarchy (window → pickup → action)
- Real-time stats (active requests + total meals shared)
- Modal detail view for full request info
- Purple hover glow effect on cards
- Event cards for free food announcements

**Additional Pages:**
- "How It Works" section (2-column: Requesters | Givers)
- NYU Food Resources page with external links
- Responsive design (5 breakpoints: 480px, 640px, 768px, 1024px, 1280px)

### Data Flow
1. User fills form → POST `/api/request` (rate-limited)
2. Server validates, creates MongoDB doc, sends confirmation email via Resend
3. Homepage fetches via GET `/api/requests` and GET `/api/stats`
4. Client renders cards dynamically with TypeScript
5. MongoDB TTL index auto-deletes expired requests after 24h
6. Cron job runs hourly as cleanup backup
