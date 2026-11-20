import { earsToken } from "../../src/voice.js";
import { config } from "../../src/config.js";
export const maxDuration = 15;
export function POST(request: Request) { return earsToken(request, config()); }
