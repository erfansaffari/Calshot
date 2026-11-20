import { speak } from "../../src/voice.js";
import { config } from "../../src/config.js";
export const maxDuration = 30;
export function POST(request: Request) { return speak(request, config()); }
