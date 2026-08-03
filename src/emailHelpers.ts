import { IRequest, ISubscriber } from "../models/db.js";
import { Resend } from "resend";
import { escapeHtml } from "./htmlEscape.js";

const FROM_EMAIL = process.env.FROM_EMAIL || "CommonPlate <onboarding@resend.dev>";
const BASE_URL = process.env.BASE_URL || "https://commonplatenyu.org";
const resend = new Resend(process.env.RESEND_API_KEY);

type EmailRequestOptions = NonNullable<Parameters<typeof resend.emails.send>[1]> & {
	signal?: AbortSignal;
};

export async function sendEmailSafe(
	opts: Parameters<typeof resend.emails.send>[0],
	requestOptions?: EmailRequestOptions
): Promise<{ success: boolean; error?: string; }> {
	try {
		const result = await resend.emails.send(opts, requestOptions);
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

// Strictly shorter than the subscribe send lease, so a provider that never
// answers releases its lifecycle long before the lease expires.
export const CONFIRMATION_EMAIL_TIMEOUT_MS = 30_000;

export class EmailProviderTimeoutError extends Error {
	constructor(timeoutMs: number) {
		super(`Email provider did not answer within ${timeoutMs}ms`);
		this.name = "EmailProviderTimeoutError";
	}
}

/**
 * Trusted configuration only. The confirmation link carries a bearer token, so
 * it must never be built from `Host`, `X-Forwarded-Host`, or a request
 * protocol: a hostile header would otherwise redirect a real subscriber's
 * confirmation token to an attacker-controlled origin.
 */
export function confirmationBaseUrl(): string {
	return process.env.BASE_URL || "https://commonplatenyu.org";
}

export async function sendSubscriptionConfirmationEmail(
	email: string,
	rawToken: string,
	timeoutMs: number = CONFIRMATION_EMAIL_TIMEOUT_MS
): Promise<void> {
	const confirmUrl = `${confirmationBaseUrl().replace(/\/+$/, "")}/api/subscribe/confirm?token=${encodeURIComponent(rawToken)}`;
	const htmlConfirmUrl = escapeHtml(confirmUrl);

	// A real abort, not a racing promise: the Resend SDK spreads request
	// options into the underlying fetch `RequestInit`, so this cancels the
	// in-flight HTTP request instead of abandoning it while it holds a lease.
	const deadline = new AbortController();
	const timer = setTimeout(() => deadline.abort(), timeoutMs);

	try {
		await sendEmailSafe({
			from: FROM_EMAIL,
			to: email,
			subject: "Confirm your CommonPlate subscription",
			html: `<p>Please confirm your subscription to CommonPlate alerts:</p><p><a href="${htmlConfirmUrl}">${htmlConfirmUrl}</a></p><p>If you didn't request this, you can ignore this email.</p>`,
			text: `Confirm your CommonPlate subscription: ${confirmUrl}\n\nIf you didn't request this, you can ignore this email.`,
		}, { signal: deadline.signal });
	} catch (error) {
		// The SDK reports an aborted fetch as an indistinguishable transport
		// failure, so the deadline we own is what identifies a timeout.
		if (deadline.signal.aborted) throw new EmailProviderTimeoutError(timeoutMs);
		throw error;
	} finally {
		clearTimeout(timer);
	}
}

export async function sendNewRequestAlert(subscriber: ISubscriber, request: IRequest) {
	if (!subscriber.unsubToken) throw new Error("Missing unsubToken");
	const requestListUrl = `${BASE_URL.replace(/\/+$/, "")}/`;
	const unsubUrl = `${BASE_URL}/api/unsubscribe?token=${encodeURIComponent(subscriber.unsubToken)}`;
	const htmlVendor = escapeHtml(request.vendor);
	const htmlFood = escapeHtml(request.food);
	const htmlPickupWindow = escapeHtml(request.pickupWindowText);
	const html = `
			<h2>New meal request: ${htmlVendor} · ${htmlPickupWindow}</h2>
			<ul>
				<li><strong>Vendor:</strong> ${htmlVendor}</li>
				<li><strong>Food:</strong> ${htmlFood}</li>
				<li><strong>Pickup Window:</strong> ${htmlPickupWindow}</li>
			</ul>
		<p><a href="${requestListUrl}">View meal request</a></p>
		<hr>
		<p style="font-size:0.9em;">To unsubscribe from these alerts, <a href="${unsubUrl}">click here</a>.</p>
	`;
	const text = `New meal request: ${request.vendor} · ${request.pickupWindowText}\n\nVendor: ${request.vendor}\nFood: ${request.food}\nPickup Window: ${request.pickupWindowText}\n\nView meal request: ${requestListUrl}\n\nTo unsubscribe: ${unsubUrl}`;
	await sendEmailSafe({
		from: FROM_EMAIL,
		to: subscriber.email,
		subject: `New meal request: ${request.vendor} · ${request.pickupWindowText}`,
		html,
		text,
	});
}


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
		// `replyTo` is the option name the Resend SDK reads; it maps it to the
		// wire field `reply_to` itself. Passing `reply_to` here is silently
		// dropped, which would send the requester notification with no Reply-To.
		...(replyTo ? { replyTo } : {}),
	});
}
