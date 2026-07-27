import type { IRequest, ISubscriber } from "../models/db.js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PUBLIC_ACTIONS_PAUSED_ENV } from "./publicActionsPause.js";

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
    unsubToken: "unsubscribe-token",
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
    models.SendLog.exists.mockResolvedValue({ _id: "already-sent" });

    await notifySubscribersForRequest(request());

    expect(models.SendLog.exists).toHaveBeenCalledOnce();
    expect(sendNewRequestAlert).not.toHaveBeenCalled();
  });

  it("resumes the recent-request path past the pause guard", async () => {
    models.Request.find.mockReturnValue({
      sort: () => ({ limit: () => ({ lean: () => Promise.resolve([]) }) }),
    });

    await notifySubscriberAboutRecentRequests(subscriber());

    expect(models.Request.find).toHaveBeenCalledOnce();
  });
});
