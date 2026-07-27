import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import express from "express";
import { describe, expect, it, vi } from "vitest";
import {
  FULFILLMENT_UNAVAILABLE_MESSAGE,
  FULFILLMENT_ROUTE_PATH,
  registerFulfillmentPause,
} from "./fulfillmentRoute.js";

async function exerciseRoutes(
  path: string,
  body?: Record<string, unknown>
): Promise<{
  response: globalThis.Response;
  legacyFulfillment: ReturnType<typeof vi.fn>;
  adminRoute: ReturnType<typeof vi.fn>;
}> {
  const testApp = express();
  testApp.use(express.json());

  const legacyFulfillment = vi.fn((_req, res) =>
    res.status(200).json({ legacy: true })
  );
  const adminRoute = vi.fn((_req, res) => res.sendStatus(204));

  registerFulfillmentPause(testApp);
  testApp.post(FULFILLMENT_ROUTE_PATH, legacyFulfillment);
  testApp.post("/admin/test-fulfillment", adminRoute);

  const server = createServer(testApp);
  await new Promise<void>((resolve) => {
    server.listen(0, "127.0.0.1", resolve);
  });

  try {
    const { port } = server.address() as AddressInfo;
    const response = await fetch(`http://127.0.0.1:${port}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    return { response, legacyFulfillment, adminRoute };
  } finally {
    if (server.listening) {
      await new Promise<void>((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
    }
  }
}

describe("POST /api/request/:id/fulfill pause", () => {
  it.each([
    {
      name: "an invalid request id and no payload",
      path: "/api/request/not-an-object-id/fulfill",
      body: undefined,
    },
    {
      name: "a valid request id and malformed payload",
      path: "/api/request/64b000000000000000000001/fulfill",
      body: { orderNumber: "" },
    },
    {
      name: "a valid request id and complete legacy payload",
      path: "/api/request/64b000000000000000000001/fulfill",
      body: {
        orderNumber: "ORDER123",
        eta: "15 minutes",
        fulfillerEmail: "helper@example.edu",
        contactMessage: "Order placed",
      },
    },
  ])("refuses $name before legacy side effects", async ({ path, body }) => {
    const result = await exerciseRoutes(path, body);

    expect(result.response.status).toBe(503);
    await expect(result.response.json()).resolves.toEqual({
      error: FULFILLMENT_UNAVAILABLE_MESSAGE,
    });
    expect(result.legacyFulfillment).not.toHaveBeenCalled();
    expect(result.adminRoute).not.toHaveBeenCalled();
  });

  it("does not affect the unrelated admin test route", async () => {
    const result = await exerciseRoutes("/admin/test-fulfillment");

    expect(result.response.status).toBe(204);
    expect(result.adminRoute).toHaveBeenCalledOnce();
    expect(result.legacyFulfillment).not.toHaveBeenCalled();
  });
});
