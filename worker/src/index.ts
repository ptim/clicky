/**
 * Clicky Proxy Worker
 *
 * Proxies requests to Claude and ElevenLabs APIs so the app never
 * ships with raw API keys. Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat              → Anthropic Messages API (streaming)
 *   POST /tts               → ElevenLabs TTS API
 *   POST /transcribe-token  → AssemblyAI temporary streaming token
 *
 * Every request must carry the shared secret in the
 * `X-Clicky-Proxy-Secret` header. Without it, anyone who finds the
 * worker URL (it is compiled into the app) could spend your API credit.
 */

interface Env {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
  CLICKY_PROXY_SHARED_SECRET: string;
}

const PROXY_SHARED_SECRET_HEADER_NAME = "X-Clicky-Proxy-Secret";

// Only the models the app's model picker offers. The worker enforces this
// so a leaked secret can't be used to run arbitrary (pricier) models.
const ALLOWED_CLAUDE_MODELS = new Set(["claude-sonnet-4-6", "claude-opus-4-6"]);

// The app asks for at most 1024 output tokens; clamp anything larger.
const MAXIMUM_CLAUDE_OUTPUT_TOKENS = 1024;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    // Fail closed: if the secret was never configured, refuse everything
    // rather than silently running as an open proxy.
    if (!env.CLICKY_PROXY_SHARED_SECRET) {
      console.error("CLICKY_PROXY_SHARED_SECRET is not set; refusing all requests.");
      return new Response("Proxy is not configured", { status: 500 });
    }

    const providedSharedSecret = request.headers.get(PROXY_SHARED_SECRET_HEADER_NAME) ?? "";
    const isSharedSecretValid = await isEqualInConstantTime(
      providedSharedSecret,
      env.CLICKY_PROXY_SHARED_SECRET
    );
    if (!isSharedSecretValid) {
      return new Response("Unauthorized", { status: 401 });
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

/**
 * Compares two strings without leaking how many leading characters match.
 * Hashing first gives both sides the same length, which timingSafeEqual requires.
 */
async function isEqualInConstantTime(providedValue: string, expectedValue: string): Promise<boolean> {
  const textEncoder = new TextEncoder();
  const [providedValueDigest, expectedValueDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", textEncoder.encode(providedValue)),
    crypto.subtle.digest("SHA-256", textEncoder.encode(expectedValue)),
  ]);
  return crypto.subtle.timingSafeEqual(providedValueDigest, expectedValueDigest);
}

async function handleChat(request: Request, env: Env): Promise<Response> {
  let requestBody: Record<string, unknown>;
  try {
    requestBody = await request.json();
  } catch {
    return new Response("Request body must be JSON", { status: 400 });
  }

  if (typeof requestBody.model !== "string" || !ALLOWED_CLAUDE_MODELS.has(requestBody.model)) {
    return new Response(`Model not allowed: ${String(requestBody.model)}`, { status: 400 });
  }

  const requestedMaxTokens = typeof requestBody.max_tokens === "number"
    ? requestBody.max_tokens
    : MAXIMUM_CLAUDE_OUTPUT_TOKENS;
  requestBody.max_tokens = Math.min(requestedMaxTokens, MAXIMUM_CLAUDE_OUTPUT_TOKENS);

  const body = JSON.stringify(requestBody);

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] Anthropic API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const voiceId = env.ELEVENLABS_VOICE_ID;

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}
