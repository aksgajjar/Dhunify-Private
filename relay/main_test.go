package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

// deterministic ~3 MiB blob spanning several subChunks + a partial tail.
func makeBlob() []byte {
	b := make([]byte, 3*int(subChunk)+7777)
	for i := range b {
		b[i] = byte((i*131 + 7) % 251)
	}
	return b
}

// newFlakyUpstream simulates googlevideo: it ADVERTISES the full requested
// range length but delivers at most serveLimit bytes for any single request,
// then drops the connection — exactly the truncation that breaks AVPlayer.
// Open-ended (bytes=A-) and oversized ranges therefore truncate; small
// bounded ranges (<= serveLimit) are served complete.
func newFlakyUpstream(blob []byte, serveLimit int64) *httptest.Server {
	total := int64(len(blob))
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rng := r.Header.Get("Range")
		if rng == "" {
			w.Header().Set("Accept-Ranges", "bytes")
			w.Header().Set("Content-Type", "audio/mp4")
			w.Header().Set("Content-Length", strconv.FormatInt(total, 10))
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(blob)
			return
		}
		spec := strings.TrimPrefix(rng, "bytes=")
		sa, sb, _ := strings.Cut(spec, "-")
		a, _ := strconv.ParseInt(sa, 10, 64)
		var b int64
		if sb == "" {
			b = total - 1
		} else {
			b, _ = strconv.ParseInt(sb, 10, 64)
		}
		if b >= total {
			b = total - 1
		}
		reqLen := b - a + 1
		serveLen := reqLen
		if serveLen > serveLimit {
			serveLen = serveLimit
		}
		w.Header().Set("Accept-Ranges", "bytes")
		w.Header().Set("Content-Type", "audio/mp4")
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", a, b, total))
		// Promise the full requested length, then deliver maybe-short and
		// return → net/http closes the conn → client sees unexpected EOF.
		w.Header().Set("Content-Length", strconv.FormatInt(reqLen, 10))
		w.WriteHeader(http.StatusPartialContent)
		_, _ = w.Write(blob[a : a+serveLen])
	}))
}

// newGoodServer is a known-good static byte server (correct Range handling).
func newGoodServer(blob []byte) *httptest.Server {
	total := int64(len(blob))
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s, e, isRange, ok := parseClientRange(r.Header.Get("Range"), total)
		w.Header().Set("Accept-Ranges", "bytes")
		w.Header().Set("Content-Type", "audio/mp4")
		if !ok {
			http.Error(w, "bad range", http.StatusRequestedRangeNotSatisfiable)
			return
		}
		w.Header().Set("Content-Length", strconv.FormatInt(e-s+1, 10))
		if isRange {
			w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", s, e, total))
			w.WriteHeader(http.StatusPartialContent)
		} else {
			w.WriteHeader(http.StatusOK)
		}
		_, _ = w.Write(blob[s : e+1])
	}))
}

// startRelay points the package globals at target and serves handleStream.
func startRelay(t *testing.T, target string) *httptest.Server {
	t.Helper()
	old := testTargetURL
	testTargetURL = target
	srv := httptest.NewServer(http.HandlerFunc(handleStream))
	t.Cleanup(func() {
		srv.Close()
		testTargetURL = old
	})
	return srv
}

// rawClient never negotiates gzip, so we can inspect true wire headers.
func rawClient() *http.Client {
	return &http.Client{Transport: &http.Transport{DisableCompression: true}, Timeout: 30 * time.Second}
}

func fetch(t *testing.T, url, rng string) (*http.Response, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	if rng != "" {
		req.Header.Set("Range", rng)
	}
	resp, err := rawClient().Do(req)
	if err != nil {
		t.Fatalf("GET %s range=%q: %v", url, rng, err)
	}
	body, err := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if err != nil {
		t.Fatalf("read body range=%q: %v", rng, err)
	}
	return resp, body
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// --- Phase 0 (reproduce the bug internally) ---------------------------------

// The flaky upstream truncates a giant open-ended range — proving the failure
// mode the relay must defend against.
func TestFlakyUpstreamTruncatesOpenEndedRange(t *testing.T) {
	blob := makeBlob()
	up := newFlakyUpstream(blob, 700_000)
	defer up.Close()

	req, _ := http.NewRequest(http.MethodGet, up.URL, nil)
	req.Header.Set("Range", "bytes=262144-")
	resp, err := rawClient().Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	body, _ := io.ReadAll(resp.Body) // read error tolerated: truncation
	_ = resp.Body.Close()

	advertised := resp.Header.Get("Content-Length")
	t.Logf("flaky open-ended: advertised=%s delivered=%d", advertised, len(body))
	if int64(len(body)) >= int64(len(blob))-262144 {
		t.Fatalf("expected truncated body, got full %d bytes", len(body))
	}
	if advertised == strconv.Itoa(len(body)) {
		t.Fatalf("expected advertised length to exceed delivered (mismatch)")
	}
}

// And it serves a small bounded subrange completely — the relay's fix path.
func TestFlakyUpstreamServesBoundedSubrangeFully(t *testing.T) {
	blob := makeBlob()
	up := newFlakyUpstream(blob, 700_000)
	defer up.Close()

	resp, body := fetch(t, up.URL, "bytes=262144-462143") // 200000 bytes <= limit
	if resp.StatusCode != http.StatusPartialContent {
		t.Fatalf("status=%d", resp.StatusCode)
	}
	if len(body) != 200000 {
		t.Fatalf("bounded subrange: got %d want 200000", len(body))
	}
}

// --- Phase 1 (stitching delivers full advertised bodies) --------------------

func assertCleanHTTP(t *testing.T, resp *http.Response) {
	t.Helper()
	if len(resp.TransferEncoding) != 0 {
		t.Fatalf("unexpected Transfer-Encoding %v (must be Content-Length framed, no chunked)", resp.TransferEncoding)
	}
	if ce := resp.Header.Get("Content-Encoding"); ce != "" {
		t.Fatalf("unexpected Content-Encoding %q (must be identity/none)", ce)
	}
	if resp.Uncompressed {
		t.Fatalf("response was compressed upstream (gzip leaked)")
	}
	if resp.Header.Get("Content-Length") == "" {
		t.Fatalf("missing Content-Length (would force chunked)")
	}
	if resp.Header.Get("Accept-Ranges") != "bytes" {
		t.Fatalf("missing Accept-Ranges: bytes")
	}
	if resp.ProtoMajor != 1 || resp.ProtoMinor != 1 {
		t.Fatalf("downstream proto = HTTP/%d.%d, want HTTP/1.1", resp.ProtoMajor, resp.ProtoMinor)
	}
}

// Open-ended client range through the relay against a TRUNCATING upstream:
// the relay must still deliver the full advertised Content-Length.
func TestRelayDeliversFullBodyDespiteTruncatingUpstream(t *testing.T) {
	blob := makeBlob()
	total := int64(len(blob))
	up := newFlakyUpstream(blob, 700_000)
	defer up.Close()
	relay := startRelay(t, up.URL)

	const off = 262144
	resp, body := fetch(t, relay.URL+"/stream", fmt.Sprintf("bytes=%d-", off))

	if resp.StatusCode != http.StatusPartialContent {
		t.Fatalf("status=%d want 206", resp.StatusCode)
	}
	wantLen := total - off
	if cl, _ := strconv.ParseInt(resp.Header.Get("Content-Length"), 10, 64); cl != wantLen {
		t.Fatalf("advertised Content-Length=%d want %d", cl, wantLen)
	}
	if int64(len(body)) != wantLen {
		t.Fatalf("delivered %d bytes, advertised %d — short body", len(body), wantLen)
	}
	if !bytesEqual(body, blob[off:]) {
		t.Fatalf("delivered bytes do not match source slice")
	}
	wantCR := fmt.Sprintf("bytes %d-%d/%d", off, total-1, total)
	if cr := resp.Header.Get("Content-Range"); cr != wantCR {
		t.Fatalf("Content-Range=%q want %q", cr, wantCR)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "audio/mp4" {
		t.Fatalf("Content-Type=%q want audio/mp4 (passthrough)", ct)
	}
	assertCleanHTTP(t, resp)
}

// Heavy truncation (tiny serve limit) forces many re-requests; body must still
// be exact. Proves the stitch loop's short-read re-request logic.
func TestRelayStitchingResilientToHeavyTruncation(t *testing.T) {
	blob := makeBlob()
	total := int64(len(blob))
	up := newFlakyUpstream(blob, 100_003) // odd, < subChunk → forces re-requests
	defer up.Close()
	relay := startRelay(t, up.URL)

	resp, body := fetch(t, relay.URL+"/stream", "bytes=0-")
	if resp.StatusCode != http.StatusPartialContent {
		t.Fatalf("status=%d want 206", resp.StatusCode)
	}
	if int64(len(body)) != total {
		t.Fatalf("delivered %d want %d", len(body), total)
	}
	if !bytesEqual(body, blob) {
		t.Fatalf("stitched body != source")
	}
}

// No client Range → full 200 with the whole object, byte-for-byte.
func TestRelayFullFileNoRange(t *testing.T) {
	blob := makeBlob()
	up := newFlakyUpstream(blob, 700_000)
	defer up.Close()
	relay := startRelay(t, up.URL)

	resp, body := fetch(t, relay.URL+"/stream", "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d want 200", resp.StatusCode)
	}
	if int64(len(body)) != int64(len(blob)) || !bytesEqual(body, blob) {
		t.Fatalf("full file mismatch: got %d want %d", len(body), len(blob))
	}
	assertCleanHTTP(t, resp)
}

// Relay output must equal a known-good static server, byte-for-byte, across a
// spread of range shapes.
func TestRelayMatchesKnownGoodServer(t *testing.T) {
	blob := makeBlob()
	up := newFlakyUpstream(blob, 700_000)
	defer up.Close()
	good := newGoodServer(blob)
	defer good.Close()
	relay := startRelay(t, up.URL)

	ranges := []string{
		"bytes=0-1",
		"bytes=0-",
		"bytes=262144-",
		"bytes=1000000-2000000",
		"bytes=-65536",
		fmt.Sprintf("bytes=%d-", len(blob)-10),
	}
	for _, rng := range ranges {
		gResp, gBody := fetch(t, good.URL, rng)
		rResp, rBody := fetch(t, relay.URL+"/stream", rng)
		if gResp.StatusCode != rResp.StatusCode {
			t.Fatalf("range %s: status relay=%d good=%d", rng, rResp.StatusCode, gResp.StatusCode)
		}
		if !bytesEqual(rBody, gBody) {
			t.Fatalf("range %s: relay body (%d) != good body (%d)", rng, len(rBody), len(gBody))
		}
		if gResp.Header.Get("Content-Range") != rResp.Header.Get("Content-Range") {
			t.Fatalf("range %s: Content-Range relay=%q good=%q", rng,
				rResp.Header.Get("Content-Range"), gResp.Header.Get("Content-Range"))
		}
	}
}

// Simulate AppleCoreMedia's probe→scan→seek range pattern: every response must
// deliver exactly its advertised Content-Length and match the source bytes.
func TestRelayAppleCoreMediaPattern(t *testing.T) {
	blob := makeBlob()
	total := int64(len(blob))
	up := newFlakyUpstream(blob, 700_000)
	defer up.Close()
	relay := startRelay(t, up.URL)

	pattern := []string{
		"bytes=0-1",                     // size probe
		"bytes=0-",                      // full open-ended
		"bytes=262144-",                 // advancing offset
		"bytes=327680-",                 // advancing offset
		fmt.Sprintf("bytes=-%d", 1<<16), // tail (moov-at-end style)
		"bytes=49152-81919",             // small bounded
	}
	for _, rng := range pattern {
		resp, body := fetch(t, relay.URL+"/stream", rng)
		cl, _ := strconv.ParseInt(resp.Header.Get("Content-Length"), 10, 64)
		if int64(len(body)) != cl {
			t.Fatalf("range %s: delivered %d != advertised Content-Length %d", rng, len(body), cl)
		}
		s, e, _, ok := parseClientRange(rng, total)
		if !ok {
			t.Fatalf("range %s: test parse failed", rng)
		}
		if !bytesEqual(body, blob[s:e+1]) {
			t.Fatalf("range %s: body bytes != source[%d:%d]", rng, s, e+1)
		}
		assertCleanHTTP(t, resp)
	}
}

// HEAD returns headers (advertised length, range) with no body.
func TestRelayHeadNoBody(t *testing.T) {
	blob := makeBlob()
	up := newFlakyUpstream(blob, 700_000)
	defer up.Close()
	relay := startRelay(t, up.URL)

	req, _ := http.NewRequest(http.MethodHead, relay.URL+"/stream", nil)
	req.Header.Set("Range", "bytes=0-")
	resp, err := rawClient().Do(req)
	if err != nil {
		t.Fatalf("HEAD: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if len(body) != 0 {
		t.Fatalf("HEAD returned %d body bytes, want 0", len(body))
	}
	if cl, _ := strconv.ParseInt(resp.Header.Get("Content-Length"), 10, 64); cl != int64(len(blob)) {
		t.Fatalf("HEAD Content-Length=%d want %d", cl, len(blob))
	}
}
