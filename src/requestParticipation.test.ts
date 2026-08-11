// Focused coverage for the W3-H2 marketplace-presentation helpers: resolving
// an optional (never-refusing) participant identity for a browse-only read,
// and finding the exact set of request ids a verified participant has ever
// successfully held.
import type { Request } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { RequestParticipation } from "../models/db.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  filterRequestListForParticipant,
  findParticipatedRequestIds,
  resolveOptionalParticipantAuthority,
} from "./requestParticipation.js";

const participantId = new mongoose.Types.ObjectId(
  "64f0000000000000000000a9"
);
const participantSecretText = "request-participation-unit-test-secret";
const participantSecret = Buffer.from(participantSecretText);
const authority = signParticipantAuthority(participantId, 1, participantSecret);

function reqWithHeaders(headers: Record<string, string> = {}): Request {
  return { headers } as unknown as Request;
}

beforeEach(() => {
  vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

describe("resolveOptionalParticipantAuthority", () => {
  it("resolves the verified participant when a usable credential is presented", async () => {
    const ParticipantModel = (
      await import("../models/db.js")
    ).Participant;
    vi.spyOn(ParticipantModel, "findOne").mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: vi.fn().mockResolvedValue({
            _id: participantId,
            email: "already-participated@nyu.edu",
          }),
        }),
      }),
    } as unknown as ReturnType<typeof ParticipantModel.findOne>);

    const result = await resolveOptionalParticipantAuthority(
      reqWithHeaders({ [PARTICIPANT_AUTHORITY_HEADER]: authority })
    );

    expect(result).toEqual({
      participantId: String(participantId),
      principal: "already-participated@nyu.edu",
    });
  });

  it("resolves null, never a refusal, when no credential is presented", async () => {
    const result = await resolveOptionalParticipantAuthority(
      reqWithHeaders({})
    );

    expect(result).toBeNull();
  });

  it("resolves null, never a refusal, when the presented credential cannot be verified", async () => {
    const result = await resolveOptionalParticipantAuthority(
      reqWithHeaders({ [PARTICIPANT_AUTHORITY_HEADER]: "not-a-real-credential" })
    );

    expect(result).toBeNull();
  });
});

describe("findParticipatedRequestIds", () => {
  it("returns an empty set without querying when no candidates are supplied", async () => {
    const query = vi.spyOn(RequestParticipation, "find");

    const result = await findParticipatedRequestIds(String(participantId), []);

    expect(result.size).toBe(0);
    expect(query).not.toHaveBeenCalled();
  });

  it("returns only the candidate ids this exact participant has participated in", async () => {
    const participatedId = new mongoose.Types.ObjectId();
    vi.spyOn(RequestParticipation, "find").mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: vi.fn().mockResolvedValue([{ requestId: participatedId }]),
        }),
      }),
    } as unknown as ReturnType<typeof RequestParticipation.find>);

    const result = await findParticipatedRequestIds(String(participantId), [
      participatedId,
      new mongoose.Types.ObjectId(),
    ]);

    expect(result).toEqual(new Set([String(participatedId)]));
  });
});

describe("filterRequestListForParticipant", () => {
  it("returns docs unfiltered, without querying, when no participant is resolved", async () => {
    const query = vi.spyOn(RequestParticipation, "find");
    const docs = [{ _id: new mongoose.Types.ObjectId() }];

    const result = await filterRequestListForParticipant(docs, null);

    expect(result).toBe(docs);
    expect(query).not.toHaveBeenCalled();
  });

  it("returns docs unfiltered, without querying, when the candidate list is empty", async () => {
    const query = vi.spyOn(RequestParticipation, "find");

    const result = await filterRequestListForParticipant([], {
      participantId: String(participantId),
      principal: "already-participated@nyu.edu",
    });

    expect(result).toEqual([]);
    expect(query).not.toHaveBeenCalled();
  });

  it("removes only the requests this exact participant has previously held", async () => {
    const participatedId = new mongoose.Types.ObjectId();
    const untouchedId = new mongoose.Types.ObjectId();
    vi.spyOn(RequestParticipation, "find").mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: vi.fn().mockResolvedValue([{ requestId: participatedId }]),
        }),
      }),
    } as unknown as ReturnType<typeof RequestParticipation.find>);
    const docs = [{ _id: participatedId }, { _id: untouchedId }];

    const result = await filterRequestListForParticipant(docs, {
      participantId: String(participantId),
      principal: "already-participated@nyu.edu",
    });

    expect(result).toEqual([{ _id: untouchedId }]);
  });

  it("returns the original array reference when this participant has never participated in any candidate", async () => {
    vi.spyOn(RequestParticipation, "find").mockReturnValue({
      select: () => ({
        lean: () => ({ exec: vi.fn().mockResolvedValue([]) }),
      }),
    } as unknown as ReturnType<typeof RequestParticipation.find>);
    const docs = [{ _id: new mongoose.Types.ObjectId() }];

    const result = await filterRequestListForParticipant(docs, {
      participantId: String(participantId),
      principal: "already-participated@nyu.edu",
    });

    expect(result).toBe(docs);
  });
});
