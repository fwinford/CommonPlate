import { IRequest, ISubscriber } from "../models/db.js";
import { Resend } from "resend";

const FROM_EMAIL = process.env.FROM_EMAIL || "CommonPlate <onboarding@resend.dev>";
const BASE_URL = process.env.BASE_URL || "https://commonplatenyu.org";
const resend = new Resend(process.env.RESEND_API_KEY);

function escapeHtml(str: any) {
	if (str == null) return '';
	return String(str)
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;')
		.replace(/'/g, '&#39;');
}

// Robust email sender: wraps resend.emails.send and handles errors
export async function sendEmailSafe(opts: Parameters<typeof resend.emails.send>[0]): Promise<{ success: boolean; error?: string; }> {
	try {
		const result = await resend.emails.send(opts);
		if ((result as any).error) {
			const err = (result as any).error;
			console.error("[Resend] send returned error:", err);
			// Throw so callers (which expect exceptions) will handle failures consistently
			throw new Error(String(err.message || JSON.stringify(err)));
		}
		return { success: true };
	} catch (err: any) {
		// Quota, network error, or other failure — throw so calling code can decide how to handle
		console.error("[Resend Exception]", err);
		throw new Error(String(err?.message || err));
	}
}

export async function sendNewRequestAlert(subscriber: ISubscriber, request: IRequest) {
	if (!subscriber.unsubToken) throw new Error("Missing unsubToken");
	const fulfillUrl = `${BASE_URL}/request/${request._id}/fulfill`;
	const unsubUrl = `${BASE_URL}/api/unsubscribe?token=${encodeURIComponent(subscriber.unsubToken)}`;
	const html = `
		<h2>New meal request: ${request.vendor} · ${request.pickupWindowText}</h2>
		<ul>
			<li><strong>Vendor:</strong> ${request.vendor}</li>
			<li><strong>Food:</strong> ${request.food}</li>
			<li><strong>Pickup Name:</strong> ${request.pickupName}</li>
			<li><strong>Pickup Window:</strong> ${request.pickupWindowText}</li>
		</ul>
		<p><a href="${fulfillUrl}">Click here to fulfill this request</a></p>
		<hr>
		<p style="font-size:0.9em;">To unsubscribe from these alerts, <a href="${unsubUrl}">click here</a>.</p>
	`;
	const text = `New meal request: ${request.vendor} · ${request.pickupWindowText}\n\nVendor: ${request.vendor}\nFood: ${request.food}\nPickup Name: ${request.pickupName}\nPickup Window: ${request.pickupWindowText}\n\nFulfill: ${fulfillUrl}\n\nTo unsubscribe: ${unsubUrl}`;
	await sendEmailSafe({
		from: FROM_EMAIL,
		to: subscriber.email,
		subject: `New meal request: ${request.vendor} · ${request.pickupWindowText}`,
		html,
		text,
	});
}

// Note: the old single-purpose contact email helper was removed in favor of
// the combined `sendFulfillmentEmail` which includes donor message and reply-to.

// Combined fulfillment email: includes order details, optional ETA and donor message,
// and always shows a reply-to address so the requester can reply directly.
export async function sendFulfillmentEmail(
	request: IRequest,
	orderNumber: string,
	eta?: string | undefined,
	donorMessage?: string | undefined,
	donorEmail?: string | undefined
) {
	const to = (request as any).email || (request as any).requesterEmail;
	if (!to) throw new Error("Missing requester email on request");

	const replyTo = donorEmail || undefined;
	const subject = "Someone is fulfilling your CommonPlate meal request";

	const html = `
		<h2>Great news! Someone has fulfilled your request from ${escapeHtml(request.vendor)}</h2>

		<h3>Request details</h3>
		<p><strong>Vendor:</strong> ${escapeHtml(request.vendor)}</p>
		<p><strong>Pickup name:</strong> ${escapeHtml(request.pickupName)}</p>
		<p><strong>Pickup window:</strong> ${escapeHtml(request.pickupWindowText)}</p>

		<h3>Order details</h3>
		<p><strong>Order number:</strong> ${escapeHtml(orderNumber)}</p>
		${eta ? `<p><strong>ETA:</strong> ${escapeHtml(eta)}</p>` : ''}

		${donorMessage ? `<h4>Message from your swipes donor</h4><p>${escapeHtml(donorMessage).replace(/\n/g, '<br>')}</p>` : ''}

		<p>You can reply to them at: <a href="mailto:${escapeHtml(replyTo || '')}">${escapeHtml(replyTo || '')}</a></p>

		<p style="margin-top: 1.5rem;">Thanks for using CommonPlate!</p>
		<p style="color: #6b6b6b; font-size: 0.9rem; margin-top: 1rem;">This is an automated message from CommonPlate @ NYU</p>
	`;

	const textParts = [
		`Great news! Someone has fulfilled your request from ${request.vendor}.`,
		``,
		`Request details:`,
		`Vendor: ${request.vendor}`,
		`Pickup name: ${request.pickupName}`,
		`Pickup window: ${request.pickupWindowText}`,
		``,
		`Order details:`,
		`Order number: ${orderNumber}`,
	];
	if (eta) textParts.push(`ETA: ${eta}`);
	if (donorMessage) textParts.push(`\nMessage from your swipes donor:\n${donorMessage}`);
	if (replyTo) textParts.push(`\nYou can reply to them at: ${replyTo}`);
	textParts.push('\nThanks for using CommonPlate!');

	const text = textParts.join('\n');

	await sendEmailSafe({
		from: FROM_EMAIL,
		to,
		subject,
		html,
		text,
		...(replyTo ? { reply_to: replyTo } : {}),
	});
}
