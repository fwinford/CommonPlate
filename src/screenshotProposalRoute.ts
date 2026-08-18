import express, {
  type Express,
  type NextFunction,
  type Request,
  type Response,
} from "express";
import { z } from "zod";
import { sendDay4Error } from "./day4Errors.js";
import {
  pausePublicAction,
  PUBLIC_ACTIONS_PAUSED_ENV,
} from "./publicActionsPause.js";
import {
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import {
  callScreenshotProvider,
  type ProviderCallResult,
} from "./screenshotProposalProvider.js";
import { validateProviderOutput } from "./screenshotProposalValidation.js";
import { evaluateEligibility } from "./screenshotEligibility.js";
import type { ScreenshotProposalResponseBody } from "./screenshotProposalTypes.js";

/**
 * W4-S1 non-authoritative proposal boundary. Deliberately not
 * `/api/request` or any `/api/request/:id/...` path: this route can never
 * call `createRequest`, mint/consume an operation identity, or touch
 * `RequestOperation`/D1, and a distinct path keeps that true by
 * construction rather than by handler discipline alone.
 */
export const SCREENSHOT_PROPOSAL_ROUTE_PATH = "/api/request/screenshot-proposal";

export const IMAGE_PROPOSAL_UNAVAILABLE_MESSAGE =
  "AI screenshot assistance is temporarily unavailable";

export const INVALID_IMAGE_CODE = "INVALID_IMAGE";
export const INVALID_IMAGE_MESSAGE =
  "Choose a single supported screenshot image.";

export const PROVIDER_UNAVAILABLE_CODE = "PROVIDER_UNAVAILABLE";
export const PROVIDER_UNAVAILABLE_MESSAGE =
  "We couldn’t analyze that screenshot right now. You can still fill out the form manually.";

export const PROPOSAL_FAILED_CODE = "SCREENSHOT_PROPOSAL_FAILED";
export const PROPOSAL_FAILED_MESSAGE =
  "We couldn’t analyze that screenshot. You can still fill out the form manually.";

/**
 * A single normalized screenshot, base64-encoded. iOS performs local
 * normalization (resize/compress) before upload (engineering-owned exact
 * dimensions/quality); this is still an explicit, bounded server-side cap —
 * independent of what any client claims to have sent — rather than trusting
 * client-side normalization alone.
 */
const MAX_IMAGE_BYTES = 5_000_000;

/**
 * The explicit bounded image transport this route owns, separate from the
 * 100 KB global JSON parser (`app.ts`) request-create and every other route
 * shares. Registered ahead of the global parser, exactly like
 * `registerParticipantVerificationRoutes`, so this route's own limit is what
 * actually governs its body rather than the global one rejecting it first.
 */
const SCREENSHOT_BODY_LIMIT = "7mb";

/**
 * Bounded so a caller cannot use this field to smuggle an arbitrarily large
 * payload past the image size cap. A real screenshot's on-device Vision OCR
 * transcription is a few hundred to a few thousand characters at most.
 */
const MAX_LOCAL_EVIDENCE_TEXT_LENGTH = 20_000;

const screenshotProposalBodySchema = z
  .object({
    imageBase64: z.string().min(1),
    mimeType: z.enum(["image/jpeg", "image/png"]),
    /**
     * On-device Apple Vision OCR transcription of the selected screenshot —
     * a different engine than the OpenAI provider below, produced and sent
     * before that provider is ever called. This is the sole eligibility and
     * meal-swipe-corroboration evidence source; the provider's own output is
     * never used to validate itself. May be empty (an illegible/blank
     * image), which the eligibility rule below simply rejects.
     */
    localEvidenceText: z.string().max(MAX_LOCAL_EVIDENCE_TEXT_LENGTH),
  })
  .strict();

/**
 * Strict base64 acceptance ahead of decoding: `Buffer.from(str, "base64")`
 * does not throw on invalid input — it silently drops unrecognized
 * characters — so a malformed payload would otherwise decode into whatever
 * bytes happened to remain rather than being refused.
 *
 * A single flat character class with no nested repetition, checked
 * separately from the length/multiple-of-4 requirement: an equivalent
 * pattern built from a repeated 4-character group
 * (`(?:[A-Za-z0-9+/]{4})*...`) hit V8's regex call-stack limit on inputs at
 * this route's multi-megabyte size ceiling. `={0,2}$` anchors padding to the
 * very end only, since the preceding `+` class excludes `=` itself — no
 * interior padding character can match.
 */
const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;

function isStrictBase64(value: string): boolean {
  return value.length > 0 && value.length % 4 === 0 && BASE64_PATTERN.test(value);
}

/** Full 8-byte PNG signature, not just its first 4 bytes. */
const PNG_SIGNATURE = Buffer.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
]);
/** Signature (8) + the smallest possible complete chunk stream: an IHDR
 * chunk (8 + 13 + 4 CRC bytes) and an IEND chunk (8 + 0 + 4 CRC bytes). */
const PNG_MIN_STRUCTURAL_BYTES = 8 + (8 + 13 + 4) + (8 + 0 + 4);
/** Defense against a pathological many-tiny-chunks payload; a real PNG
 * this route's size ceiling would ever encounter needs nowhere near this
 * many chunks. */
const PNG_MAX_CHUNKS = 512;

/** Standard IEEE 802.3 CRC-32 table, used to verify each PNG chunk's CRC —
 * the same algorithm every PNG encoder/decoder uses. Verifying it is what
 * turns "these bytes have the right shape" into "these bytes are a
 * self-consistent chunk stream," without decoding image content. */
const CRC32_TABLE: Uint32Array = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(buffer: Buffer): number {
  let crc = 0xffffffff;
  for (let i = 0; i < buffer.length; i++) {
    crc = CRC32_TABLE[(crc ^ buffer[i]!) & 0xff]! ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

/**
 * Valid PNG bit-depth values per color type (spec table 11.1). A combination
 * outside this table cannot be decoded by any conforming PNG decoder — it is
 * not merely unusual, it is an impossible image.
 */
const PNG_VALID_BIT_DEPTHS_BY_COLOR_TYPE: Readonly<Record<number, readonly number[]>> = {
  0: [1, 2, 4, 8, 16], // grayscale
  2: [8, 16], // truecolor
  3: [1, 2, 4, 8], // indexed-color
  4: [8, 16], // grayscale + alpha
  6: [8, 16], // truecolor + alpha
};

/**
 * Validates the fixed 13-byte IHDR payload against every invariant the PNG
 * spec places on it, independent of chunk shape/CRC (which the caller has
 * already verified). A CRC-valid IHDR whose *content* describes an
 * impossible image — zero width/height, an invalid bit-depth/color-type
 * combination, a non-zero compression/filter method, or an out-of-range
 * interlace method — is not a real PNG a conforming encoder could ever have
 * produced, and must be refused before this payload is treated as a
 * supported image.
 */
function isValidIhdrSemantics(ihdr: Buffer): boolean {
  const width = ihdr.readUInt32BE(0);
  const height = ihdr.readUInt32BE(4);
  const bitDepth = ihdr[8]!;
  const colorType = ihdr[9]!;
  const compressionMethod = ihdr[10]!;
  const filterMethod = ihdr[11]!;
  const interlaceMethod = ihdr[12]!;

  if (width === 0 || height === 0) return false;
  const validBitDepths = PNG_VALID_BIT_DEPTHS_BY_COLOR_TYPE[colorType];
  if (!validBitDepths || !validBitDepths.includes(bitDepth)) return false;
  // The only value ever defined for either method; any other value is not
  // merely unsupported, it is not a valid PNG.
  if (compressionMethod !== 0) return false;
  if (filterMethod !== 0) return false;
  // 0 = no interlace, 1 = Adam7; nothing else is defined.
  if (interlaceMethod !== 0 && interlaceMethod !== 1) return false;

  return true;
}

/**
 * Walks the complete PNG chunk stream after the 8-byte signature, the
 * bounded structural parser this format gets instead of full image
 * decoding. Requires, in order: the first chunk is exactly `IHDR` with its
 * fixed 13-byte payload and semantically valid content
 * (`isValidIhdrSemantics`); every chunk's declared length stays inside the
 * buffer; every chunk's CRC-32 (computed over its own type+data, the same
 * way every PNG encoder computes it) matches its stored CRC exactly; at
 * least one `IDAT` chunk appears; and the stream ends with a zero-length
 * `IEND` chunk that is the last thing in the buffer — not merely present
 * somewhere, but exactly consuming every remaining byte.
 *
 * This rejects a payload that has a well-formed `IHDR` header (the right
 * length, type, and even a correctly recomputed CRC) but content describing
 * an impossible image — e.g. width `0` — which a shape-and-CRC-only check
 * cannot catch, since an attacker can always recompute a valid CRC for
 * whatever 13 bytes they choose.
 */
function isStructurallyValidPng(buffer: Buffer): boolean {
  if (buffer.length < PNG_MIN_STRUCTURAL_BYTES) return false;
  if (!buffer.subarray(0, 8).equals(PNG_SIGNATURE)) return false;

  let offset = 8;
  let chunkIndex = 0;
  let sawIDAT = false;

  while (offset < buffer.length) {
    chunkIndex += 1;
    if (chunkIndex > PNG_MAX_CHUNKS) return false;
    if (offset + 8 > buffer.length) return false;

    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString("ascii", offset + 4, offset + 8);
    const dataStart = offset + 8;
    const dataEnd = dataStart + length;
    const crcEnd = dataEnd + 4;
    if (crcEnd > buffer.length) return false;

    if (chunkIndex === 1) {
      if (type !== "IHDR" || length !== 13) return false;
      if (!isValidIhdrSemantics(buffer.subarray(dataStart, dataEnd))) return false;
    }

    const storedCrc = buffer.readUInt32BE(dataEnd);
    const computedCrc = crc32(buffer.subarray(offset + 4, dataEnd));
    if (storedCrc !== computedCrc) return false;

    if (type === "IDAT") sawIDAT = true;
    if (type === "IEND") {
      return length === 0 && sawIDAT && crcEnd === buffer.length;
    }

    offset = crcEnd;
  }

  return false;
}

const JPEG_SOI_MARKER = Buffer.from([0xff, 0xd8]);
const JPEG_EOI_MARKER = Buffer.from([0xff, 0xd9]);
/** A real screenshot is comfortably larger than this; nothing this small can
 * hold usable Grubhub screen content regardless of format validity. */
const JPEG_MIN_STRUCTURAL_BYTES = 100;
/** Same defensive bound as `PNG_MAX_CHUNKS`, for marker segments. */
const JPEG_MAX_SEGMENTS = 512;
/** Start-Of-Frame markers (baseline/progressive/etc. DCT), excluding
 * 0xC4 (DHT), 0xC8 (reserved/JPG), and 0xCC (DAC) — those share the 0xC0–0xCF
 * range but are not frame headers. */
function isStartOfFrameMarker(marker: number): boolean {
  return marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
}
const JPEG_START_OF_SCAN_MARKER = 0xda;
/** Markers with no following length-prefixed segment. */
function isStandaloneMarker(marker: number): boolean {
  return marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7);
}

/**
 * SOF payload: precision(1) + height(2) + width(2) + numComponents(1),
 * followed by 3 bytes (id, sampling factors, quant-table selector) per
 * component. The length field itself (2 bytes) plus that fixed 6-byte
 * header is the smallest a segment declaring at least one component can be.
 */
const JPEG_SOF_FIXED_HEADER_BYTES = 6;
const JPEG_SOF_MIN_SEGMENT_LENGTH = 2 + JPEG_SOF_FIXED_HEADER_BYTES + 3;
/** Every real encoder this route accepts a screenshot from produces
 * grayscale (1), YCbCr (3), or CMYK/YCCK (4) frames; nothing else is a
 * plausible photographic/UI screenshot. */
const JPEG_MAX_FRAME_COMPONENTS = 4;

/** SOS payload: numComponents(1), 2 bytes per scan component (selector +
 * table selectors), then spectral-selection/approximation (3 bytes). */
const JPEG_SOS_FIXED_HEADER_BYTES = 1 + 3;
const JPEG_SOS_MIN_SEGMENT_LENGTH = 2 + JPEG_SOS_FIXED_HEADER_BYTES + 2;

interface JpegFrame {
  componentCount: number;
}

/**
 * Validates a Start-Of-Frame segment's actual payload — not merely that a
 * SOF marker is present with *some* length >= 2. `segmentStart` points at
 * the segment's 2-byte length field; the caller has already bounds-checked
 * `segmentStart + segmentLength` against the buffer. Requires: nonzero
 * width and height (a zero-dimension frame is not a real image), a
 * component count in the range real encoders produce, and — critically —
 * the segment's declared length exactly matching what that component count
 * requires, so a segment claiming a component but not actually carrying its
 * 3-byte descriptor is refused rather than silently accepted.
 */
function parseStartOfFrame(
  buffer: Buffer,
  segmentStart: number,
  segmentLength: number
): JpegFrame | null {
  if (segmentLength < JPEG_SOF_MIN_SEGMENT_LENGTH) return null;
  const payloadStart = segmentStart + 2;
  const height = buffer.readUInt16BE(payloadStart + 1);
  const width = buffer.readUInt16BE(payloadStart + 3);
  const componentCount = buffer[payloadStart + 5]!;
  if (width === 0 || height === 0) return null;
  if (componentCount < 1 || componentCount > JPEG_MAX_FRAME_COMPONENTS) return null;
  const expectedLength = 2 + JPEG_SOF_FIXED_HEADER_BYTES + 3 * componentCount;
  if (segmentLength !== expectedLength) return null;
  return { componentCount };
}

/**
 * Validates a Start-Of-Scan segment's actual payload against the frame it
 * must belong to (`frame`, from a SOF this walker has already accepted
 * earlier in the same stream — a SOS with no prior SOF is refused by the
 * caller, never reaching this function). Requires: at least one scan
 * component, no more scan components than the frame actually declared (a
 * scan cannot reference a component the frame never defined), and the
 * segment's declared length exactly matching what that scan component count
 * requires.
 */
function isValidStartOfScan(
  buffer: Buffer,
  segmentStart: number,
  segmentLength: number,
  frame: JpegFrame
): boolean {
  if (segmentLength < JPEG_SOS_MIN_SEGMENT_LENGTH) return false;
  const payloadStart = segmentStart + 2;
  const scanComponentCount = buffer[payloadStart]!;
  if (scanComponentCount < 1 || scanComponentCount > frame.componentCount) return false;
  const expectedLength = 2 + 1 + 2 * scanComponentCount + 3;
  return segmentLength === expectedLength;
}

/**
 * Walks JPEG marker segments after the SOI marker — the bounded structural
 * parser this format gets instead of full image decoding. Requires a
 * genuine Start-Of-Frame segment with valid, internally consistent content
 * (`parseStartOfFrame`) followed by a Start-Of-Scan segment whose content is
 * valid and consistent with that frame (`isValidStartOfScan`) — not merely
 * that SOF/SOS markers are present with *some* length. Both are discovered
 * by actually walking length-prefixed segments rather than assumed from a
 * prefix. Once a valid SOS is confirmed this stops walking — the
 * entropy-coded scan data that follows is not re-parsed as segments — but
 * the buffer was already confirmed to end with a genuine EOI marker before
 * this walk begins, so "SOI + APP0 + padding + EOI" (no real frame/scan
 * structure at all) fails here even though the outer bytes look plausible,
 * and so does "SOF/SOS present but with an empty/impossible payload."
 */
function isStructurallyValidJpeg(buffer: Buffer): boolean {
  if (buffer.length < JPEG_MIN_STRUCTURAL_BYTES) return false;
  if (!buffer.subarray(0, 2).equals(JPEG_SOI_MARKER)) return false;
  if (!buffer.subarray(buffer.length - 2).equals(JPEG_EOI_MARKER)) return false;

  let offset = 2;
  let segmentIndex = 0;
  let frame: JpegFrame | null = null;

  while (offset < buffer.length - 1) {
    segmentIndex += 1;
    if (segmentIndex > JPEG_MAX_SEGMENTS) return false;
    if (buffer[offset] !== 0xff) return false;

    // Marker padding: a run of extra 0xFF fill bytes may precede the
    // actual marker byte.
    let markerOffset = offset + 1;
    while (markerOffset < buffer.length && buffer[markerOffset] === 0xff) {
      markerOffset += 1;
    }
    if (markerOffset >= buffer.length) return false;
    const marker = buffer[markerOffset]!;
    offset = markerOffset + 1;

    if (isStandaloneMarker(marker)) continue;
    if (marker === 0xd9) return false; // EOI reached before a real scan segment

    if (offset + 2 > buffer.length) return false;
    const segmentLength = buffer.readUInt16BE(offset);
    if (segmentLength < 2 || offset + segmentLength > buffer.length) return false;

    if (isStartOfFrameMarker(marker)) {
      frame = parseStartOfFrame(buffer, offset, segmentLength);
      if (!frame) return false;
    }

    if (marker === JPEG_START_OF_SCAN_MARKER) {
      if (!frame) return false;
      return isValidStartOfScan(buffer, offset, segmentLength, frame);
    }

    offset += segmentLength;
  }

  return false;
}

/**
 * Bounded structural validity, not full image decoding: a single forward
 * walk over chunk/marker headers per format, with no decompression and no
 * unbounded scanning (`PNG_MAX_CHUNKS`/`JPEG_MAX_SEGMENTS` cap iteration).
 * This is still not authenticity verification — a well-formed PNG/JPEG with
 * fabricated pixel content passes exactly as the accepted eligibility
 * contract already allows — but it rejects truncated files, valid-prefix-
 * plus-garbage payloads, and constructed non-images that merely start and
 * end with the right marker bytes.
 */
function isStructurallyValidImage(buffer: Buffer, mimeType: string): boolean {
  if (mimeType === "image/png") return isStructurallyValidPng(buffer);
  if (mimeType === "image/jpeg") return isStructurallyValidJpeg(buffer);
  return false;
}

/** Finite bound (engineering-owned): a screenshot analysis attempt must
 * resolve or fail within this window rather than leaving the requester's
 * manual form blocked on the network. */
const PROVIDER_TIMEOUT_MS = 20_000;

/**
 * Every provider failure kind (auth/rate_limit/server/timeout/parse/unknown)
 * degrades identically for the requester — the form stays fully
 * manual-usable — so this returns one fixed refusal regardless of kind. The
 * distinction is preserved separately for content-free operational
 * analytics (`logProposalOutcome`'s `detail` argument), never for a
 * different requester-facing message.
 */
function classifyProviderFailure(
  _result: ProviderCallResult
): { status: number; code: string; message: string } {
  return {
    status: 503,
    code: PROVIDER_UNAVAILABLE_CODE,
    message: PROVIDER_UNAVAILABLE_MESSAGE,
  };
}

/**
 * Content-free operational analytics only (contract: no raw screenshot, OCR
 * output, or provider request/response content may ever be logged). Every
 * argument here is a closed classification value, never extracted text,
 * venue text, food items, or provider JSON.
 */
function logProposalOutcome(
  outcome: "eligible" | "ineligible" | "provider_error" | "invalid_output",
  detail?: string
): void {
  console.log(
    `[screenshot-proposal] ${outcome}${detail ? ` (${detail})` : ""}`
  );
}

export async function handleScreenshotProposal(
  req: Request,
  res: Response
): Promise<Response> {
  // Participant authority first: an unverified caller triggers no image
  // decoding, no provider call, and learns nothing about whether its image
  // would otherwise have been accepted — the same ordering every other
  // gated mutation in this repository uses.
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }

  const parsedBody = screenshotProposalBodySchema.safeParse(req.body);
  if (!parsedBody.success) {
    return sendDay4Error(res, 400, INVALID_IMAGE_CODE, INVALID_IMAGE_MESSAGE);
  }

  if (!isStrictBase64(parsedBody.data.imageBase64)) {
    return sendDay4Error(res, 400, INVALID_IMAGE_CODE, INVALID_IMAGE_MESSAGE);
  }

  let imageBuffer: Buffer;
  try {
    imageBuffer = Buffer.from(parsedBody.data.imageBase64, "base64");
  } catch {
    return sendDay4Error(res, 400, INVALID_IMAGE_CODE, INVALID_IMAGE_MESSAGE);
  }

  if (
    imageBuffer.length === 0 ||
    imageBuffer.length > MAX_IMAGE_BYTES ||
    !isStructurallyValidImage(imageBuffer, parsedBody.data.mimeType)
  ) {
    return sendDay4Error(res, 400, INVALID_IMAGE_CODE, INVALID_IMAGE_MESSAGE);
  }

  // Independent eligibility gate, evaluated from on-device Vision OCR text
  // ONLY — never from anything the provider below could say. An ineligible
  // screenshot is refused here, before the provider is ever called: no
  // unsupported-category image reaches OpenAI, and no provider claim can
  // reverse this decision.
  const eligibility = evaluateEligibility(parsedBody.data.localEvidenceText);
  if (!eligibility.eligible) {
    logProposalOutcome("ineligible");
    const body: ScreenshotProposalResponseBody = { eligible: false, proposal: {} };
    return res.status(200).json(body);
  }

  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    // Fail closed: missing provider configuration is not a signal to skip
    // straight to "no useful extraction" as if the provider legitimately
    // found nothing — the requester is told analysis is unavailable, and
    // manual entry remains the answer either way.
    console.error(
      "[screenshot-proposal] OPENAI_API_KEY is not configured"
    );
    return sendDay4Error(
      res,
      503,
      PROVIDER_UNAVAILABLE_CODE,
      PROVIDER_UNAVAILABLE_MESSAGE
    );
  }

  const providerResult = await callScreenshotProvider({
    imageBase64: parsedBody.data.imageBase64,
    mimeType: parsedBody.data.mimeType,
    apiKey,
    timeoutMs: PROVIDER_TIMEOUT_MS,
  });

  if (!providerResult.ok) {
    logProposalOutcome("provider_error", providerResult.errorKind);
    const failure = classifyProviderFailure(providerResult);
    return sendDay4Error(res, failure.status, failure.code, failure.message);
  }

  const validation = validateProviderOutput(
    providerResult.rawJson,
    parsedBody.data.localEvidenceText
  );
  if (!validation.ok) {
    // The provider returned a well-formed HTTP response but content this
    // service cannot trust as proposal authority (forbidden field, wrong
    // shape). Never surfaced as raw output to iOS, logs, or storage — only
    // the classification.
    logProposalOutcome("invalid_output", validation.reason);
    return sendDay4Error(
      res,
      503,
      PROPOSAL_FAILED_CODE,
      PROPOSAL_FAILED_MESSAGE
    );
  }

  logProposalOutcome("eligible");

  const body: ScreenshotProposalResponseBody = {
    eligible: true,
    proposal: validation.proposal,
  };
  return res.status(200).json(body);
}

/**
 * Final error boundary for this route's body parser
 * (`express.json({ limit: SCREENSHOT_BODY_LIMIT })` below). A malformed or
 * oversized body makes `express.json` call `next(err)` instead of running
 * the handler; without this, that error would fall through to the global
 * error handler in `app.ts`, which logs the error object — and a body-parser
 * `SyntaxError` can carry a slice of the raw request body, which for this
 * route may contain screenshot/OCR content. Mirrors
 * `confirmationParserError` (`confirmSubscriptionRoute.ts`): nothing about
 * the error is ever logged, only the same structured `INVALID_IMAGE`
 * refusal a request this route rejected for any other shape reason would
 * get.
 */
export function screenshotProposalParserError(
  error: unknown,
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  if (res.headersSent) {
    next(error);
    return;
  }
  sendDay4Error(res, 400, INVALID_IMAGE_CODE, INVALID_IMAGE_MESSAGE);
}

/**
 * Registered ahead of the global JSON parser (`app.ts`), like
 * `registerParticipantVerificationRoutes` — this route owns its complete
 * middleware chain, including a body-size limit sized for a normalized
 * screenshot rather than the 100 KB shared by every other route.
 */
export function registerScreenshotProposalRoute(app: Express): void {
  app.post(
    SCREENSHOT_PROPOSAL_ROUTE_PATH,
    // A discretionary AI side-feature that sends bytes off-device is exactly
    // the kind of surface an incident response should be able to shut off
    // independent of ordinary request creation; fails closed with every
    // other public action when `PUBLIC_ACTIONS_PAUSED_ENV` is unset.
    pausePublicAction(IMAGE_PROPOSAL_UNAVAILABLE_MESSAGE, PUBLIC_ACTIONS_PAUSED_ENV),
    screenshotProposalRateLimiter,
    express.json({ limit: SCREENSHOT_BODY_LIMIT }),
    handleScreenshotProposal,
    // Error-handling middleware (4 args) is matched by arity, not position:
    // Express skips forward to it from wherever `next(err)` was called
    // within this same route's chain, exactly like
    // `confirmationParserError`'s registration in `app.ts`.
    screenshotProposalParserError
  );
}

export const screenshotProposalRateLimiter = createDay4MutationRateLimiter(10);
