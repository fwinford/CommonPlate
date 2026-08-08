import type { NextFunction, Request, Response } from "express";
import mongoose from "mongoose";
import { Request as MealRequest } from "../models/db.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  isVisibleNow,
  REQUEST_NOT_YET_AVAILABLE_CODE,
  REQUEST_NOT_YET_AVAILABLE_MESSAGE,
} from "./requestAvailability.js";
import {
  buildPublicRequestDetailResponse,
  type PublicRequestDocument,
} from "./requestListResponse.js";

export async function getPublicRequestDetail(
  req: Request,
  res: Response,
  next: NextFunction
): Promise<Response | void> {
  try {
    const { id } = req.params;
    if (!mongoose.Types.ObjectId.isValid(String(id))) {
      return res.status(400).json({ error: "Invalid request id" });
    }

    // One instant decides both the visibility gate below and the effective
    // status of the response, so the two cannot disagree about the same read.
    const now = new Date();

    const document = await MealRequest.findById(id).lean().exec();
    if (!document) {
      return res.status(404).json({ error: "Request not found" });
    }

    // A scheduled request withheld from the list must also be withheld here.
    // Otherwise this route is the hole in the W3-R1 visibility rule: knowing
    // an id — from a shared link, an enumeration attempt, or a notification
    // that should not have been sent yet — would return the vendor, the food,
    // the pickup window, and a status of `open`, hours before helpers are
    // meant to see any of it.
    //
    // The refusal carries no request content of any kind: only the shared
    // not-yet-available code and sentence, which are the same ones the claim
    // route answers with. It is deliberately distinct from the 404 below,
    // which keeps meaning exactly one thing — no such request — so a client
    // can tell "come back later" apart from "this is gone" without either
    // answer describing the request itself.
    //
    // Legacy rows carry no `visibleFrom`, and `isVisibleNow` reads that
    // absence as "visible from creation", so nothing persisted before this
    // field existed becomes unreachable.
    if (!isVisibleNow((document as { visibleFrom?: Date }).visibleFrom, now)) {
      return sendDay4Error(
        res,
        409,
        REQUEST_NOT_YET_AVAILABLE_CODE,
        REQUEST_NOT_YET_AVAILABLE_MESSAGE
      );
    }

    return res.json(
      buildPublicRequestDetailResponse(
        document as unknown as PublicRequestDocument,
        now
      )
    );
  } catch (err) {
    next(err);
  }
}
