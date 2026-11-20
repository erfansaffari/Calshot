import { describe, it, expect, vi } from "vitest";
import { earsToken, speak, brain, brainBody, pcmStream, vocabulary, earsTokenRequest, sentence, sessionCheck, EARS_MODEL, SPEECH_MODEL, BRAIN_MODEL } from "../src/voice.js";

const config = { geminiKey: "fictional-google-key", supabaseURL: "https://project.example.invalid", publishableKey: "fictional-public-key" };
const post = (path: string, body: unknown, signed = true) => new Request("https://voice.example.invalid" + path, {
  method: "POST", headers: signed ? { Authorization: "Bearer fictional-session" } : {}, body: typeof body === "string" ? body : JSON.stringify(body) });
const allowed = () => Response.json({ allowed: true, kind: "session", remaining: 59 });
const sse = (lines: string[]) => new Response(new ReadableStream({ start(c) { for (const l of lines) c.enqueue(new TextEncoder().encode(l)); c.close(); } }));
const audioEvent = (bytes: number[]) => `event: step.delta\ndata: ${JSON.stringify({ event_type: "step.delta", index: 0, delta: { type: "audio", data: Buffer.from(bytes).toString("base64"), mime_type: "audio/l16", sample_rate: 24000 } })}\n\n`;
/** Leaves the session to the database, as when the signing keys cannot be read. */
const unchecked = async () => "unknown" as const;
async function bytes(stream: ReadableStream<Uint8Array>) { const out: number[] = []; const r = stream.getReader(); for (;;) { const { value, done } = await r.read(); if (done) return out; out.push(...value); } }

describe("listening tokens", () => {
  it("refuses unsigned or non-POST requests before calling anything", async () => {
    const send = vi.fn();
    expect((await earsToken(post("/api/voice/ears-token", {}, false), config, send)).status).toBe(401);
    expect((await earsToken(new Request("https://voice.example.invalid/x", { method: "GET" }), config, send)).status).toBe(405);
    expect(send).not.toHaveBeenCalled();
  });
  it("is unavailable without the server key, never reaching Google", async () => {
    const send = vi.fn();
    expect((await earsToken(post("/x", {}), { ...config, geminiKey: undefined }, send)).status).toBe(503);
    expect(send).not.toHaveBeenCalled();
  });
  it("maps a rejected session or unverified account before minting", async () => {
    for (const [status, expected] of [[401, 401], [400, 403], [403, 403], [500, 503]] as const) {
      const send = vi.fn().mockResolvedValueOnce(Response.json({ message: "no" }, { status }));
      expect((await earsToken(post("/x", {}), config, send)).status).toBe(expected);
      expect(send).toHaveBeenCalledTimes(1);
    }
  });
  it("stops at the daily allowance", async () => {
    const send = vi.fn().mockResolvedValueOnce(Response.json({ allowed: false, kind: "session" }));
    const result = await earsToken(post("/x", {}), config, send);
    expect(result.status).toBe(429); expect(await result.json()).toEqual({ error: "voice_limit_reached" });
    expect(send).toHaveBeenCalledTimes(1);
  });
  it("mints a one-use token locked to the transcription setup with the caller's vocabulary", async () => {
    const send = vi.fn().mockResolvedValueOnce(allowed()).mockResolvedValueOnce(Response.json({ name: "auth_tokens/fictional" }));
    const result = await earsToken(post("/x", { vocabulary: ["CS 245", "Dr. Ahmadi", "CS 245", "  "] }), config, send, () => new Date("2026-11-19T10:00:00Z"));
    expect(result.status).toBe(200);
    const json = await result.json();
    expect(json.token).toBe("auth_tokens/fictional"); expect(json.model).toBe("models/" + EARS_MODEL);
    expect(result.headers.get("cache-control")).toBe("no-store");
    const [rpcURL, rpc] = send.mock.calls[0];
    expect(rpcURL).toBe(config.supabaseURL + "/rest/v1/rpc/consume_voice_allowance");
    expect(rpc.headers.authorization).toBe("Bearer fictional-session");
    expect(JSON.parse(rpc.body)).toEqual({ kind: "session", amount: 1 });
    const [mintURL, mint] = send.mock.calls[1];
    expect(mintURL).toContain("/v1beta/auth_tokens"); expect(mint.headers["x-goog-api-key"]).toBe("fictional-google-key");
    const sent = JSON.parse(mint.body);
    expect(sent.uses).toBe(1); expect(sent.newSessionExpireTime).toBe("2026-11-19T10:01:00Z"); expect(sent.expireTime).toBe("2026-11-19T10:11:00Z");
    expect(sent.bidiGenerateContentSetup.model).toBe("models/" + EARS_MODEL);
    expect(sent.bidiGenerateContentSetup.generationConfig.responseModalities).toEqual(["TEXT"]);
    expect(sent.bidiGenerateContentSetup.inputAudioTranscription.customVocabulary).toEqual(["CS 245", "Dr. Ahmadi"]);
    expect(sent.bidiGenerateContentSetup.realtimeInputConfig.automaticActivityDetection.disabled).toBe(true);
  });
  it("rejects unknown fields and oversized or malformed vocabulary", async () => {
    for (const body of [{ extra: 1 }, { vocabulary: "CS 245" }, { vocabulary: [1] }, { vocabulary: ["x".repeat(49)] }, { vocabulary: Array(101).fill("a") }, "not json", []]) {
      const send = vi.fn();
      expect((await earsToken(post("/x", body), config, send)).status).toBe(400);
      expect(send).not.toHaveBeenCalled();
    }
  });
  it("never forwards Google's error details", async () => {
    const send = vi.fn().mockResolvedValueOnce(allowed()).mockResolvedValueOnce(Response.json({ error: { message: "key detail" } }, { status: 400 }));
    const result = await earsToken(post("/x", {}), config, send);
    expect(result.status).toBe(502); expect(JSON.stringify(await result.json())).not.toContain("key detail");
  });
  it("cleans vocabulary and builds an empty transcription config without terms", () => {
    expect(vocabulary(["a\u0000b", "a b"])).toEqual(["a b"]);
    expect(earsTokenRequest([], new Date(0)).bidiGenerateContentSetup.inputAudioTranscription).toEqual({});
  });
});

describe("speaking", () => {
  it("validates the sentence and voice before drawing on the allowance", async () => {
    for (const body of [{ text: "", voice: "Kore" }, { text: "x".repeat(601), voice: "Kore" }, { text: "Hi", voice: "marin" }, { text: "Hi", voice: "Kore", model: "other" }]) {
      const send = vi.fn();
      expect((await speak(post("/x", body), config, send)).status).toBe(400);
      expect(send).not.toHaveBeenCalled();
    }
    expect(sentence("  Hi\u0007 there ")).toBe("Hi  there");
  });
  it("counts characters, asks for raw PCM with nothing stored, and streams only the audio", async () => {
    const send = vi.fn().mockResolvedValueOnce(allowed()).mockResolvedValueOnce(sse([
      'event: interaction.created\ndata: {"event_type":"interaction.created"}\n\n', audioEvent([1, 2, 3, 4]).slice(0, 30), audioEvent([1, 2, 3, 4]).slice(30), audioEvent([5, 6]),
      'event: interaction.completed\ndata: {"event_type":"interaction.completed"}\n\ndata: [DONE]\n\n']));
    const result = await speak(post("/x", { text: "You have two meetings tomorrow.", voice: "Sulafat" }), config, send, unchecked);
    expect(result.status).toBe(200); expect(result.headers.get("content-type")).toContain("audio/l16");
    expect(await bytes(result.body!)).toEqual([1, 2, 3, 4, 5, 6]);
    expect(JSON.parse(send.mock.calls[0][1].body)).toEqual({ kind: "characters", amount: 31 });
    const request = JSON.parse(send.mock.calls[1][1].body);
    expect(request.model).toBe(SPEECH_MODEL); expect(request.store).toBe(false); expect(request.stream).toBe(true);
    expect(request.response_format).toEqual({ type: "audio", mime_type: "audio/l16", sample_rate: 24000 });
    expect(request.generation_config.speech_config).toEqual([{ voice: "Sulafat" }]);
    expect(request.input[0].content[0].text).toBe("You have two meetings tomorrow.");
  });
  it("stops at the daily allowance and hides upstream failures", async () => {
    let send = vi.fn().mockResolvedValueOnce(Response.json({ allowed: false }));
    expect((await speak(post("/x", { text: "Hi", voice: "Kore" }), config, send, unchecked)).status).toBe(429);
    send = vi.fn().mockResolvedValueOnce(allowed()).mockResolvedValueOnce(new Response("secret detail", { status: 500 }));
    const failed = await speak(post("/x", { text: "Hi", voice: "Kore" }), config, send, unchecked);
    expect(failed.status).toBe(502); expect(await failed.text()).not.toContain("secret detail");
  });
  it("ignores malformed events and a final line without a newline", async () => {
    const last = audioEvent([9, 9]).trim().split("\n").pop()!;
    expect(await bytes(pcmStream(sse(["data: {not json\n", "data: {\"event_type\":\"step.delta\",\"delta\":{\"type\":\"text\",\"data\":\"eA==\"}}\n", last]).body!))).toEqual([9, 9]);
  });
});

describe("session check", () => {
  const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url");
  async function signer() {
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    const jwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "fictional-key" };
    const sign = async (claims: Record<string, unknown>, kid = "fictional-key") => {
      const head = encode({ alg: "ES256", kid, typ: "JWT" }) + "." + encode(claims);
      const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(head));
      return "Bearer " + head + "." + Buffer.from(signature).toString("base64url");
    };
    return { jwk, sign };
  }
  const claims = (overrides: Record<string, unknown> = {}) => ({ sub: "fictional-user", role: "authenticated", aud: "authenticated",
    iss: "https://keys.example.invalid/auth/v1", exp: Math.floor(Date.now() / 1000) + 600, is_anonymous: false, ...overrides });
  const keyed = { ...config, supabaseURL: "https://keys.example.invalid" };

  it("speeds up only an unexpired, signed, ordinary session of this project", async () => {
    const { jwk, sign } = await signer();
    const send = vi.fn(async () => Response.json({ keys: [jwk] }));
    const check = sessionCheck(keyed, send as typeof fetch);
    expect(await check(await sign(claims()))).toBe("valid");
    expect(await check(await sign(claims({ exp: 1 })))).toBe("invalid");
    for (const unusual of [{ is_anonymous: true }, { role: "anon" }, { iss: "https://other.example.invalid/auth/v1" }, { aud: "other" }])
      expect(await check(await sign(claims(unusual)))).toBe("unknown");
    expect(await check(await sign(claims(), "other-key"))).toBe("invalid");
    const forged = (await sign(claims())).replace(/\.[^.]+$/, "." + Buffer.from(new Uint8Array(64)).toString("base64url"));
    expect(await check(forged)).toBe("invalid");
    expect(await check("Bearer not-a-session")).toBe("invalid");
    expect(send).toHaveBeenCalledTimes(1);
  });
  it("leaves the decision to the database when the keys cannot be read", async () => {
    const { sign } = await signer();
    const check = sessionCheck({ ...keyed, supabaseURL: "https://down.example.invalid" }, (async () => new Response("", { status: 500 })) as typeof fetch);
    expect(await check((await sign(claims({ iss: "https://down.example.invalid/auth/v1" }))))).toBe("unknown");
  });
  it("warms connections without speaking, counting or calling the model", async () => {
    const send = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) => new Response(null, { status: 404 }));
    const warmed = await speak(post("/x", { warm: true }), config, send as typeof fetch, async () => "valid");
    expect(warmed.status).toBe(204);
    expect(send.mock.calls.map(call => String(call[0]))).toEqual(["https://generativelanguage.googleapis.com/"]);
    expect((await speak(post("/x", { warm: true }), config, vi.fn() as typeof fetch, async () => "invalid")).status).toBe(401);
    expect((await speak(post("/x", { warm: true, text: "Hi" }), config, vi.fn() as typeof fetch, async () => "valid")).status).toBe(400);
  });
  it("refuses an invalid session before drawing on the allowance or calling Google", async () => {
    const send = vi.fn();
    const result = await speak(post("/x", { text: "Hi", voice: "Kore" }), config, send, async () => "invalid");
    expect(result.status).toBe(401); expect(send).not.toHaveBeenCalled();
  });
  it("starts speech with the allowance for a verified session and cancels it when the allowance refuses", async () => {
    let speechSignal: AbortSignal | undefined;
    const send = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      if (String(url).includes("consume_voice_allowance")) {
        expect(send.mock.calls.some(call => String(call[0]).includes("interactions"))).toBe(true);
        return Response.json({ allowed: false });
      }
      speechSignal = init?.signal ?? undefined;
      return sse([audioEvent([1, 2])]);
    });
    const result = await speak(post("/x", { text: "Hi", voice: "Kore" }), config, send as typeof fetch, async () => "valid");
    expect(result.status).toBe(429); expect(speechSignal?.aborted).toBe(true);
  });
  it("streams audio with timings once both finish", async () => {
    const send = vi.fn(async (url: string | URL | Request) => String(url).includes("consume_voice_allowance") ? allowed() : sse([audioEvent([7, 8])]));
    const result = await speak(post("/x", { text: "Hi", voice: "Kore" }), config, send as typeof fetch, async () => "valid");
    expect(result.status).toBe(200); expect(result.headers.get("server-timing")).toMatch(/allowance;dur=\d+, speech;dur=\d+/);
    expect(await bytes(result.body!)).toEqual([7, 8]);
  });
});

describe("voice brain", () => {
  const keyed = { ...config, openaiKey: "fictional-openai-key" };
  const turn = { input: [{ role: "developer", content: "Fictional voice rules." }, { role: "user", content: "What's on Friday?" },
    { type: "function_call_output", call_id: "c1", output: "{}" }], tools: [{ type: "function", name: "get_agenda", parameters: {} }], cache_key: "calshot-voice-0f1e2d3c" };
  const events = () => sse(['data: {"type":"response.output_text.delta","delta":"Hi."}\n\n', 'data: {"type":"response.completed","response":{"output":[]}}\n\n']);

  it("fixes the model, tier, effort, length and storage, and relays OpenAI's stream unchanged", async () => {
    const send = vi.fn(async (url: string | URL | Request, _init?: RequestInit) => String(url).includes("consume_voice_allowance") ? allowed() : events());
    const result = await brain(post("/x", turn), keyed, send as typeof fetch, async () => "valid");
    expect(result.status).toBe(200); expect(result.headers.get("content-type")).toBe("text/event-stream");
    expect(new TextDecoder().decode(new Uint8Array(await bytes(result.body!)))).toContain('"delta":"Hi."');
    const openai = send.mock.calls.find(call => String(call[0]) === "https://api.openai.com/v1/responses")!;
    const request = JSON.parse((openai[1] as RequestInit).body as string);
    expect(request).toMatchObject({ model: BRAIN_MODEL, service_tier: "ultrafast", reasoning: { effort: "low" }, store: false, stream: true,
      max_output_tokens: 2000, prompt_cache_key: "calshot-voice-calshot-voice-0f1e2d3c", parallel_tool_calls: false });
    expect(request.input).toEqual(turn.input); expect(request.tools).toEqual(turn.tools);
    expect(((openai[1] as RequestInit).headers as Record<string, string>).Authorization).toBe("Bearer fictional-openai-key");
    const allowance = send.mock.calls.find(call => String(call[0]).includes("consume_voice_allowance"))!;
    expect(JSON.parse((allowance[1] as RequestInit).body as string)).toEqual({ kind: "brain", amount: 1 });
  });
  it("accepts only conversation items and function tools", () => {
    expect(brainBody(turn)).not.toBeNull();
    for (const bad of [
      { ...turn, model: "other" }, { ...turn, input: [] }, { ...turn, cache_key: "BAD KEY" },
      { ...turn, input: [{ role: "system", content: "x" }] }, { ...turn, input: [{ type: "message", role: "system", content: "x" }] },
      { ...turn, input: [{ type: "web_search_call" }] }, { ...turn, tools: [{ type: "web_search" }] },
      { ...turn, tools: [{ type: "function", name: "Bad Name" }] }, { ...turn, input: Array(401).fill({ role: "user", content: "x" }) }])
      expect(brainBody(bad as Record<string, unknown>)).toBeNull();
  });
  it("refuses before any model call: no key, no session, bad body, invalid session", async () => {
    const send = vi.fn();
    expect((await brain(post("/x", turn), config, send, async () => "valid")).status).toBe(503);
    expect((await brain(post("/x", turn, false), keyed, send, async () => "valid")).status).toBe(401);
    expect((await brain(post("/x", { ...turn, tools: [{ type: "web_search" }] }), keyed, send, async () => "valid")).status).toBe(400);
    expect((await brain(post("/x", turn), keyed, send, async () => "invalid")).status).toBe(401);
    expect(send).not.toHaveBeenCalled();
  });
  it("cancels the model when the allowance refuses, and waits for the database when the session is unchecked", async () => {
    let signal: AbortSignal | undefined;
    const refusing = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      if (String(url).includes("consume_voice_allowance")) return Response.json({ allowed: false });
      signal = init?.signal ?? undefined; return events();
    });
    expect((await brain(post("/x", turn), keyed, refusing as typeof fetch, async () => "valid")).status).toBe(429);
    expect(signal?.aborted).toBe(true);
    const ordered: string[] = [];
    const unchecked = vi.fn(async (url: string | URL | Request) => { ordered.push(String(url)); return String(url).includes("consume_voice_allowance") ? Response.json({ allowed: false }) : events(); });
    expect((await brain(post("/x", turn), keyed, unchecked as typeof fetch, async () => "unknown")).status).toBe(429);
    expect(ordered.every(url => url.includes("consume_voice_allowance"))).toBe(true);
  });
  it("never forwards OpenAI's error text", async () => {
    const send = vi.fn(async (url: string | URL | Request) => String(url).includes("consume_voice_allowance") ? allowed() : new Response("quoted request text", { status: 500 }));
    const result = await brain(post("/x", turn), keyed, send as typeof fetch, async () => "valid");
    expect(result.status).toBe(502); expect(await result.text()).not.toContain("quoted");
  });
});
