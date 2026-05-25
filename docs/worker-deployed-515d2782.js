/**
 * Dhunify Audio Worker v7
 * ───────────────────────
 * Edge proxy + R2 cache. First play for a given song downloads from
 * upstream (JioSaavn CDN via Fly 302 or googlevideo via Fly resolver)
 * and mirrors the bytes into R2. Subsequent plays are served direct
 * from R2 at whichever Cloudflare PoP is nearest the listener — no
 * upstream round-trip, no re-resolve, sub-50ms TTFB from Toronto.
 *
 * Endpoints:
 *   GET /stream/{id}   — audio stream, id is jio_XXX or yt_XXX
 *   GET /audio/{id}    — alias
 *   GET /resolve/{id}  — debug passthrough to Fly YT resolver
 *   GET /health        — liveness + cache stats
 *
 * Env bindings (wrangler.toml):
 *   BACKEND_URL   — https://dhunify-api.fly.dev
 *   AUDIO_CACHE   — R2 bucket (bucket_name = dhunify-audio)
 */

const DEFAULT_BACKEND = "https://dhunify-api.fly.dev";
const RESOLVE_TTL_MS = 4 * 3600 * 1000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
  "Access-Control-Allow-Headers": "Range",
  "Access-Control-Expose-Headers":
    "Content-Length, Content-Range, Accept-Ranges, Content-Type, X-Cache",
};

// ── Upstream resolvers ───────────────────────────────────────

async function resolveYouTube(videoId, env) {
  const cacheKey = `https://dhunify-cache.internal/v7/yt/${videoId}`;
  const cache = caches.default;

  try {
    const hit = await cache.match(cacheKey);
    if (hit) {
      const info = await hit.json();
      if (Date.now() - info.ts < RESOLVE_TTL_MS) return info;
    }
  } catch (_) {}

  const backend = env.BACKEND_URL || DEFAULT_BACKEND;
  let resp;
  try {
    resp = await fetch(`${backend}/resolve/yt_${videoId}`, {
      cf: { cacheTtl: 0 },
    });
  } catch (e) {
    return { error: `backend fetch: ${e.message}` };
  }
  if (!resp.ok) return { error: `backend HTTP ${resp.status}` };

  let data;
  try {
    data = await resp.json();
  } catch {
    return { error: "bad backend JSON" };
  }
  if (!data?.url) return { error: "backend returned no url" };

  const info = {
    url: data.url,
    mime: data.mime || "audio/mp4",
    source: data.source || "",
    ts: Date.now(),
  };
  try {
    await cache.put(
      cacheKey,
      new Response(JSON.stringify(info), {
        headers: { "Cache-Control": "max-age=14400" },
      })
    );
  } catch (_) {}
  return info;
}

async function resolveJioSaavn(fullId, env) {
  const backend = env.BACKEND_URL || DEFAULT_BACKEND;
  const url = `${backend}/stream?id=${encodeURIComponent(fullId)}&q=320`;
  let resp;
  try {
    resp = await fetch(url, {
      redirect: "manual",
      headers: {
        "User-Agent":
          "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
      },
    });
  } catch (e) {
    return { error: `backend fetch: ${e.message}` };
  }
  if (resp.status >= 300 && resp.status < 400) {
    const loc = resp.headers.get("Location");
    if (loc && loc !== "NULL" && loc.startsWith("http")) {
      return { url: loc, mime: "audio/mp4", source: "jiosaavn" };
    }
    return { error: `bad Location: ${loc}` };
  }
  if (resp.ok) {
    // Some backends stream directly without redirect.
    return { url, mime: "audio/mp4", source: "jiosaavn-direct" };
  }
  return { error: `backend HTTP ${resp.status}` };
}

// ── Src allowlist (prevents Worker becoming open proxy) ─────

function isAllowedUpstream(rawURL) {
  try {
    const u = new URL(rawURL);
    if (u.protocol !== "https:" && u.protocol !== "http:") return false;
    const h = u.hostname.toLowerCase();
    return (
      h.endsWith(".googlevideo.com") ||
      h.endsWith(".saavncdn.com") ||
      h.endsWith(".akamaized.net") ||
      h.endsWith(".ytimg.com")
    );
  } catch {
    return false;
  }
}

// ── R2 serve ─────────────────────────────────────────────────

function parseRange(header, size) {
  if (!header) return null;
  const m = header.match(/bytes=(\d+)-(\d*)/);
  if (!m) return null;
  const start = parseInt(m[1], 10);
  const end = m[2] ? parseInt(m[2], 10) : size - 1;
  if (isNaN(start)) return null;
  return { offset: start, length: (end - start) + 1 };
}

async function serveFromR2(r2key, request, env) {
  const head = await env.AUDIO_CACHE.head(r2key);
  if (!head) return null;

  const size = head.size;
  const rangeHeader = request.headers.get("Range");
  const range = rangeHeader ? parseRange(rangeHeader, size) : null;

  const obj = range
    ? await env.AUDIO_CACHE.get(r2key, { range })
    : await env.AUDIO_CACHE.get(r2key);
  if (!obj) return null;

  const h = new Headers();
  for (const [k, v] of Object.entries(CORS)) h.set(k, v);
  h.set("Content-Type", head.httpMetadata?.contentType || "audio/mp4");
  h.set("Accept-Ranges", "bytes");
  h.set("X-Cache", "HIT");

  if (range) {
    const end = range.offset + range.length - 1;
    h.set("Content-Length", String(range.length));
    h.set("Content-Range", `bytes ${range.offset}-${end}/${size}`);
    return new Response(obj.body, { status: 206, headers: h });
  }
  h.set("Content-Length", String(size));
  return new Response(obj.body, { status: 200, headers: h });
}

// Background populate: fetch full body, upload to R2. Non-blocking.
async function populateR2(r2key, upstreamURL, contentType, env) {
  try {
    const existing = await env.AUDIO_CACHE.head(r2key);
    if (existing) return;
    const resp = await fetch(upstreamURL, {
      headers: {
        "User-Agent":
          "Mozilla/5.0 (Linux; Android 15) Chrome/131.0.0.0 Mobile Safari/537.36",
      },
    });
    if (!resp.ok) return;
    await env.AUDIO_CACHE.put(r2key, resp.body, {
      httpMetadata: { contentType: contentType || "audio/mp4" },
    });
  } catch (e) {
    console.log(`R2 populate ${r2key} failed: ${e.message}`);
  }
}

// ── Main stream handler ─────────────────────────────────────

async function handleStream(rawId, request, env, ctx) {
  // Normalise: accept bare videoId (legacy) → treat as yt_.
  const id = rawId.startsWith("jio_") || rawId.startsWith("yt_")
    ? rawId
    : `yt_${rawId}`;
  const r2key = `audio/${id}.m4a`;

  // 1. Try R2
  try {
    const cached = await serveFromR2(r2key, request, env);
    if (cached) return cached;
  } catch (e) {
    console.log(`R2 serve error: ${e.message}`);
  }

  // 2. Miss — resolve upstream.
  // Client may pre-resolve a googlevideo URL and pass it as ?src= to
  // skip the server-side resolver (which is rate-limited on Fly IPs).
  // We validate the host to prevent the Worker from being abused as
  // an open proxy.
  const reqURL = new URL(request.url);
  const srcParam = reqURL.searchParams.get("src");
  let info;
  if (srcParam && isAllowedUpstream(srcParam)) {
    info = { url: srcParam, mime: "audio/mp4", source: "client-resolved" };
  } else if (id.startsWith("jio_")) {
    info = await resolveJioSaavn(id, env);
  } else {
    info = await resolveYouTube(id.slice(3), env);
  }
  if (info?.error || !info?.url) {
    return Response.json(
      { error: `Resolve failed for ${id}`, detail: info?.error || "?" },
      { status: 502, headers: CORS }
    );
  }

  // 3. Cache miss — stream upstream with BOUNDED-SUBRANGE STITCHING.
  //
  // googlevideo throttles large / open-ended ranges to ~30 KB/s but serves
  // bounded subranges (<= 8 MB) at multi-MB/s. AVPlayer issues open-ended
  // ranges and must fetch the moov (at EOF for these MP4s) before it reaches
  // readyToPlay; a raw passthrough gets throttled, so AVPlayer stalls forever
  // in `.unknown`. We fetch the client's requested range as a sequence of
  // bounded subranges and stitch them into one continuous, range-correct
  // response — the client always gets exactly the advertised Content-Length.
  const upHeaders = {
    "User-Agent":
      "Mozilla/5.0 (Linux; Android 15) Chrome/131.0.0.0 Mobile Safari/537.36",
  };

  // Probe total size with a tiny bounded range; re-resolve once on expiry.
  let probe;
  try {
    probe = await fetch(info.url, { headers: { ...upHeaders, Range: "bytes=0-1" } });
  } catch (e) {
    return Response.json({ error: `upstream fetch: ${e.message}` }, { status: 502, headers: CORS });
  }
  if ((probe.status === 403 || probe.status === 410) && id.startsWith("yt_")) {
    try { await caches.default.delete(`https://dhunify-cache.internal/v7/yt/${id.slice(3)}`); } catch (_) {}
    const fresh = await resolveYouTube(id.slice(3), env);
    if (fresh?.url) {
      info = fresh;
      try { probe = await fetch(info.url, { headers: { ...upHeaders, Range: "bytes=0-1" } }); } catch (_) {}
    }
  }
  if (probe.status !== 206 && probe.status !== 200) {
    return Response.json({ error: `CDN returned ${probe.status}` }, { status: 502, headers: CORS });
  }
  let total = 0;
  const probeCR = probe.headers.get("Content-Range"); // bytes 0-1/N
  if (probeCR) { const mm = probeCR.match(/\/(\d+)\s*$/); if (mm) total = parseInt(mm[1], 10); }
  if (!total && probe.status === 200) {
    const pcl = probe.headers.get("Content-Length");
    if (pcl) total = parseInt(pcl, 10);
  }
  try { await probe.body?.cancel(); } catch (_) {}

  ctx.waitUntil(populateR2(r2key, info.url, info.mime, env));

  // Couldn't determine size → fall back to a plain passthrough (best-effort).
  if (!total) {
    const fb = await fetch(info.url, { headers: upHeaders });
    const fh = new Headers();
    for (const [k, v] of Object.entries(CORS)) fh.set(k, v);
    fh.set("Content-Type", info.mime);
    fh.set("Accept-Ranges", "bytes");
    fh.set("X-Cache", "MISS");
    fh.set("X-Source", info.source || "unknown");
    return new Response(fb.body, { status: fb.status, headers: fh });
  }

  // Resolve the client's requested byte range against the known total.
  let start = 0, end = total - 1, isRange = false;
  const clientRange = request.headers.get("Range");
  if (clientRange) {
    const pr = parseRange(clientRange, total);
    if (pr) { start = pr.offset; end = Math.min(pr.offset + pr.length - 1, total - 1); isRange = true; }
  }
  const contentLength = end - start + 1;

  const rh = new Headers();
  for (const [k, v] of Object.entries(CORS)) rh.set(k, v);
  rh.set("Content-Type", info.mime);
  rh.set("Accept-Ranges", "bytes");
  rh.set("Content-Length", String(contentLength));
  if (isRange) rh.set("Content-Range", `bytes ${start}-${end}/${total}`);
  rh.set("X-Cache", "MISS");
  rh.set("X-Source", info.source || "unknown");

  if (request.method === "HEAD") {
    return new Response(null, { status: isRange ? 206 : 200, headers: rh });
  }

  const SUB = 4 * 1024 * 1024;        // 4 MB subrange — googlevideo throttles >= 16 MB
  const BUFFER_CAP = 8 * 1024 * 1024; // small ranges buffered for exact framing
  const srcURL = info.url;
  const fetchSub = (from, to) =>
    fetch(srcURL, { headers: { ...upHeaders, Range: `bytes=${from}-${to}` } });

  // Small ranges (AVPlayer's probe + moov reads) → buffer fully so the response
  // carries an exact Content-Length with no chunked framing.
  if (contentLength <= BUFFER_CAP) {
    const buf = new Uint8Array(contentLength);
    let off = 0, cur = start;
    while (cur <= end && off < contentLength) {
      const r = await fetchSub(cur, Math.min(cur + SUB - 1, end));
      if (r.status !== 206 && r.status !== 200) break;
      const ab = new Uint8Array(await r.arrayBuffer());
      if (ab.length === 0) break;
      const n = Math.min(ab.length, contentLength - off);
      buf.set(ab.subarray(0, n), off);
      off += n;
      cur += ab.length;
    }
    return new Response(buf.subarray(0, off), { status: isRange ? 206 : 200, headers: rh });
  }

  // Large ranges → consumer-driven ReadableStream. `pull` fetches the next
  // bounded subrange only when the client (AVPlayer) drains the queue, so the
  // stream lifetime is tied to the RESPONSE, not to `ctx.waitUntil` (which
  // Cloudflare truncated early on production → partial body vs Content-Length
  // → AVPlayer played to the gap then ran silent while its clock advanced).
  let cur = start;
  let reader = null; // reader for the current bounded subrange
  const stream = new ReadableStream({
    async pull(controller) {
      while (true) {
        if (!reader) {
          if (cur > end) {
            controller.close();
            return;
          }
          let r;
          try {
            r = await fetchSub(cur, Math.min(cur + SUB - 1, end));
          } catch (e) {
            controller.error(e);
            return;
          }
          if (r.status !== 206 && r.status !== 200) {
            controller.close(); // upstream gap — end cleanly rather than corrupt
            return;
          }
          reader = r.body.getReader();
        }
        const { done, value } = await reader.read();
        if (done) {
          reader = null; // subrange exhausted → next pull opens the next subrange
          continue;
        }
        controller.enqueue(value); // network-sized chunk → low TTFB, incremental
        cur += value.byteLength;    // advance by ACTUAL bytes (short read → remainder next subrange)
        return;
      }
    },
    cancel() {
      cur = end + 1; // client disconnected → stop
      if (reader) {
        try { reader.cancel(); } catch (_) {}
      }
    },
  });

  return new Response(stream, { status: isRange ? 206 : 200, headers: rh });
}

// ── Resolve passthrough (debug) ──────────────────────────────

async function handleResolve(videoId, env) {
  const info = await resolveYouTube(videoId, env);
  if (info?.error || !info?.url) {
    return Response.json(
      { error: info?.error || "no url" },
      { status: 502, headers: CORS }
    );
  }
  return Response.json(info, { headers: CORS });
}

// ── Router ───────────────────────────────────────────────────

export default {
  async fetch(request, env, ctx) {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS });
    }

    const path = new URL(request.url).pathname;

    if (path === "/" || path === "/health") {
      return Response.json(
        {
          status: "ok",
          version: "7.0",
          mode: "edge-proxy + r2-cache",
          backend: env.BACKEND_URL || DEFAULT_BACKEND,
          r2: env.AUDIO_CACHE ? "bound" : "missing",
        },
        { headers: CORS }
      );
    }

    // Accept ids with or without prefix: jio_XXX, yt_XXX, or bare videoId.
    let m = path.match(/^\/(stream|audio)\/((?:jio_|yt_)?[a-zA-Z0-9_-]{4,40})$/);
    if (m) return handleStream(m[2], request, env, ctx);

    m = path.match(/^\/resolve\/([a-zA-Z0-9_-]{4,30})$/);
    if (m) return handleResolve(m[1], env);

    return Response.json(
      { error: "Not found", paths: ["/health", "/stream/{id}", "/resolve/{id}"] },
      { status: 404, headers: CORS }
    );
  },
};
