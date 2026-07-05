import 'dotenv/config';

// This script calls the admin HTTP endpoint /admin/test-fulfillment which triggers
// the same sendFulfillmentEmail path used by the app. This avoids importing
// project TS modules directly from Node when compiled JS may not be present.

const BASE = process.env.BASE_URL || process.env.ADMIN_BASE || 'http://localhost:3000';
const ADMIN_TOKEN = process.env.ADMIN_TOKEN || '';

(async () => {
  try {
    const url = new URL('/admin/test-fulfillment', BASE).toString();
    console.log(`POSTing test fulfillment to ${url}`);
    const headers = { 'Content-Type': 'application/json' };
    if (ADMIN_TOKEN) headers['x-admin-token'] = ADMIN_TOKEN;

    const resp = await fetch(url, { method: 'POST', headers });
    if (!resp.ok) {
      const body = await resp.text();
      console.error('Admin endpoint returned error:', resp.status, body);
      process.exit(2);
    }
    console.log('Test fulfillment request accepted by server.');
    process.exit(0);
  } catch (err) {
    console.error('Failed to call admin endpoint:', err);
    process.exit(1);
  }
})();
