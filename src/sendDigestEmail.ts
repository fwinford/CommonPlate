import { IRequest, ISubscriber } from "../models/db.js";
import { sendEmailSafe } from "./emailHelpers.js";

// Helper to send a digest email to a subscriber
export async function sendDigestEmail(subscriber: ISubscriber, requests: IRequest[]) {
  if (!subscriber.unsubToken) throw new Error("Missing unsubToken");
  const BASE_URL = process.env.BASE_URL || "https://commonplatenyu.org";
  const unsubUrl = `${BASE_URL}/api/unsubscribe?token=${encodeURIComponent(subscriber.unsubToken)}`;
  const htmlList = requests.map(req => `
    <li>
      <strong>${req.vendor}</strong> — ${req.food}<br>
      <em>${req.pickupName}</em> · ${req.pickupWindowText}<br>
      <a href="${BASE_URL}/request/${req._id}/fulfill">Fulfill this request</a>
    </li>
  `).join("");
  const html = `
    <h2>${requests.length} new meal requests in the last hour</h2>
    <ul>${htmlList}</ul>
    <hr>
    <p style="font-size:0.9em;">To unsubscribe from these alerts, <a href="${unsubUrl}">click here</a>.</p>
  `;
  const textList = requests.map(req => `- ${req.vendor} — ${req.food}\n  ${req.pickupName} · ${req.pickupWindowText}\n  Fulfill: ${BASE_URL}/request/${req._id}/fulfill`).join("\n\n");
  const text = `${requests.length} new meal requests in the last hour\n\n${textList}\n\nTo unsubscribe: ${unsubUrl}`;
  await sendEmailSafe({
    from: process.env.FROM_EMAIL || "CommonPlate <onboarding@resend.dev>",
    to: subscriber.email,
    subject: `${requests.length} new meal requests in the last hour`,
    html,
    text,
  });
}
