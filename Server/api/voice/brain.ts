import { brain } from "../../src/voice.js";
import { config } from "../../src/config.js";
export const maxDuration = 60;
export function POST(request: Request) { return brain(request, config()); }
