import type { IRequest, ISubscriber } from "../models/db.js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";
import {
  CLAIM_MINIMUM_REMAINING_MS,
  buildEffectiveAvailabilityFilter,
  isEffectivelyAvailable,
} from "./requestAvailability.js";

const alertInstant = new Date("2026-07-30T16:00:00.000Z");

const { models, sendNewRequestAlert } = vi.hoisted(() => {
  const collection = () => ({
    find: vi.fn(),
    findOne: vi.fn(),
    findById: vi.fn(),
    exists: vi.fn(),
    create: vi.fn(),
    updateOne: vi.fn(),
  });

  return {
    models: {
      Subscriber: collection(),
      System: collection(),
      SendLog: collection(),
      Request: collection(),
    },
    sendNewRequestAlert: vi.fn(),
  };
});

vi.mock("../models/db.js", () => models);
vi.mock("./emailHelpers.js", () => ({ sendNewRequestAlert }));

import {
  notifySubscriberAboutRecentRequests,
  notifySubscribersForRequest,
} from "./notifySubscribers.js";

function request(): IRequest {
  return {
    _id: "64b000000000000000000001",
    vendor: "Campus Market",
    food: "Vegetable rice bowl",
    pickupWindowText: "1:00 PM – 2:00 PM",
  } as unknown as IRequest;
}

function subscriber(): ISubscriber {
  return {
    _id: "64b000000000000000000002",
    email: "helper@example.edu",
    status: "confirmed",
    unsubscribeCredentialVersion: 1,
    dailyCount: 0,
    bounced: false,
  } as unknown as ISubscriber;
}

function everyModelCall() {
  return Object.values(models).flatMap((model) => Object.values(model));
}

beforeEach(() => {
  for (const call of everyModelCall()) call.mockReset();
  sendNewRequestAlert.mockReset();
});

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("notification dispatch while public actions are paused", () => {
  beforeEach(() => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "true");
  });

  it("skips real-time alerts without touching the database or email", async () => {
    await notifySubscribersForRequest(request());

    expect(sendNewRequestAlert).not.toHaveBeenCalled();
    for (const call of everyModelCall()) {
      expect(call).not.toHaveBeenCalled();
    }
  });

  it("skips recent-request alerts after subscription", async () => {
    await notifySubscriberAboutRecentRequests(subscriber());

    expect(sendNewRequestAlert).not.toHaveBeenCalled();
    for (const call of everyModelCall()) {
      expect(call).not.toHaveBeenCalled();
    }
  });

  it("records no delivery for a skipped alert", async () => {
    await notifySubscribersForRequest(request());
    await notifySubscriberAboutRecentRequests(subscriber());

    expect(models.SendLog.create).not.toHaveBeenCalled();
    expect(models.SendLog.updateOne).not.toHaveBeenCalled();
    expect(models.Subscriber.updateOne).not.toHaveBeenCalled();
  });
});

describe("notification dispatch when public actions are resumed", () => {
  beforeEach(() => {
    vi.stubEnv(PUBLIC_ACTIONS_PAUSED_ENV, "false");
  });

  it("resumes the real-time path past the pause guard", async () => {
    // Reaching the idempotency check proves the guard did not short-circuit;
    // reporting an existing successful send stops the rest of the flow.
    models.Request.exists.mockResolvedValue({ _id: request()._id });
    models.SendLog.exists.mockResolvedValue({ _id: "already-sent" });

    await notifySubscribersForRequest(request());

    expect(models.SendLog.exists).toHaveBeenCalledOnce();
    expect(sendNewRequestAlert).not.toHaveBeenCalled();
  });

  it("queries only confirmed subscribers for real-time alerts", async () => {
    models.Request.exists.mockResolvedValue({ _id: request()._id });
    models.SendLog.exists.mockResolvedValue(null);
    models.Subscriber.find.mockReturnValue({
      sort: vi.fn().mockResolvedValue([]),
    });

    await notifySubscribersForRequest(request());

    expect(models.Subscriber.find).toHaveBeenCalledWith({
      $and: expect.arrayContaining([{ status: "confirmed" }]),
    });
    expect(sendNewRequestAlert).not.toHaveBeenCalled();
  });

  it.each(["pending", "unsubscribed"] as const)(
    "keeps a %s subscriber ineligible for recent-request alerts",
    async (status) => {
      await notifySubscriberAboutRecentRequests({
        ...subscriber(),
        status,
      } as ISubscriber);

      expect(models.Request.find).not.toHaveBeenCalled();
      expect(sendNewRequestAlert).not.toHaveBeenCalled();
      expect(models.SendLog.create).not.toHaveBeenCalled();
    }
  );

  it("resumes the recent-request path past the pause guard", async () => {
    models.Request.find.mockReturnValue({
      sort: () => ({ limit: () => ({ lean: () => Promise.resolve([]) }) }),
    });

    await notifySubscriberAboutRecentRequests(subscriber());

    expect(models.Request.find).toHaveBeenCalledOnce();
    expect(models.Request.find).toHaveBeenCalledWith(
      expect.objectContaining({
        expiresAt: { $gt: expect.any(Date), $gte: expect.any(Date) },
        $or: [
          { status: "open" },
          {
            status: "claimed",
            claimExpiresAt: { $lte: expect.any(Date) },
          },
        ],
      })
    );
  });

  it("excludes short-lived requests from real-time helper alerts", async () => {
    // Frozen so the captured instant in the module is knowable exactly.
    vi.useFakeTimers();
    vi.setSystemTime(alertInstant);
    models.Request.exists.mockResolvedValue(null);

    try {
      await notifySubscribersForRequest(request());
    } finally {
      vi.useRealTimers();
    }

    expect(models.Request.exists).toHaveBeenCalledWith({
      _id: request()._id,
      ...buildEffectiveAvailabilityFilter(alertInstant),
    });
    // A request expiring inside the next five minutes fails that filter, so no
    // alert is ever sent for it.
    expect(
      isEffectivelyAvailable(
        {
          status: "open",
          expiresAt: new Date(
            alertInstant.getTime() + CLAIM_MINIMUM_REMAINING_MS - 1
          ),
        },
        alertInstant
      )
    ).toBe(false);
    expect(sendNewRequestAlert).not.toHaveBeenCalled();
  });

  it("excludes short-lived requests from recent-request notification queries", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(alertInstant);
    models.Request.find.mockReturnValue({
      sort: () => ({ limit: () => ({ lean: () => Promise.resolve([]) }) }),
    });

    try {
      await notifySubscriberAboutRecentRequests(subscriber());
    } finally {
      vi.useRealTimers();
    }

    const filter = models.Request.find.mock.calls[0][0];
    expect(filter).toEqual({
      createdAt: {
        $gte: new Date(alertInstant.getTime() - 24 * 60 * 60 * 1000),
      },
      ...buildEffectiveAvailabilityFilter(alertInstant),
    });
    expect(filter.expiresAt.$gte).toEqual(
      new Date(alertInstant.getTime() + CLAIM_MINIMUM_REMAINING_MS)
    );
  });

  it("does not advertise a request that became actively claimed", async () => {
    models.Request.exists.mockResolvedValue(null);

    await notifySubscribersForRequest(request());

    expect(models.Request.exists).toHaveBeenCalledWith(
      expect.objectContaining({
        _id: request()._id,
        $or: expect.any(Array),
      })
    );
    expect(models.SendLog.exists).not.toHaveBeenCalled();
    expect(sendNewRequestAlert).not.toHaveBeenCalled();
  });
});
