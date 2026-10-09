// W4-QA1 local QA tooling. Not imported by the backend and never started by it.
//
// A loopback-only stand-in for the Resend HTTP API, so an isolated local
// backend can run the *ordinary* participant verification flow — challenge
// issuance, emailed code, in-app redemption, backend authority issuance —
// without a real mail provider. The backend is pointed at it through the
// Resend SDK's own `RESEND_BASE_URL` seam; nothing in the backend is changed.
//
// What it is not: it mints no authority, calls no backend route, and writes no
// database. It reads exactly one thing out of the mail it receives — the
// six-digit code in a participant verification message — and makes that
// available to the person running local QA, so they can type it into the app.
// Every other message is acknowledged and discarded without being stored,
// logged, or exposed.
import {
  createServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";
import type { AddressInfo } from "node:net";
import { pathToFileURL } from "node:url";

const LOOPBACK_HOST = "127.0.0.1";
const DEFAULT_PORT = 8025;
const MAX_BODY_BYTES = 64 * 1024;
const CODE_LIFETIME_MS = 10 * 60 * 1000;
const MAX_REMEMBERED_RECIPIENTS = 20;
// Matches the subject `sendParticipantVerificationEmail` sends, and nothing else.
const VERIFICATION_SUBJECT = /^(\d{6}) is your CommonPlate verification code$/;
const LOOPBACK_HOST_HEADER = /^(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/i;

type RememberedCode = { code: string; expiresAt: number };

export interface LocalMailSink {
  /** The address actually bound; always loopback. */
  host: string;
  /** The port actually bound (useful when started with port 0). */
  port: number;
  close(): Promise<void>;
}

function readBody(request: IncomingMessage): Promise<string | null> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    let size = 0;
    request.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        resolve(null);
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", () => resolve(null));
  });
}

function normalizeRecipient(value: unknown): string | null {
  const candidate = Array.isArray(value) ? value[0] : value;
  if (typeof candidate !== "string") return null;
  // `"Name <a@b.edu>"` is a valid Resend `to`.
  const bracketed = /<([^<>]+)>\s*$/.exec(candidate);
  const address = (bracketed ? bracketed[1]! : candidate).trim().toLowerCase();
  return /^[^\s@<>]{1,128}@[^\s@<>]{1,128}$/.test(address) ? address : null;
}

export async function startLocalMailSink(
  options: { port?: number; now?: () => number } = {}
): Promise<LocalMailSink> {
  const now = options.now ?? Date.now;
  // Insertion-ordered, so the oldest recipient is the first key to evict.
  const codes = new Map<string, RememberedCode>();

  const remember = (recipient: string, code: string) => {
    codes.delete(recipient);
    codes.set(recipient, { code, expiresAt: now() + CODE_LIFETIME_MS });
    while (codes.size > MAX_REMEMBERED_RECIPIENTS) {
      codes.delete(codes.keys().next().value!);
    }
  };

  const server: Server = createServer((request, response) => {
    handle(request, response).catch(() => {
      // Contained: an unexpected failure answers a fixed 500 and never takes the
      // sink down. Nothing derived from the error or the message is exposed.
      if (!response.headersSent) {
        response.writeHead(500, { "Content-Type": "application/json", "Cache-Control": "no-store" });
        response.end(JSON.stringify({ error: "internal error" }));
      } else {
        response.destroy();
      }
    });
  });

  const handle = async (request: IncomingMessage, response: ServerResponse) => {
    const send = (status: number, body: unknown) => {
      response.writeHead(status, {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      });
      response.end(JSON.stringify(body));
    };

    // A page in a browser must not be able to reach this through a hostname
    // that merely resolves to loopback.
    if (!LOOPBACK_HOST_HEADER.test(request.headers.host ?? "")) {
      send(403, { error: "loopback host only" });
      return;
    }

    let url: URL;
    try {
      url = new URL(request.url ?? "/", `http://${LOOPBACK_HOST}`);
    } catch {
      send(400, { error: "invalid request target" });
      return;
    }

    if (request.method === "POST" && url.pathname === "/emails") {
      const raw = await readBody(request);
      if (raw === null) {
        send(413, { name: "validation_error", message: "body too large" });
        return;
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(raw);
      } catch {
        send(422, { name: "validation_error", message: "invalid JSON" });
        return;
      }
      // `null`, numbers, strings, and arrays parse as valid JSON but are not a
      // message; reading a field off them would throw or silently misread.
      if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
        send(422, { name: "validation_error", message: "invalid payload" });
        return;
      }
      const payload = parsed as { to?: unknown; subject?: unknown };
      const subject = typeof payload.subject === "string" ? payload.subject : "";
      const recipient = normalizeRecipient(payload.to);
      const match = VERIFICATION_SUBJECT.exec(subject);
      if (match && recipient) {
        remember(recipient, match[1]!);
      } else {
        // Counted only; the recipient, subject, and body are never kept.
        console.log("[mail-sink] discarded a non-verification message");
      }
      send(200, { id: "local-mail-sink" });
      return;
    }

    if (request.method === "GET" && url.pathname === "/latest-code") {
      const recipient = normalizeRecipient(url.searchParams.get("to"));
      const entry = recipient ? codes.get(recipient) : undefined;
      if (!recipient || !entry || entry.expiresAt <= now()) {
        if (recipient && entry) codes.delete(recipient);
        send(404, { error: "no current verification code for that address" });
        return;
      }
      send(200, { to: recipient, code: entry.code });
      return;
    }

    send(404, { error: "not found" });
  };

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    // Bound to loopback explicitly; there is no option to widen it.
    server.listen(options.port ?? 0, LOOPBACK_HOST, resolve);
  });

  const bound = server.address() as AddressInfo;
  return {
    host: bound.address,
    port: bound.port,
    close: () =>
      new Promise<void>((resolve) => {
        server.close(() => resolve());
        server.closeAllConnections();
      }),
  };
}

const entryPath = process.argv[1];
if (entryPath && import.meta.url === pathToFileURL(entryPath).href) {
  const configured = process.env.QA_MAIL_SINK_PORT;
  const port = configured ? Number(configured) : DEFAULT_PORT;
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    console.error("QA_MAIL_SINK_PORT must be an integer between 1 and 65535.");
    process.exitCode = 1;
  } else {
    try {
      const sink = await startLocalMailSink({ port });
      console.log(`local mail sink listening on http://${LOOPBACK_HOST}:${sink.port}`);
    } catch {
      console.error("Could not start the local mail sink (is the port already in use?).");
      process.exitCode = 1;
    }
  }
}
