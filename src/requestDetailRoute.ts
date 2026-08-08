import type { NextFunction, Request, Response } from "express";
import mongoose from "mongoose";
import { Request as MealRequest } from "../models/db.js";
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

    const document = await MealRequest.findById(id).lean().exec();
    if (!document) {
      return res.status(404).json({ error: "Request not found" });
    }

    return res.json(
      buildPublicRequestDetailResponse(
        document as unknown as PublicRequestDocument,
        new Date()
      )
    );
  } catch (err) {
    next(err);
  }
}
