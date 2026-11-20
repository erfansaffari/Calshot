import type { VoiceConfig } from "./voice.js";
/** The Calshot Supabase project (public values) and the server-only Google and OpenAI keys from the deployment environment. */
export const config = (): VoiceConfig => ({
  geminiKey: process.env.GEMINI_API_KEY,
  openaiKey: process.env.OPENAI_API_KEY,
  supabaseURL: "https://gjdzybwjmwixsypsyzem.supabase.co",
  publishableKey: "sb_publishable_Lp5OZ2iVor3xDtBHcnCykQ_X2ts7ThA",
});
