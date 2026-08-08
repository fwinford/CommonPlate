import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  Installation,
  PushDelivery,
  Request as MealRequest,
  SendLog,
  Subscriber,
  System,
  type IRequest,
} from "../models/db.js";
import type { ApnsConfiguration } from "./apnsConfig.js";
import type { ApnsConnection, ApnsOutcome, ApnsSubmission } from "./apnsClient.js";
import {
  HELPER_NEW_REQUEST_PURPOSE,
  PUSH_DELIVERY_RETENTION_MS,
  dispatchHelperNewRequestPush,
  startHelperNewRequestPush,
} from "./helperNewRequestPush.js";

/**
 * The dispatcher, exercised against stubbed models and a stubbed provider
 * connection. No case contacts Apple or needs real credentials; the real
 * HTTP/2 behavior is covered in `apnsClient.test.ts` and the real persistence
 * behavior in `helperNewRequestPush.mongo.test.ts`.
 */
const requestId = new mongoose.Types.ObjectId("64b000000000000000000001");
const now = new Date("2026-07-28T16:00:00.000Z");
const expiresAt = new Date("2026-07-28T21:00:00.000Z");

const configuration: ApnsConfiguration = {
  teamId: "ABCDE12345",
  keyId: "KEY1234567",
  bundleId: "org.commonplatenyu.CommonPlateios",
  authKeyPem: "unused: the provider token is injected",
};

function requestDocument(overrides: Record<string, unknown> = {}): IRequest {
  return {
    _id: requestId,
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupName: "Requester Private Name",
    email: "requester@nyu.edu",
    pickupWindowText: "ASAP (within the next 5 hours)",
    status: "open",
    expiresAt,
    ...overrides,
  } as unknown as IRequest;
}

function installationRow(
  index: number,
  overrides: Record<string, unknown> = {}
) {
  return {
    _id: new mongoose.Types.ObjectId(
      `64c${index.toString(16).padStart(21, "0")}`
    ),
    apnsToken: index.toString(16).padStart(64, "a"),
    apnsEnvironment: "development",
    ...overrides,
  };
}

const accepted: ApnsOutcome = {
  classification: "accepted",
  status: 200,
  reason: "Accepted",
  apnsId: "apns-1",
};

let installationFind: ReturnType<typeof vi.spyOn>;
let requestExists: ReturnType<typeof vi.spyOn>;
let pushCreate: ReturnType<typeof vi.spyOn>;
let pushUpdate: ReturnType<typeof vi.spyOn>;
let installationUpdate: ReturnType<typeof vi.spyOn>;
let selectedProjection: unknown;
let selectionFilter: unknown;

function stubInstallations(rows: Record<string, unknown>[]): void {
  installationFind.mockImplementation((filter: unknown) => {
    selectionFilter = filter;
    return {
      select(projection: unknown) {
        selectedProjection = projection;
        return this;
      },
      lean() {
        return this;
      },
      exec: async () => rows,
    };
  });
}

function duplicateKeyError(): Error {
  return Object.assign(new Error("E11000 duplicate key"), { code: 11000 });
}

interface RecordedSubmission {
  origin: string;
  submission: ApnsSubmission;
  timeoutMs: number;
}

function stubConnections(
  respond: (submission: ApnsSubmission, origin: string) => Promise<ApnsOutcome>
) {
  const submissions: RecordedSubmission[] = [];
  const opened: string[] = [];
  const closed: string[] = [];

  const openConnection = vi.fn((origin: string): ApnsConnection => {
    opened.push(origin);
    return {
      async submit(submission, timeoutMs) {
        submissions.push({ origin, submission, timeoutMs });
        return respond(submission, origin);
      },
      close() {
        closed.push(origin);
      },
    };
  });

  return { openConnection, submissions, opened, closed };
}

function dispatch(
  overrides: Record<string, unknown> = {},
  request: IRequest = requestDocument()
) {
  return dispatchHelperNewRequestPush(request, {
    now: () => now,
    isPaused: () => false,
    readConfiguration: () => configuration,
    providerToken: () => "provider-jwt",
    ...overrides,
  });
}

beforeEach(() => {
  installationFind = vi.spyOn(Installation, "find") as ReturnType<typeof vi.spyOn>;
  stubInstallations([]);
  requestExists = vi
    .spyOn(MealRequest, "exists")
    .mockResolvedValue({ _id: requestId } as never) as ReturnType<typeof vi.spyOn>;
  pushCreate = vi
    .spyOn(PushDelivery, "create")
    .mockImplementation((async () => ({
      _id: new mongoose.Types.ObjectId(),
    })) as never) as ReturnType<typeof vi.spyOn>;
  pushUpdate = vi
    .spyOn(PushDelivery, "updateOne")
    .mockReturnValue({ exec: async () => ({ modifiedCount: 1 }) } as never) as ReturnType<
      typeof vi.spyOn
    >;
  installationUpdate = vi
    .spyOn(Installation, "updateOne")
    .mockReturnValue({ exec: async () => ({ modifiedCount: 1 }) } as never) as ReturnType<
      typeof vi.spyOn
    >;
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
  selectedProjection = undefined;
  selectionFilter = undefined;
});

describe("helper push eligibility selection", () => {
  it("selects push-enabled, tokened, non-invalidated installations only", async () => {
    stubInstallations([installationRow(1)]);

    await dispatch({ openConnection: stubConnections(async () => accepted).openConnection });

    expect(selectionFilter).toEqual({
      pushEnabled: true,
      apnsToken: { $type: "string" },
      invalidatedAt: null,
    });
  });

  it("asks for the select:false apnsToken explicitly", async () => {
    // A query that forgets this silently selects zero deliverable
    // installations, because the schema hides the token from projections.
    stubInstallations([installationRow(1)]);

    await dispatch({ openConnection: stubConnections(async () => accepted).openConnection });

    expect(String(selectedProjection)).toContain("+apnsToken");
  });

  it("submits for every eligible installation, with no cap or round-robin", async () => {
    const rows = Array.from({ length: 25 }, (_, index) =>
      installationRow(index + 1)
    );
    stubInstallations(rows);
    const connections = stubConnections(async () => accepted);

    const summary = await dispatch({ openConnection: connections.openConnection });

    expect(summary.eligible).toBe(25);
    expect(summary.accepted).toBe(25);
    expect(connections.submissions).toHaveLength(25);
    expect(
      new Set(connections.submissions.map((entry) => entry.submission.deviceToken))
        .size
    ).toBe(25);
  });

  it.each([undefined, null, "", "sandbox", "Development"])(
    "skips an installation whose stored environment is %j, never defaulting it",
    async (environment) => {
      stubInstallations([
        installationRow(1, { apnsEnvironment: environment }),
        installationRow(2),
      ]);
      const connections = stubConnections(async () => accepted);

      const summary = await dispatch({ openConnection: connections.openConnection });

      expect(summary.skippedEnvironment).toBe(1);
      expect(summary.eligible).toBe(1);
      expect(connections.submissions).toHaveLength(1);
      expect(pushCreate).toHaveBeenCalledTimes(1);
    }
  );

  it("routes each installation to the host for its own stored environment", async () => {
    stubInstallations([
      installationRow(1, { apnsEnvironment: "development" }),
      installationRow(2, { apnsEnvironment: "production" }),
    ]);
    const connections = stubConnections(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });

    expect(new Set(connections.opened)).toEqual(
      new Set([
        "https://api.sandbox.push.apple.com:443",
        "https://api.push.apple.com:443",
      ])
    );
    expect(connections.closed).toHaveLength(2);
  });

  it("opens one connection per host per dispatch", async () => {
    stubInstallations([
      installationRow(1, { apnsEnvironment: "development" }),
      installationRow(2, { apnsEnvironment: "development" }),
      installationRow(3, { apnsEnvironment: "production" }),
    ]);
    const connections = stubConnections(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });

    expect(connections.openConnection).toHaveBeenCalledTimes(2);
  });

  it("reads and writes nothing belonging to the email channel", async () => {
    const forbidden = [
      vi.spyOn(Subscriber, "find"),
      vi.spyOn(Subscriber, "updateOne"),
      vi.spyOn(SendLog, "create"),
      vi.spyOn(SendLog, "exists"),
      vi.spyOn(SendLog, "updateOne"),
      vi.spyOn(System, "findOne"),
      vi.spyOn(System, "updateOne"),
    ];
    stubInstallations([installationRow(1)]);

    await dispatch({ openConnection: stubConnections(async () => accepted).openConnection });

    for (const spy of forbidden) expect(spy).not.toHaveBeenCalled();
  });
});

describe("helper push guards before any delivery record", () => {
  it("returns through the pause before writing a PushDelivery row", async () => {
    // The dispatcher can be called directly, so a suppressed notification must
    // leave no delivery record behind.
    stubInstallations([installationRow(1)]);
    const connections = stubConnections(async () => accepted);

    const summary = await dispatch({
      isPaused: () => true,
      openConnection: connections.openConnection,
    });

    expect(summary.stop).toBe("paused");
    expect(requestExists).not.toHaveBeenCalled();
    expect(installationFind).not.toHaveBeenCalled();
    expect(pushCreate).not.toHaveBeenCalled();
    expect(connections.submissions).toHaveLength(0);
  });

  it("re-checks effective availability and skips a request claimed since creation", async () => {
    requestExists.mockResolvedValue(null);
    stubInstallations([installationRow(1)]);
    const connections = stubConnections(async () => accepted);

    const summary = await dispatch({ openConnection: connections.openConnection });

    expect(summary.stop).toBe("unavailable");
    expect(requestExists).toHaveBeenCalledWith(
      expect.objectContaining({ _id: requestId, expiresAt: expect.any(Object) })
    );
    expect(pushCreate).not.toHaveBeenCalled();
    expect(connections.submissions).toHaveLength(0);
  });

  it("stops before any claim when provider configuration is unreadable", async () => {
    const connections = stubConnections(async () => accepted);
    stubInstallations([installationRow(1)]);

    const summary = await dispatch({
      readConfiguration: () => {
        throw new Error("APNS_TEAM_ID missing");
      },
      openConnection: connections.openConnection,
    });

    expect(summary.stop).toBe("configuration");
    expect(pushCreate).not.toHaveBeenCalled();
    expect(installationFind).not.toHaveBeenCalled();
  });

  it("stops before any claim when the payload cannot be built", async () => {
    const connections = stubConnections(async () => accepted);
    stubInstallations([installationRow(1)]);

    const summary = await dispatch(
      { openConnection: connections.openConnection },
      requestDocument({ expiresAt: undefined })
    );

    expect(summary.stop).toBe("configuration");
    expect(pushCreate).not.toHaveBeenCalled();
  });
});

describe("helper push deduplication", () => {
  it("claims the identity triple before submitting", async () => {
    stubInstallations([installationRow(1)]);
    const connections = stubConnections(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });

    expect(pushCreate).toHaveBeenCalledWith(
      expect.objectContaining({
        requestId,
        purpose: HELPER_NEW_REQUEST_PURPOSE,
        status: "claimed",
      })
    );
    expect(pushCreate.mock.invocationCallOrder[0]).toBeLessThan(
      connections.openConnection.mock.invocationCallOrder[0]
    );
  });

  it("sets the TTL a day past the request's expiration", async () => {
    stubInstallations([installationRow(1)]);

    await dispatch({ openConnection: stubConnections(async () => accepted).openConnection });

    const claim = pushCreate.mock.calls[0][0] as { deleteAt: Date };
    expect(claim.deleteAt).toEqual(
      new Date(expiresAt.getTime() + PUSH_DELIVERY_RETENTION_MS)
    );
  });

  it("skips an installation another dispatch already owns", async () => {
    stubInstallations([installationRow(1), installationRow(2)]);
    pushCreate
      .mockRejectedValueOnce(duplicateKeyError())
      .mockResolvedValueOnce({ _id: new mongoose.Types.ObjectId() });
    const connections = stubConnections(async () => accepted);

    const summary = await dispatch({ openConnection: connections.openConnection });

    expect(summary.duplicate).toBe(1);
    expect(summary.claimed).toBe(1);
    expect(connections.submissions).toHaveLength(1);
  });

  it("records nothing and submits nothing when the claim fails for another reason", async () => {
    stubInstallations([installationRow(1)]);
    pushCreate.mockRejectedValue(new Error("database unavailable"));
    const connections = stubConnections(async () => accepted);

    const summary = await dispatch({ openConnection: connections.openConnection });

    expect(summary.failed).toBe(1);
    expect(connections.submissions).toHaveLength(0);
    expect(pushUpdate).not.toHaveBeenCalled();
  });

  it("stores no token, credential, or request content on the claim", async () => {
    stubInstallations([installationRow(1)]);

    await dispatch({ openConnection: stubConnections(async () => accepted).openConnection });

    const claim = JSON.stringify(pushCreate.mock.calls[0][0]);
    expect(claim).not.toContain("aaaa");
    expect(claim).not.toContain("Campus Market");
    expect(claim).not.toContain("requester@nyu.edu");
    expect(claim).not.toContain("Requester Private Name");
  });
});

describe("helper push submission and provider outcomes", () => {
  it("submits the alert payload with the bounded per-submission timeout", async () => {
    stubInstallations([installationRow(1)]);
    const connections = stubConnections(async () => accepted);

    await dispatch({ openConnection: connections.openConnection });

    const [entry] = connections.submissions;
    expect(entry.timeoutMs).toBe(10_000);
    expect(entry.submission.headers["apns-push-type"]).toBe("alert");
    expect(entry.submission.headers["apns-topic"]).toBe(configuration.bundleId);
    expect(entry.submission.headers.authorization).toBe("bearer provider-jwt");
    expect(JSON.parse(entry.submission.payload)).toMatchObject({
      type: "new-request",
      requestId: requestId.toString(),
    });
  });

  it("records an APNs 200 as an accepted submission with its apns-id", async () => {
    stubInstallations([installationRow(1)]);

    const summary = await dispatch({
      openConnection: stubConnections(async () => accepted).openConnection,
    });

    expect(summary.accepted).toBe(1);
    expect(pushUpdate).toHaveBeenCalledWith(
      expect.any(Object),
      expect.objectContaining({
        $set: expect.objectContaining({ status: "accepted", apnsId: "apns-1" }),
      })
    );
    expect(installationUpdate).not.toHaveBeenCalled();
  });

  it.each([
    [410, "Unregistered"],
    [400, "BadDeviceToken"],
  ])(
    "retires the exact token on a terminal %i %s rejection",
    async (status, reason) => {
      const row = installationRow(1);
      stubInstallations([row]);

      const summary = await dispatch({
        openConnection: stubConnections(async () => ({
          classification: "token-rejected" as const,
          status,
          reason,
        })).openConnection,
      });

      expect(summary.rejected).toBe(1);
      expect(summary.retired).toBe(1);
      expect(pushUpdate).toHaveBeenCalledWith(
        expect.any(Object),
        expect.objectContaining({ $set: expect.objectContaining({ status: "rejected" }) })
      );
      // Exact token and exact environment, matched conditionally in one
      // mutation — never a read-check-save.
      expect(installationUpdate).toHaveBeenCalledWith(
        {
          _id: row._id,
          apnsToken: row.apnsToken,
          apnsEnvironment: "development",
          pushEnabled: true,
        },
        {
          $set: {
            pushEnabled: false,
            invalidatedAt: expect.any(Date),
            updatedAt: expect.any(Date),
          },
        }
      );
    }
  );

  it("treats a retirement that matches zero documents as expected, not an error", async () => {
    installationUpdate.mockReturnValue({
      exec: async () => ({ modifiedCount: 0 }),
    } as never);
    stubInstallations([installationRow(1)]);

    const summary = await dispatch({
      openConnection: stubConnections(async () => ({
        classification: "token-rejected" as const,
        status: 410,
        reason: "Unregistered",
      })).openConnection,
    });

    expect(summary.rejected).toBe(1);
    expect(summary.retired).toBe(0);
    expect(summary.stop).toBe("completed");
  });

  it.each([
    ["transient", 429, "TooManyRequests"],
    ["transient", 503, "ServiceUnavailable"],
    ["configuration", 400, "BadTopic"],
    ["configuration", 400, "DeviceTokenNotForTopic"],
  ] as const)(
    "records a %s %i %s as failed and never retires a token",
    async (classification, status, reason) => {
      stubInstallations([installationRow(1), installationRow(2)]);

      const summary = await dispatch({
        openConnection: stubConnections(async () => ({
          classification,
          status,
          reason,
        })).openConnection,
      });

      // A topic or environment misconfiguration would otherwise retire every
      // installation's token in one dispatch.
      expect(summary.failed).toBe(2);
      expect(summary.stop).toBe("completed");
      expect(installationUpdate).not.toHaveBeenCalled();
      expect(pushUpdate).toHaveBeenCalledWith(
        expect.any(Object),
        expect.objectContaining({ $set: expect.objectContaining({ status: "failed" }) })
      );
    }
  );

  it.each([401, 403])(
    "abandons the remaining submissions after a %i provider auth failure",
    async (status) => {
      stubInstallations(
        Array.from({ length: 6 }, (_, index) => installationRow(index + 1))
      );
      const connections = stubConnections(async () => ({
        classification: "provider-auth" as const,
        status,
        reason: "ExpiredProviderToken",
      }));

      const summary = await dispatch({
        maximumConcurrentSubmissions: 1,
        openConnection: connections.openConnection,
      });

      expect(summary.stop).toBe("provider-auth");
      expect(connections.submissions).toHaveLength(1);
      expect(summary.failed).toBe(1);
      expect(installationUpdate).not.toHaveBeenCalled();
    }
  );

  it("contains a connection that throws instead of resolving", async () => {
    stubInstallations([installationRow(1)]);
    const openConnection = vi.fn(
      (): ApnsConnection => ({
        async submit() {
          throw new Error("provider exploded");
        },
        close() {},
      })
    );

    const summary = await dispatch({ openConnection });

    expect(summary.failed).toBe(1);
    expect(summary.stop).toBe("completed");
  });

  it("logs no token, provider token, or raw provider error", async () => {
    const logged: unknown[] = [];
    (console.log as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (...args: unknown[]) => logged.push(args)
    );
    (console.error as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (...args: unknown[]) => logged.push(args)
    );
    const row = installationRow(1);
    stubInstallations([row]);

    await dispatch({
      openConnection: stubConnections(async () => ({
        classification: "token-rejected" as const,
        status: 410,
        reason: "Unregistered",
      })).openConnection,
    });

    const text = JSON.stringify(logged);
    expect(text).not.toContain(row.apnsToken);
    expect(text).not.toContain("provider-jwt");
    expect(text).not.toContain("bearer");
    expect(text).not.toContain(configuration.authKeyPem);
  });
});

describe("helper push persistence failures stay local to one installation", () => {
  /**
   * The fan-out is the product promise: every eligible installation receives
   * every new eligible request. A database failure while recording one
   * installation's outcome is a bookkeeping loss for that installation, and
   * must never truncate the installations behind it in the queue.
   */
  it("keeps submitting after an outcome write fails", async () => {
    stubInstallations(
      Array.from({ length: 4 }, (_, index) => installationRow(index + 1))
    );
    pushUpdate
      .mockReturnValueOnce({
        exec: async () => {
          throw new Error("outcome write failed");
        },
      } as never)
      .mockReturnValue({ exec: async () => ({ modifiedCount: 1 }) } as never);
    const provider = stubConnections(async () => accepted);

    const summary = await dispatch({
      maximumConcurrentSubmissions: 1,
      openConnection: provider.openConnection,
    });

    expect(provider.submissions).toHaveLength(4);
    expect(summary.claimed).toBe(4);
    // The provider outcome is unchanged by the failed write: APNs accepted
    // all four submissions, and the summary still says so.
    expect(summary.accepted).toBe(4);
    expect(summary.failed).toBe(0);
    expect(summary.persistenceFailed).toBe(1);
    expect(summary.stop).toBe("completed");
  });

  it("keeps submitting after an exact-token retirement write fails", async () => {
    stubInstallations(
      Array.from({ length: 4 }, (_, index) => installationRow(index + 1))
    );
    installationUpdate.mockReturnValueOnce({
      exec: async () => {
        throw new Error("retirement write failed");
      },
    } as never);
    const provider = stubConnections(async (submission) =>
      submission.deviceToken === installationRow(1).apnsToken
        ? { classification: "token-rejected" as const, status: 410, reason: "Unregistered" }
        : accepted
    );

    const summary = await dispatch({
      maximumConcurrentSubmissions: 1,
      openConnection: provider.openConnection,
    });

    expect(provider.submissions).toHaveLength(4);
    expect(summary.rejected).toBe(1);
    expect(summary.accepted).toBe(3);
    // A retirement that could not be written is not a retirement.
    expect(summary.retired).toBe(0);
    expect(summary.persistenceFailed).toBe(1);
    expect(summary.stop).toBe("completed");
  });

  it("still abandons on provider auth when that outcome's write fails", async () => {
    // The abort follows APNs truth, not the success of a bookkeeping write.
    stubInstallations(
      Array.from({ length: 4 }, (_, index) => installationRow(index + 1))
    );
    pushUpdate.mockReturnValue({
      exec: async () => {
        throw new Error("outcome write failed");
      },
    } as never);
    const provider = stubConnections(async () => ({
      classification: "provider-auth" as const,
      status: 403,
      reason: "ExpiredProviderToken",
    }));

    const summary = await dispatch({
      maximumConcurrentSubmissions: 1,
      openConnection: provider.openConnection,
    });

    expect(provider.submissions).toHaveLength(1);
    expect(summary.stop).toBe("provider-auth");
    expect(summary.failed).toBe(1);
    expect(summary.persistenceFailed).toBe(1);
  });

  it("logs no token or provider token when a write fails", async () => {
    const logged: unknown[] = [];
    (console.error as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (...args: unknown[]) => logged.push(args)
    );
    const row = installationRow(1);
    stubInstallations([row]);
    pushUpdate.mockReturnValue({
      exec: async () => {
        throw Object.assign(new Error(`bearer provider-jwt ${row.apnsToken}`), {
          code: "SECRET",
        });
      },
    } as never);

    await dispatch({
      openConnection: stubConnections(async () => accepted).openConnection,
    });

    const text = JSON.stringify(logged);
    expect(text).not.toContain(row.apnsToken);
    expect(text).not.toContain("provider-jwt");
    expect(text).toContain("Error");
  });
});

describe("helper push detached-dispatch bounds", () => {
  it("bounds concurrent submissions", async () => {
    stubInstallations(
      Array.from({ length: 20 }, (_, index) => installationRow(index + 1))
    );
    let inFlight = 0;
    let peak = 0;
    const openConnection = vi.fn(
      (): ApnsConnection => ({
        async submit() {
          inFlight += 1;
          peak = Math.max(peak, inFlight);
          await new Promise((resolve) => setTimeout(resolve, 1));
          inFlight -= 1;
          return accepted;
        },
        close() {},
      })
    );

    const summary = await dispatch({ openConnection });

    expect(summary.accepted).toBe(20);
    expect(peak).toBeLessThanOrEqual(8);
  });

  it("starts no new submission after a provider auth abort observed under concurrency", async () => {
    /**
     * Concurrency greater than one is what production runs. The abort is a
     * gate on *starting* work, not a cancellation of work already in flight:
     * an HTTP/2 request already sent to APNs has no cancellation semantics
     * this contract defines, so it is allowed to finish and be recorded
     * truthfully. What must not happen is a fresh submission beginning after
     * the refusal is known.
     */
    const rows = Array.from({ length: 4 }, (_, index) =>
      installationRow(index + 1)
    );
    stubInstallations(rows);
    const provider = stubConnections(async (submission) => {
      if (submission.deviceToken === rows[0].apnsToken) {
        return {
          classification: "provider-auth" as const,
          status: 403,
          reason: "ExpiredProviderToken",
        };
      }
      // Still in flight when the abort above is observed.
      await new Promise((resolve) => setTimeout(resolve, 30));
      return accepted;
    });
    const rejections: unknown[] = [];
    const onRejection = (reason: unknown) => rejections.push(reason);
    process.on("unhandledRejection", onRejection);

    let summary;
    try {
      summary = await dispatch({
        maximumConcurrentSubmissions: 2,
        openConnection: provider.openConnection,
      });
      await new Promise((resolve) => setTimeout(resolve, 20));
    } finally {
      process.off("unhandledRejection", onRejection);
    }

    // Exactly the two the pool had already started; neither of the two behind
    // them began.
    expect(provider.submissions).toHaveLength(2);
    expect(provider.submissions.map((entry) => entry.submission.deviceToken)).toEqual([
      rows[0].apnsToken,
      rows[1].apnsToken,
    ]);
    expect(summary.stop).toBe("provider-auth");
    // The in-flight submission completed and was recorded for what it was.
    expect(summary.accepted).toBe(1);
    expect(summary.failed).toBe(1);
    // Only the started work claimed; the abandoned installations wrote nothing.
    expect(summary.claimed).toBe(2);
    expect(pushCreate).toHaveBeenCalledTimes(2);
    expect(pushUpdate).toHaveBeenCalledTimes(2);
    expect(summary.persistenceFailed).toBe(0);
    expect(installationUpdate).not.toHaveBeenCalled();
    expect(rejections).toEqual([]);
  });

  it("starts no new submission after the deadline is observed under concurrency", async () => {
    // The same gate, proved for the deadline branch at the concurrency
    // production actually uses. Both existing seams — the injected deadline
    // and the injected pool size — are enough; no restructuring was needed.
    const rows = Array.from({ length: 4 }, (_, index) =>
      installationRow(index + 1)
    );
    stubInstallations(rows);
    const provider = stubConnections(async () => {
      await new Promise((resolve) => setTimeout(resolve, 30));
      return accepted;
    });

    const summary = await dispatch({
      maximumConcurrentSubmissions: 2,
      dispatchDeadlineMs: 25,
      openConnection: provider.openConnection,
    });

    expect(provider.submissions).toHaveLength(2);
    expect(summary.stop).toBe("deadline");
    // Both already-started submissions completed and were recorded.
    expect(summary.accepted).toBe(2);
    expect(summary.claimed).toBe(2);
    expect(summary.persistenceFailed).toBe(0);
    // The audience was never capped; the detached work's own lifetime was.
    expect(summary.eligible).toBe(4);
  });

  it("abandons the remaining submissions at the dispatch deadline", async () => {
    stubInstallations(
      Array.from({ length: 5 }, (_, index) => installationRow(index + 1))
    );
    const connections = stubConnections(async () => {
      await new Promise((resolve) => setTimeout(resolve, 30));
      return accepted;
    });

    const summary = await dispatch({
      maximumConcurrentSubmissions: 1,
      dispatchDeadlineMs: 45,
      openConnection: connections.openConnection,
    });

    expect(summary.stop).toBe("deadline");
    expect(connections.submissions.length).toBeLessThan(5);
    // The audience was never capped; the detached work's own lifetime was.
    expect(summary.eligible).toBe(5);
  });
});

describe("the total start function", () => {
  it("returns void and never throws when dispatch rejects", async () => {
    installationFind.mockImplementation(() => {
      throw new Error("selection exploded");
    });
    const rejections: unknown[] = [];
    const onRejection = (reason: unknown) => rejections.push(reason);
    process.on("unhandledRejection", onRejection);

    try {
      expect(startHelperNewRequestPush(requestDocument())).toBeUndefined();
      await new Promise((resolve) => setTimeout(resolve, 10));
    } finally {
      process.off("unhandledRejection", onRejection);
    }

    expect(rejections).toEqual([]);
  });

  it("contains a synchronous setup failure", () => {
    // A defect thrown before any promise exists must not escape either.
    const broken = { get _id() {
      throw new Error("identity exploded");
    } } as unknown as IRequest;

    expect(() => startHelperNewRequestPush(broken)).not.toThrow();
  });
});
