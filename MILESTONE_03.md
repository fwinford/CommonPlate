Milestone 03
===

Repository Link
---
https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford

URL for form 1 (from previous milestone) 
---
http://localhost:3000/request/new

**Request Food Form** - Users can submit a request for food by providing:
- Vendor (dropdown of dining halls)
- Food item description
- Pickup name
- Pickup time window (ASAP or scheduled)
- Email for notifications

Special Instructions for Form 1
---
1. Start the server with `npm run dev`
2. MongoDB Atlas is configured through the `MONGO_URI` environment variable.
3. `.env` file contains `RESEND_API_KEY` for email functionality
4. Form validates all required fields and limits users to 3 requests per day
5. Upon submission, user receives a confirmation email

URL for form 2 (for current milestone)
---
http://localhost:3000/request/{requestId}/fulfill

**Fulfill Request Form** - Appears when a giver clicks "Order This" on a request card. Allows them to:
- View request summary (food item, vendor, pickup name, time window)
- Enter order number (required)
- Enter optional ETA (e.g., "10 min", "20 min")
- Submit to notify the requester

After submission, a thank you GIF modal appears with a community appreciation message.

Special Instructions for Form 2
---
1. First create a request using Form 1 or navigate to homepage to see active requests
2. Click "Order This" button on any request card to go directly to the fulfill page
3. Or click anywhere on the card to see full details in a modal, then click "I'll Order This"
4. Enter an order number and optionally an ETA
5. Upon submission:
   - Requester receives an email with order details
   - A thank you modal appears for 3.5 seconds with a GIF
   - Page redirects to homepage after 3 seconds

URL(s) to github repository with commits that show progress on research
--- 
**Email Integration Research:**
- https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/app.ts#L150-L171
- Implemented Resend API for transactional emails
- Researched best practices for email templates and error handling

**Rate Limiting Research:**
- https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/app.ts#L22-L23
- Implemented express-rate-limit to prevent abuse
- Daily request limit per email (3 requests/day)

**Cron Jobs Research:**
- https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/app.ts#L276-L288
- Implemented node-cron for automated cleanup of expired requests
- Runs hourly to supplement MongoDB TTL indexes

**Client-Side TypeScript Build:**
- https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/build-client.mjs
- Researched esbuild for fast TypeScript compilation
- Generates sourcemaps for debugging

**Modal UX Patterns:**
- https://github.com/nyu-csci-ua-0467-001-002-fall-2025/final-project-fwinford/blob/main/public/js/fulfill.js#L47-L123
- Researched accessible modal patterns with keyboard navigation
- Implemented auto-dismiss with manual close option

References 
---
**Resend Email API:**
- Official docs: https://resend.com/docs/send-with-nodejs
- Used for transactional email implementation in app.ts

**Express Rate Limiting:**
- npm package: https://www.npmjs.com/package/express-rate-limit
- Applied to form submission endpoints

**MongoDB TTL Indexes:**
- Documentation: https://www.mongodb.com/docs/manual/core/index-ttl/
- Used for automatic request expiration (24 hours)

**Node-Cron:**
- Documentation: https://www.npmjs.com/package/node-cron
- Used for hourly cleanup job as backup to TTL

**esbuild:**
- Documentation: https://esbuild.github.io/
- Used for fast client-side TypeScript bundling

**Accessibility Best Practices:**
- WCAG color contrast guidelines for button colors
- Keyboard navigation for modals
- ARIA labels for screen readers

---

## Architecture Overview

### System Architecture

CommonPlate follows a **client-server architecture** with a clear separation between the frontend (static HTML/CSS/JS) and backend (Node.js/Express API).

```
┌─────────────────────────────────────────────────────────────┐
│                         CLIENT LAYER                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │   home.html  │  │new-request   │  │  fulfill.html│      │
│  │   home.ts    │  │   .html/.ts  │  │  fulfill.ts  │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│         │                  │                  │             │
│         └──────────────────┴──────────────────┘             │
│                            │                                │
│                     (esbuild compiles                       │
│                   TypeScript → JavaScript)                  │
│                            │                                │
└────────────────────────────┼────────────────────────────────┘
                             │
                    HTTP/JSON API Calls
                             │
┌────────────────────────────┼────────────────────────────────┐
│                      SERVER LAYER (app.ts)                  │
│                            │                                │
│  ┌─────────────────────────▼──────────────────────────┐    │
│  │          Express.js REST API Routes                │    │
│  │  • GET  /api/requests    (list all active)        │    │
│  │  • GET  /api/request/:id (single request)         │    │
│  │  • POST /api/request     (create new request)     │    │
│  │  • POST /api/request/:id/fulfill (mark as placed) │    │
│  │  • GET  /api/stats       (total meals shared)     │    │
│  └────────────────────────────────────────────────────┘    │
│            │                              │                 │
│            │ (Mongoose ODM)               │ (Resend API)    │
│            ▼                              ▼                 │
│  ┌──────────────────┐          ┌──────────────────┐        │
│  │  MongoDB Atlas   │          │  Email Service   │        │
│  │  or Local DB     │          │   (Resend)       │        │
│  │                  │          │                  │        │
│  │ Collections:     │          │ • Confirmation   │        │
│  │ • mealrequests   │          │ • Fulfillment    │        │
│  │ • fulfillments   │          │   notification   │        │
│  │ • events         │          └──────────────────┘        │
│  └──────────────────┘                                       │
│            │                                                │
│  ┌─────────▼──────────┐                                    │
│  │   Node-Cron Job    │                                    │
│  │ (Hourly cleanup)   │                                    │
│  └────────────────────┘                                    │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow

**1. Request Creation Flow:**
```
User fills form → POST /api/request → Validate data → 
Check daily limit → Create DB record → Send confirmation email → 
Return success
```

**2. Request Fulfillment Flow:**
```
User clicks "Order This" → Navigate to /request/:id/fulfill → 
Load request details (GET /api/request/:id) → 
User enters order number → POST /api/request/:id/fulfill → 
Update DB status → Create fulfillment record → 
Send notification email → Show thank you modal → 
Redirect to home
```

**3. Homepage Display Flow:**
```
Load page → Fetch stats (GET /api/stats) → 
Fetch requests (GET /api/requests) → 
Sort by ASAP first, then by time → Render cards → 
User interaction (click card or button)
```

### Technology Stack

**Frontend:**
- HTML5, CSS3 (mobile-first responsive design)
- TypeScript (compiled to JavaScript via esbuild)
- Vanilla JS (no framework - lightweight and fast)
- Google Fonts (Cabin, Plus Jakarta Sans)

**Backend:**
- Node.js v20+
- Express.js v5 (web framework)
- TypeScript (type safety)
- Mongoose (MongoDB ODM)

**Database:**
- MongoDB (document store)
- TTL indexes for automatic expiration
- Schema validation

**External Services:**
- Resend (email API)
- MongoDB Atlas (production) or local MongoDB (development)

**Build Tools:**
- esbuild (fast TypeScript bundling)
- tsx (TypeScript execution)
- npm scripts for automation

### Database Schema

**MealRequest Collection:**
```typescript
{
  _id: ObjectId,
  vendor: String (required),
  food: String (required),
  pickupName: String (required),
  pickupWindowText: String (required),
  email: String (required),
  windowStart: Date (optional),
  windowEnd: Date (optional),
  status: String (enum: 'requested' | 'placed'),
  orderNumber: String (optional, set when fulfilled),
  eta: Date (optional),
  expiresAt: Date (TTL index, default: 24 hours),
  createdAt: Date,
  updatedAt: Date
}
```

**Fulfillment Collection:**
```typescript
{
  _id: ObjectId,
  requestId: ObjectId (reference to MealRequest),
  orderNumber: String (required),
  eta: Date (optional),
  etaText: String (optional, free-text ETA),
  note: String (optional, removed in latest version),
  createdAt: Date
}
```

**Event Collection** (placeholder for future feature):
```typescript
{
  _id: ObjectId,
  where: String,
  when: Date,
  foodType: String,
  notes: String,
  createdAt: Date
}
```

### Security & Performance

**Security Measures:**
- Rate limiting (5 requests/minute per IP)
- Daily request limit (3 requests/day per email)
- Input validation and sanitization
- XSS prevention via escapeHtml() utility
- CORS protection (Express default)
- No sensitive data stored after fulfillment

**Performance Optimizations:**
- MongoDB indexing (TTL, status, createdAt)
- Client-side code bundling and minification
- Static file caching via Express
- Efficient queries (lean(), limit())
- Background cron job for cleanup (doesn't block requests)
- Sourcemaps for debugging without impacting production

### Deployment Considerations

**Environment Variables (.env):**
```
PORT=3000
MONGO_URI=your_mongodb_connection_string
RESEND_API_KEY=re_xxxxx
```

**Build Commands:**
- `npm run build:client` - Compile TypeScript client code
- `npm run build` - Build entire project
- `npm run dev` - Development mode with hot reload
- `npm start` - Production mode

**Production Ready:**
- MongoDB Atlas configured and connected
- Resend API key configured
- Rate limiting active
- Error handling in place
- TypeScript strict mode enabled
- Body size limits set (100kb)
- TTL indexes configured

---

## Key Features

- Request creation with vendor, food, pickup details
- Homepage displays active requests sorted by urgency (ASAP first)
- Request fulfillment with order number and ETA
- Automated email notifications
- Rate limiting (5/min per IP, 3/day per email)
- Auto-expiration after 24 hours
- Responsive mobile-first design
- WCAG compliant accessibility