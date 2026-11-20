/**
 * Calshot voice server: the listening and speaking halves of voice, which Calshot provides for every verified
 * account. The Google key stays here; the Mac receives either a one-use listening token locked to the
 * transcription model, or the spoken audio of one sentence. Stateless: no audio, text or calendar content is
 * stored or logged. Each request verifies the Calshot session and draws on the account's daily allowance
 * (public.consume_voice_allowance) before any audio or token is returned; speech from a locally verified session
 * starts while the allowance is drawn and is cancelled if it is refused.
 */
export type VoiceConfig = { geminiKey?: string; openaiKey?: string; supabaseURL: string; publishableKey: string };
type Send = typeof fetch;

export const EARS_MODEL = "gemini-3.5-transcribe-live";
export const SPEECH_MODEL = "gemini-3.8-flash-lite-tts";
export const EARS_URL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained";
/** Prebuilt Gemini voices offered in Settings → Voice. Anything else is rejected. */
export const VOICES = ["Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe", "Autonoe",
  "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi", "Laomedeia", "Achernar",
  "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird", "Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"] as const;
export const MAX_SENTENCE = 600;
export const MAX_TERMS = 100;
/** A listening session lasts at most ten minutes, matching the Mac's voice session limit. */
export const EARS_SESSION_SECONDS = 11 * 60;

const reply = (status: number, data: Record<string, unknown>) =>
  Response.json(data, { status, headers: { "Cache-Control": "no-store", "Pragma": "no-cache" } });

type Caller = { authorization: string };
function caller(request: Request, config: VoiceConfig): Caller | Response {
  if (request.method !== "POST") return reply(405, { error: "method_not_allowed" });
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ") || authorization.length > 8192) return reply(401, { error: "unauthorized" });
  if (!config.geminiKey) return reply(503, { error: "voice_unavailable" });
  return { authorization };
}

/**
 * Verifies the session and draws on today's allowance in one call made with the caller's own session: PostgREST
 * rejects an invalid session, and the function refuses unverified or anonymous accounts, so the database decides
 * whose row moves. No decoded client claims authorize access.
 */
async function consume(who: Caller, config: VoiceConfig, kind: "session" | "characters" | "brain", amount: number, send: Send): Promise<Response | null> {
  const result = await send(config.supabaseURL + "/rest/v1/rpc/consume_voice_allowance", {
    method: "POST", headers: { authorization: who.authorization, apikey: config.publishableKey, "Content-Type": "application/json" },
    body: JSON.stringify({ kind, amount }), signal: AbortSignal.timeout(8000) });
  if (result.status === 401) return reply(401, { error: "unauthorized" });
  if (result.status === 400 || result.status === 403) return reply(403, { error: "verified_account_required" });
  if (!result.ok) return reply(503, { error: "voice_unavailable" });
  const allowance = await result.json().catch(() => null);
  if (allowance?.allowed !== true) return reply(429, { error: "voice_limit_reached" });
  return null;
}

async function body(request: Request, limit: number): Promise<Record<string, unknown> | null> {
  const raw = await request.text();
  if (raw.length > limit) return null;
  try {
    const value = JSON.parse(raw);
    return value && typeof value === "object" && !Array.isArray(value) ? value : null;
  } catch { return null; }
}

/** Calendar words that bias recognition (titles, people, places). Plain short strings only; never stored. */
export function vocabulary(value: unknown): string[] | null {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > MAX_TERMS) return null;
  const terms: string[] = [];
  for (const item of value) {
    if (typeof item !== "string") return null;
    const term = item.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
    if (term.length > 48) return null;
    if (term && !terms.includes(term)) terms.push(term);
  }
  return terms;
}

/** The whole listening setup is fixed in the token, so it opens only the transcription model, once, briefly. */
export function earsTokenRequest(terms: string[], now: Date) {
  const at = (seconds: number) => new Date(now.getTime() + seconds * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
  return {
    uses: 1, expireTime: at(EARS_SESSION_SECONDS), newSessionExpireTime: at(60),
    bidiGenerateContentSetup: {
      model: "models/" + EARS_MODEL,
      generationConfig: { responseModalities: ["TEXT"] },
      inputAudioTranscription: terms.length ? { customVocabulary: terms } : {},
      realtimeInputConfig: { automaticActivityDetection: { disabled: true } },
    },
  };
}

export async function earsToken(request: Request, config: VoiceConfig, send: Send = fetch, now = () => new Date()): Promise<Response> {
  try {
    const who = caller(request, config);
    if (who instanceof Response) return who;
    const fields = await body(request, 16384);
    if (!fields || Object.keys(fields).some(key => key !== "vocabulary")) return reply(400, { error: "invalid_request" });
    const terms = vocabulary(fields.vocabulary);
    if (!terms) return reply(400, { error: "invalid_request" });
    const denied = await consume(who, config, "session", 1, send);
    if (denied) return denied;
    const minted = await send("https://generativelanguage.googleapis.com/v1beta/auth_tokens", {
      method: "POST", headers: { "x-goog-api-key": config.geminiKey!, "Content-Type": "application/json" },
      body: JSON.stringify(earsTokenRequest(terms, now())), signal: AbortSignal.timeout(8000) });
    const token = await minted.json().catch(() => null);
    if (!minted.ok || typeof token?.name !== "string" || !token.name) return reply(502, { error: "voice_unavailable" });
    return reply(200, { token: token.name, url: EARS_URL, model: "models/" + EARS_MODEL, expiresIn: EARS_SESSION_SECONDS });
  } catch { return reply(502, { error: "voice_unavailable" }); }
}

/** One sentence the Mac's agent wrote, read aloud verbatim. Text that cannot be spoken is refused. */
export function sentence(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const text = value.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, " ").trim();
  return text && text.length <= MAX_SENTENCE ? text : null;
}

export function speechRequest(text: string, voice: string) {
  return {
    model: SPEECH_MODEL,
    input: [{ type: "user_input", content: [{ type: "text", text }] }],
    response_format: { type: "audio", mime_type: "audio/l16", sample_rate: 24000 },
    generation_config: { speech_config: [{ voice }] },
    stream: true, store: false,
  };
}

/** Turns Google's event stream into raw 24 kHz mono PCM16. A failure mid-stream simply ends the audio early. */
export function pcmStream(events: ReadableStream<Uint8Array>): ReadableStream<Uint8Array> {
  const decoder = new TextDecoder();
  let buffer = "";
  const reader = events.getReader();
  const decode = (line: string): Uint8Array | null => {
    if (!line.startsWith("data:")) return null;
    const payload = line.slice(5).trim();
    if (!payload || payload === "[DONE]") return null;
    let event: { event_type?: string; delta?: { type?: string; data?: string } };
    try { event = JSON.parse(payload); } catch { return null; }
    if (event.event_type !== "step.delta" || event.delta?.type !== "audio" || typeof event.delta.data !== "string") return null;
    return Uint8Array.from(Buffer.from(event.delta.data, "base64"));
  };
  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      for (;;) {
        const newline = buffer.indexOf("\n");
        if (newline >= 0) {
          const line = buffer.slice(0, newline).replace(/\r$/, ""); buffer = buffer.slice(newline + 1);
          const audio = decode(line);
          if (audio?.length) { controller.enqueue(audio); return; }
          continue;
        }
        const { value, done } = await reader.read();
        if (done) { const audio = decode(buffer); buffer = ""; if (audio?.length) controller.enqueue(audio); controller.close(); return; }
        buffer += decoder.decode(value, { stream: true });
        if (buffer.length > 4_000_000) { controller.close(); await reader.cancel(); return; }
      }
    },
    cancel() { return reader.cancel(); },
  });
}

/**
 * A fast local check of the Calshot session, so speech can start while the database draws on the allowance.
 * "valid": an unexpired ES256 session for a signed-in, non-anonymous user of this project, signed by one of its
 * published keys. "invalid": malformed, expired or not signed by them; refused at once. "unknown": anything else
 * (keys unreadable, another signing method, an unusual session), so the database decides before Google is called.
 * It only decides whether Google may be called early; the allowance call still authorizes every sentence.
 */
export type SessionCheck = (authorization: string) => Promise<"valid" | "invalid" | "unknown">;
const keyCache = new Map<string, { at: number; keys: Map<string, CryptoKey> }>();
const decodePart = (part: string) => Buffer.from(part, "base64url");

export function sessionCheck(config: VoiceConfig, send: Send = fetch, now = () => Date.now()): SessionCheck {
  async function key(kid: string): Promise<CryptoKey | null | undefined> {
    const cached = keyCache.get(config.supabaseURL);
    // Keys are reread every ten minutes, or for an unknown key at most every 30 seconds.
    if (cached && (cached.keys.has(kid) ? now() - cached.at < 600_000 : now() - cached.at < 30_000)) return cached.keys.get(kid) ?? null;
    try {
      const result = await send(config.supabaseURL + "/auth/v1/.well-known/jwks.json", { signal: AbortSignal.timeout(3000) });
      const listed = (await result.json())?.keys;
      if (!result.ok || !Array.isArray(listed)) return undefined;
      const keys = new Map<string, CryptoKey>();
      for (const jwk of listed) {
        if (jwk?.kty !== "EC" || jwk.crv !== "P-256" || typeof jwk.kid !== "string") continue;
        keys.set(jwk.kid, await crypto.subtle.importKey("jwk", { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]));
      }
      keyCache.set(config.supabaseURL, { at: now(), keys });
      return keys.get(kid) ?? null;
    } catch { return undefined; }
  }
  return async authorization => {
    const parts = authorization.slice(7).split(".");
    if (parts.length !== 3) return "invalid";
    let header: { alg?: string; kid?: string }, claims: { exp?: number; iss?: string; aud?: string | string[]; role?: string; sub?: string; is_anonymous?: boolean };
    try { header = JSON.parse(decodePart(parts[0]).toString()); claims = JSON.parse(decodePart(parts[1]).toString()); } catch { return "invalid"; }
    // Sessions signed another way (a legacy shared secret) are left to the database.
    if (header.alg !== "ES256" || typeof header.kid !== "string") return "unknown";
    if (typeof claims.exp !== "number" || claims.exp * 1000 <= now()) return "invalid";
    const verifier = await key(header.kid);
    if (verifier === undefined) return "unknown";
    if (verifier === null) return "invalid";
    const signed = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, verifier, decodePart(parts[2]),
      new TextEncoder().encode(parts[0] + "." + parts[1])).catch(() => false);
    if (!signed) return "invalid";
    // A genuine session that is not an ordinary signed-in user (anonymous, another audience) gets no early speech;
    // the database answers for it.
    const audience = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
    return claims.iss === config.supabaseURL + "/auth/v1" && audience.includes("authenticated") && claims.role === "authenticated"
      && !!claims.sub && claims.is_anonymous !== true ? "valid" : "unknown";
  };
}

export async function speak(request: Request, config: VoiceConfig, send: Send = fetch, check: SessionCheck = sessionCheck(config, send)): Promise<Response> {
  const speech = new AbortController();
  try {
    const who = caller(request, config);
    if (who instanceof Response) return who;
    const fields = await body(request, 4096);
    if (fields && Object.keys(fields).length === 1 && fields.warm === true) {
      // Voice just started: open this instance's connections to the database and Google and load the signing keys,
      // so the first sentence does not pay for them. Nothing is spoken, counted or stored.
      const [session] = await Promise.all([check(who.authorization),
        Promise.resolve().then(() => send("https://generativelanguage.googleapis.com/", { method: "HEAD", signal: AbortSignal.timeout(3000) })).catch(() => null)]);
      return session === "invalid" ? reply(401, { error: "unauthorized" }) : new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
    }
    if (!fields || Object.keys(fields).some(key => !["text", "voice"].includes(key))) return reply(400, { error: "invalid_request" });
    const text = sentence(fields.text);
    const voice = typeof fields.voice === "string" && (VOICES as readonly string[]).includes(fields.voice) ? fields.voice : null;
    if (!text || !voice) return reply(400, { error: "invalid_request" });
    const started = Date.now();
    const session = await check(who.authorization);
    if (session === "invalid") return reply(401, { error: "unauthorized" });
    request.signal.addEventListener("abort", () => speech.abort(), { once: true });
    const call = () => send("https://generativelanguage.googleapis.com/v1beta/interactions", {
      method: "POST", headers: { "x-goog-api-key": config.geminiKey!, "Content-Type": "application/json", Accept: "text/event-stream" },
      body: JSON.stringify(speechRequest(text, voice)), signal: speech.signal });
    // A verified session starts the speech while the allowance is drawn; a refusal cancels it before any audio leaves.
    const early = session === "valid" ? call() : null;
    early?.catch(() => {});
    const denied = await consume(who, config, "characters", text.length, send);
    const allowance = Date.now() - started;
    if (denied) { speech.abort(); return denied; }
    const upstream = await (early ?? call());
    if (!upstream.ok || !upstream.body) { speech.abort(); return reply(502, { error: "voice_unavailable" }); }
    return new Response(pcmStream(upstream.body), { status: 200, headers: {
      "Content-Type": "audio/l16; rate=24000; channels=1", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
      "Server-Timing": `allowance;dur=${allowance}, speech;dur=${Date.now() - started}` } });
  } catch { speech.abort(); return reply(502, { error: "voice_unavailable" }); }
}

/**
 * The voice brain: one model request of the Mac's voice agent, run on Calshot's OpenAI account the way HeyClicky
 * runs its voice. The Mac sends the conversation and its function tools; the model, tier, effort, length limit and
 * storage are fixed here, so an account can spend at most one bounded request per call within its daily allowance.
 * OpenAI's event stream is relayed unchanged; nothing is stored or logged.
 */
export const BRAIN_MODEL = "gpt-6.1-sol";
export const BRAIN_TIER = "ultrafast";
export const MAX_BRAIN_BYTES = 3_000_000;
export const MAX_BRAIN_ITEMS = 400;
export const MAX_BRAIN_TOOLS = 48;
export const MAX_BRAIN_OUTPUT = 2_000;
const BRAIN_ITEMS = new Set(["message", "function_call", "function_call_output", "reasoning"]);
const BRAIN_ROLES = new Set(["developer", "user", "assistant"]);

/** Plain conversation items and function tools only: no system role, hosted tools or other models. */
export function brainBody(fields: Record<string, unknown> | null): { input: unknown[]; tools: unknown[]; cacheKey: string } | null {
  if (!fields || Object.keys(fields).some(key => !["input", "tools", "cache_key"].includes(key))) return null;
  const { input, tools, cache_key: cacheKey } = fields;
  if (!Array.isArray(input) || input.length === 0 || input.length > MAX_BRAIN_ITEMS) return null;
  if (!Array.isArray(tools) || tools.length > MAX_BRAIN_TOOLS) return null;
  if (typeof cacheKey !== "string" || !/^[a-z0-9-]{8,80}$/.test(cacheKey)) return null;
  for (const item of input) {
    if (!item || typeof item !== "object" || Array.isArray(item)) return null;
    const { type, role } = item as { type?: unknown; role?: unknown };
    if (type === undefined ? !BRAIN_ROLES.has(role as string) : !BRAIN_ITEMS.has(type as string)) return null;
    if (type === "message" && !BRAIN_ROLES.has(role as string)) return null;
  }
  for (const tool of tools) {
    const { type, name } = (tool ?? {}) as { type?: unknown; name?: unknown };
    if (type !== "function" || typeof name !== "string" || !/^[a-z_]{1,64}$/.test(name)) return null;
  }
  return { input, tools, cacheKey };
}

export function brainRequest(input: unknown[], tools: unknown[], cacheKey: string, subject?: string) {
  return {
    model: BRAIN_MODEL, service_tier: BRAIN_TIER, reasoning: { effort: "low" }, text: { verbosity: "low" },
    store: false, stream: true, input, tools, parallel_tool_calls: false, max_output_tokens: MAX_BRAIN_OUTPUT,
    include: ["reasoning.encrypted_content"], prompt_cache_key: "calshot-voice-" + cacheKey,
    ...(subject ? { safety_identifier: subject } : {}),
  };
}

/** OpenAI's abuse monitoring sees a one-way hash of the account, never the account itself. */
async function safetyIdentifier(authorization: string): Promise<string | undefined> {
  try {
    const sub = JSON.parse(decodePart(authorization.slice(7).split(".")[1] ?? "").toString()).sub;
    if (typeof sub !== "string" || !sub) return undefined;
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("calshot-voice:" + sub));
    return Buffer.from(digest).toString("hex").slice(0, 32);
  } catch { return undefined; }
}

export async function brain(request: Request, config: VoiceConfig, send: Send = fetch, check: SessionCheck = sessionCheck(config, send)): Promise<Response> {
  const model = new AbortController();
  try {
    if (request.method !== "POST") return reply(405, { error: "method_not_allowed" });
    const authorization = request.headers.get("authorization");
    if (!authorization?.startsWith("Bearer ") || authorization.length > 8192) return reply(401, { error: "unauthorized" });
    if (!config.openaiKey) return reply(503, { error: "voice_unavailable" });
    const who = { authorization };
    const parsed = brainBody(await body(request, MAX_BRAIN_BYTES));
    if (!parsed) return reply(400, { error: "invalid_request" });
    const started = Date.now();
    const session = await check(authorization);
    if (session === "invalid") return reply(401, { error: "unauthorized" });
    request.signal.addEventListener("abort", () => model.abort(), { once: true });
    const subject = await safetyIdentifier(authorization);
    const call = () => send("https://api.openai.com/v1/responses", {
      method: "POST", headers: { Authorization: "Bearer " + config.openaiKey, "Content-Type": "application/json", Accept: "text/event-stream" },
      body: JSON.stringify(brainRequest(parsed.input, parsed.tools, parsed.cacheKey, subject)), signal: model.signal });
    // As with speech: a verified session starts the model while the allowance is drawn; a refusal cancels it.
    const early = session === "valid" ? call() : null;
    early?.catch(() => {});
    const denied = await consume(who, config, "brain", 1, send);
    const allowance = Date.now() - started;
    if (denied) { model.abort(); return denied; }
    const upstream = await (early ?? call());
    if (!upstream.ok || !upstream.body) {
      model.abort();
      // Only the status is kept: OpenAI's message can quote the request.
      // OpenAI's own rate limit is Calshot's capacity, not the account's allowance, so it is reported as unavailable.
      return upstream.status === 400 ? reply(400, { error: "invalid_request" }) : reply(upstream.status === 429 ? 503 : 502, { error: "voice_unavailable" });
    }
    return new Response(upstream.body, { status: 200, headers: {
      "Content-Type": "text/event-stream", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
      "Server-Timing": `allowance;dur=${allowance}, model;dur=${Date.now() - started}` } });
  } catch { model.abort(); return reply(502, { error: "voice_unavailable" }); }
}
