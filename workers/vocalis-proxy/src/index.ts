/**
 * Vocalis license proxy — validates a friend license code, then forwards
 * STT / cleanup to OpenAI or xAI using server-side keys.
 *
 * Routes (OpenAI-shaped + Grok STT):
 *   POST /v1/audio/transcriptions  → api.openai.com
 *   POST /v1/chat/completions      → api.openai.com
 *   POST /v1/stt                   → api.x.ai
 */

export interface Env {
  LICENSE_CODES: string;
  OPENAI_API_KEY: string;
  XAI_API_KEY: string;
}

const OPENAI = "https://api.openai.com/v1";
const XAI = "https://api.x.ai/v1";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
      return Response.json({ ok: true, service: "vocalis-proxy" });
    }

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    const license = bearerToken(request);
    if (!(await licenseAllowed(license, env.LICENSE_CODES))) {
      return jsonError(401, "Invalid or missing license");
    }

    try {
      if (request.method === "POST" && url.pathname === "/v1/audio/transcriptions") {
        return await proxy(request, `${OPENAI}/audio/transcriptions`, env.OPENAI_API_KEY);
      }
      if (request.method === "POST" && url.pathname === "/v1/chat/completions") {
        return await proxy(request, `${OPENAI}/chat/completions`, env.OPENAI_API_KEY);
      }
      if (request.method === "POST" && url.pathname === "/v1/stt") {
        return await proxy(request, `${XAI}/stt`, env.XAI_API_KEY);
      }
      return jsonError(404, "Not found");
    } catch (err) {
      const message = err instanceof Error ? err.message : "Proxy error";
      console.error(JSON.stringify({ event: "proxy_error", message }));
      return jsonError(502, message);
    }
  },
} satisfies ExportedHandler<Env>;

function bearerToken(request: Request): string {
  const header = request.headers.get("Authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  return match?.[1]?.trim() ?? "";
}

/** Timing-safe membership check against comma-separated LICENSE_CODES. */
async function licenseAllowed(candidate: string, rawList: string | undefined): Promise<boolean> {
  if (!candidate || !rawList) return false;
  const codes = rawList
    .split(",")
    .map((c) => c.trim())
    .filter(Boolean);
  for (const code of codes) {
    if (await timingSafeEqual(candidate, code)) return true;
  }
  return false;
}

async function timingSafeEqual(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const aa = enc.encode(a);
  const bb = enc.encode(b);
  if (aa.byteLength !== bb.byteLength) {
    // Still hash both so length leaks are harder; always fail.
    const pad = new Uint8Array(Math.max(aa.byteLength, bb.byteLength) || 1);
    await crypto.subtle.digest("SHA-256", pad);
    return false;
  }
  const ha = await crypto.subtle.digest("SHA-256", aa);
  const hb = await crypto.subtle.digest("SHA-256", bb);
  const va = new Uint8Array(ha);
  const vb = new Uint8Array(hb);
  let diff = 0;
  for (let i = 0; i < va.length; i++) diff |= va[i]! ^ vb[i]!;
  return diff === 0;
}

async function proxy(request: Request, upstream: string, apiKey: string): Promise<Response> {
  if (!apiKey) {
    return jsonError(500, "Upstream API key not configured on proxy");
  }

  // Buffer the body. Streaming/duplex multipart from macOS → Worker → OpenAI/xAI
  // often arrives upstream with an empty file, which STT returns as blank text
  // ("Empty audio" in Vocalis) even though the listening waveform looked fine.
  const body = await request.arrayBuffer();
  if (body.byteLength === 0) {
    return jsonError(400, "Empty upload body");
  }

  const headers = new Headers();
  const contentType = request.headers.get("Content-Type");
  if (contentType) headers.set("Content-Type", contentType);
  headers.set("Authorization", `Bearer ${apiKey}`);
  headers.set("Content-Length", String(body.byteLength));

  console.log(
    JSON.stringify({
      event: "proxy_forward",
      upstream,
      bytes: body.byteLength,
      contentType: contentType ?? null,
    })
  );

  const upstreamResponse = await fetch(upstream, {
    method: "POST",
    headers,
    body,
    redirect: "follow",
  });

  const out = new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    statusText: upstreamResponse.statusText,
    headers: upstreamResponse.headers,
  });
  for (const [k, v] of Object.entries(corsHeaders())) {
    out.headers.set(k, v);
  }
  return out;
}

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type",
  };
}

function jsonError(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: { message } }), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders(),
    },
  });
}
