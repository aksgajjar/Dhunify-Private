// Dhunify byte-range relay.
//
// Endpoints:
//
//	GET /healthz             → liveness
//	GET|HEAD /stream?id=<id> → resolve a YouTube videoID to a fresh, IP-bound
//	                           itag-139/140 googlevideo URL (via yt-dlp,
//	                           cached until expiry), then serve it as a
//	                           range-correct stream. On upstream 403 / URL
//	                           expiry the relay re-resolves transparently
//	                           mid-stream and continues — no downstream break.
//	GET|HEAD /stream         → fallback to TEST_URL env (manual single-URL
//	                           testing; no resolver).
//
// AVPlayer "silent killer" correctness:
//   - no http.Client.Timeout (would cap the whole stream → cut long tracks)
//   - DisableCompression + Accept-Encoding: identity (keep byte offsets)
//   - explicit Content-Length / Content-Range (no chunked); Accept-Ranges
//   - bounded upstream subranges stitched into ONE full downstream body:
//     googlevideo truncates giant/open-ended ranges, so we never rely on a
//     single open-ended upstream read — the client always gets exactly the
//     advertised Content-Length (unless the client itself cancels)
//   - upstream bound to request context (client disconnect → cancel)
package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Paste a fresh googlevideo URL here via env: TEST_URL=...
var testTargetURL = os.Getenv("TEST_URL")

// Non-AppleCoreMedia UA — the request fingerprint googlevideo serves
// (proven to pull at 6.5 MB/s from app URLSession).
const upstreamUA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"

// 64 KB pooled copy buffers → constant memory under concurrency.
var bufPool = sync.Pool{New: func() any { b := make([]byte, 64*1024); return &b }}

// One shared client. NO overall Timeout — only connect/header phases are
// bounded; the streaming body must not be capped.
var upstream = &http.Client{
	Transport: &http.Transport{
		MaxConnsPerHost:       64,
		MaxIdleConns:          64,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   5 * time.Second,
		ResponseHeaderTimeout: 10 * time.Second,
		DisableCompression:    true,
		ForceAttemptHTTP2:     false, // deterministic HTTP/1.1 byte semantics upstream
	},
}

// Bounded upstream subrange. googlevideo truncates giant / open-ended ranges
// mid-body; bounded subranges are served complete. The relay fetches the
// client-requested range as a sequence of these and stitches them into ONE
// continuous downstream body, so AVPlayer always receives exactly the
// advertised Content-Length.
const subChunk int64 = 1 << 20 // 1 MiB

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/stream", handleStream)

	addr := ":" + envOr("PORT", "8080")
	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      0, // streaming — cannot bound
		IdleTimeout:       120 * time.Second,
	}
	slog.Info("relay listening", "addr", addr, "fallbackTestURL", testTargetURL != "")
	if err := srv.ListenAndServe(); err != nil {
		slog.Error("server exited", "err", err)
		os.Exit(1)
	}
}

// maxReResolves bounds transparent URL refreshes per stream (expiry/403).
const maxReResolves = 3

func handleStream(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	ctx := r.Context()

	// Resolve the source URL: by videoID (yt-dlp, cached) or TEST_URL fallback.
	id := r.URL.Query().Get("id")
	var url string
	var err error
	switch {
	case id != "":
		if !validVideoID(id) {
			http.Error(w, "invalid video id", http.StatusBadRequest)
			return
		}
		url, err = streamResolver.resolve(ctx, id, false)
		if err != nil {
			slog.Error("resolve failed", "id", id, "err", err)
			http.Error(w, "resolve failed", http.StatusBadGateway)
			return
		}
	case testTargetURL != "":
		url = testTargetURL
	default:
		http.Error(w, "missing id and no TEST_URL fallback", http.StatusServiceUnavailable)
		return
	}

	// One bounded probe → total size + content type. Re-resolve once if the
	// (cached) URL is already dead (403/expired) before we commit headers.
	total, contentType, pstatus, perr := probeTotal(ctx, url)
	if needsReResolve(pstatus, perr) && id != "" {
		slog.Info("re-resolve on probe", "id", id, "probe_status", pstatus)
		if fresh, rerr := streamResolver.resolve(ctx, id, true); rerr == nil {
			url = fresh
			total, contentType, pstatus, perr = probeTotal(ctx, url)
		}
	}
	if perr != nil || total <= 0 {
		slog.Error("probe failed", "id", id, "status", pstatus, "err", errStr(perr))
		http.Error(w, "upstream probe failed", http.StatusBadGateway)
		return
	}

	reqStart, reqEnd, isRange, ok := parseClientRange(r.Header.Get("Range"), total)
	if !ok {
		w.Header().Set("Content-Range", "bytes */"+strconv.FormatInt(total, 10))
		http.Error(w, "invalid range", http.StatusRequestedRangeNotSatisfiable)
		return
	}
	promised := reqEnd - reqStart + 1

	// Headers written ONCE, before any body. Explicit Content-Length →
	// no chunked encoding. We commit to delivering exactly `promised` bytes.
	h := w.Header()
	h.Set("Accept-Ranges", "bytes")
	h.Set("Cache-Control", "no-store")
	if contentType == "" {
		contentType = "audio/mp4"
	}
	h.Set("Content-Type", contentType)
	h.Set("Content-Length", strconv.FormatInt(promised, 10))
	status := http.StatusOK
	if isRange {
		h.Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", reqStart, reqEnd, total))
		status = http.StatusPartialContent
	}
	w.WriteHeader(status)

	if r.Method == http.MethodHead {
		slog.Info("stream-head", "proto", r.Proto, "ua", r.UserAgent(),
			"status", status, "promised", promised, "total", total,
			"ms", time.Since(start).Milliseconds())
		return
	}

	bp := bufPool.Get().(*[]byte)
	defer bufPool.Put(bp)

	// Stitch the client range from bounded upstream subranges. A short read
	// (upstream EOF mid-body) re-requests the remainder; a 403/expiry triggers
	// a transparent re-resolve and continues at the SAME offset (same id+itag
	// addresses identical bytes). The downstream body equals the advertised
	// Content-Length unless the CLIENT cancels (ctx cancelled).
	var written int64
	cur := reqStart
	zeroStreak := 0
	reResolves := 0
	for cur <= reqEnd && ctx.Err() == nil {
		segStart := cur
		subEnd := segStart + subChunk - 1
		if subEnd > reqEnd {
			subEnd = reqEnd
		}
		want := subEnd - segStart + 1
		got, sstatus, serr := copySubrange(ctx, w, url, segStart, subEnd, *bp)
		written += got
		cur = segStart + got
		slog.Info("subrange",
			"upstream_range", fmt.Sprintf("bytes=%d-%d", segStart, subEnd),
			"want", want, "got", got, "complete", got == want,
			"status", sstatus, "err", errStr(serr))

		if got == want {
			zeroStreak = 0
			continue
		}
		// Incomplete subrange. If the upstream URL died, re-resolve and retry
		// the unfilled remainder from a fresh URL — playback never sees a gap.
		if needsReResolve(sstatus, serr) && id != "" && reResolves < maxReResolves {
			if fresh, rerr := streamResolver.resolve(ctx, id, true); rerr == nil {
				url = fresh
				reResolves++
				zeroStreak = 0
				slog.Info("re-resolve mid-stream", "id", id, "at", cur, "attempt", reResolves)
				continue
			}
		}
		if got == 0 {
			zeroStreak++
			if zeroStreak >= 3 {
				slog.Error("subrange stalled", "at", cur, "status", sstatus, "err", errStr(serr))
				break
			}
		} else {
			zeroStreak = 0
		}
	}

	slog.Info("stream",
		"id", id, "proto", r.Proto, "ua", r.UserAgent(), "status", status,
		"client_range", r.Header.Get("Range"),
		"promised", promised, "written", written,
		"full_body", written == promised,
		"total", total, "re_resolves", reResolves,
		"disconnected", ctx.Err() != nil,
		"ms", time.Since(start).Milliseconds())
}

// needsReResolve reports whether an upstream result means the URL is dead
// (expired / IP-rebound) and a fresh resolve should be attempted.
func needsReResolve(status int, err error) bool {
	switch status {
	case http.StatusForbidden, http.StatusUnauthorized, http.StatusGone:
		return true
	}
	return false
}

// probeTotal makes a tiny bounded probe (bytes=0-0) to learn the object's
// total size and content type without pulling the body.
func probeTotal(ctx context.Context, srcURL string) (total int64, contentType string, status int, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, srcURL, nil)
	if err != nil {
		return 0, "", 0, err
	}
	req.Header.Set("User-Agent", upstreamUA)
	req.Header.Set("Accept-Encoding", "identity")
	req.Header.Set("Range", "bytes=0-0")
	resp, err := upstream.Do(req)
	if err != nil {
		return 0, "", 0, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	ct := resp.Header.Get("Content-Type")
	if resp.StatusCode != http.StatusPartialContent && resp.StatusCode != http.StatusOK {
		return 0, ct, resp.StatusCode, fmt.Errorf("upstream probe status %d", resp.StatusCode)
	}
	if resp.StatusCode == http.StatusPartialContent {
		if _, after, found := strings.Cut(resp.Header.Get("Content-Range"), "/"); found {
			if t, perr := strconv.ParseInt(strings.TrimSpace(after), 10, 64); perr == nil && t > 0 {
				return t, ct, resp.StatusCode, nil
			}
		}
	}
	if resp.ContentLength > 0 {
		return resp.ContentLength, ct, resp.StatusCode, nil
	}
	return 0, ct, resp.StatusCode, fmt.Errorf("cannot determine total size (status %d)", resp.StatusCode)
}

// copySubrange fetches one bounded upstream subrange [from,to] from srcURL and
// copies it to w. Returns bytes written (may be < requested on upstream EOF),
// the upstream status, and any error.
func copySubrange(ctx context.Context, w io.Writer, srcURL string, from, to int64, buf []byte) (int64, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, srcURL, nil)
	if err != nil {
		return 0, 0, err
	}
	req.Header.Set("User-Agent", upstreamUA)
	req.Header.Set("Accept-Encoding", "identity")
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", from, to))
	resp, err := upstream.Do(req)
	if err != nil {
		return 0, 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusPartialContent && resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, resp.Body)
		return 0, resp.StatusCode, fmt.Errorf("upstream status %d", resp.StatusCode)
	}
	n, cerr := io.CopyBuffer(w, resp.Body, buf)
	return n, resp.StatusCode, cerr
}

// parseClientRange resolves a client Range header against the known total.
// Returns absolute [start,end], whether a range was requested, and validity.
func parseClientRange(header string, total int64) (start, end int64, isRange, ok bool) {
	if header == "" {
		return 0, total - 1, false, true
	}
	if !strings.HasPrefix(header, "bytes=") {
		return 0, 0, false, false
	}
	spec := strings.TrimPrefix(header, "bytes=")
	if i := strings.IndexByte(spec, ','); i >= 0 {
		spec = spec[:i] // only the first range is honored
	}
	startText, endText, found := strings.Cut(spec, "-")
	if !found {
		return 0, 0, false, false
	}
	switch {
	case startText == "": // suffix range: bytes=-N → last N bytes
		n, perr := strconv.ParseInt(endText, 10, 64)
		if perr != nil || n <= 0 {
			return 0, 0, false, false
		}
		if n > total {
			n = total
		}
		start, end = total-n, total-1
	case endText == "": // open-ended: bytes=START-
		s, perr := strconv.ParseInt(startText, 10, 64)
		if perr != nil {
			return 0, 0, false, false
		}
		start, end = s, total-1
	default:
		s, perr := strconv.ParseInt(startText, 10, 64)
		if perr != nil {
			return 0, 0, false, false
		}
		e, perr := strconv.ParseInt(endText, 10, 64)
		if perr != nil {
			return 0, 0, false, false
		}
		start, end = s, e
	}
	if start < 0 || start >= total || end < start {
		return 0, 0, false, false
	}
	if end >= total {
		end = total - 1
	}
	return start, end, true, true
}

func errStr(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
