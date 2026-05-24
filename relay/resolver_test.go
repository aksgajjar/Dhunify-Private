package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

const testVideoID = "dQw4w9WgXcQ" // valid 11-char shape

func makeSeededBlob(seed, size int) []byte {
	b := make([]byte, size)
	for i := range b {
		b[i] = byte((i*131 + seed*7 + 3) % 251)
	}
	return b
}

// serveRange answers a bounded upstream subrange (bytes=A-B) like googlevideo,
// truncating to serveLimit bytes (declares full length, delivers short, drops
// conn → client unexpected EOF). The relay only ever sends bounded ranges.
func serveRange(w http.ResponseWriter, r *http.Request, blob []byte, serveLimit int64) {
	total := int64(len(blob))
	var a, b int64
	_, _ = fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &a, &b)
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
	w.Header().Set("Content-Length", strconv.FormatInt(reqLen, 10))
	w.WriteHeader(http.StatusPartialContent)
	_, _ = w.Write(blob[a : a+serveLen])
}

// newMultiBlobUpstream serves a distinct blob per ?v=<id> (queue simulation),
// optionally truncating large ranges.
func newMultiBlobUpstream(blobs map[string][]byte, serveLimit int64) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		blob, ok := blobs[r.URL.Query().Get("v")]
		if !ok {
			http.Error(w, "unknown video", http.StatusNotFound)
			return
		}
		serveRange(w, r, blob, serveLimit)
	}))
}

// newExpiringUpstream serves a token-stamped URL but 403s once a token has
// served killAfter requests (and immediately 403s tok="dead"). Forces the
// relay's transparent re-resolve. Re-resolve hands out a fresh token.
func newExpiringUpstream(blob []byte, killAfter int) *httptest.Server {
	var mu sync.Mutex
	counts := map[string]int{}
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok := r.URL.Query().Get("tok")
		if tok == "dead" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		mu.Lock()
		counts[tok]++
		n := counts[tok]
		mu.Unlock()
		if n > killAfter {
			http.Error(w, "url expired", http.StatusForbidden)
			return
		}
		serveRange(w, r, blob, 1<<30) // no truncation here; isolate expiry behavior
	}))
}

// fakeResolver stands in for yt-dlp. With seq set, returns those URLs in order
// (use "{id}" placeholder); otherwise stamps base?v=id&tok=N, bumping N on force.
type fakeResolver struct {
	mu           sync.Mutex
	base         string
	seq          []string
	i            int
	curTok       int
	forceCount   int
	resolveCount int
}

func (f *fakeResolver) resolve(_ context.Context, id string, force bool) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.resolveCount++
	if force {
		f.forceCount++
	}
	if len(f.seq) > 0 {
		u := f.seq[f.i]
		if f.i < len(f.seq)-1 {
			f.i++
		}
		return strings.ReplaceAll(u, "{id}", id), nil
	}
	if force || f.curTok == 0 {
		f.curTok++
	}
	return fmt.Sprintf("%s?v=%s&tok=%d", f.base, id, f.curTok), nil
}

// startRelayWithResolver serves handleStream with a fake resolver and no
// TEST_URL fallback, so the id path is exercised exclusively.
func startRelayWithResolver(t *testing.T, fr urlResolver) *httptest.Server {
	t.Helper()
	oldR, oldURL := streamResolver, testTargetURL
	streamResolver = fr
	testTargetURL = ""
	srv := httptest.NewServer(http.HandlerFunc(handleStream))
	t.Cleanup(func() {
		srv.Close()
		streamResolver = oldR
		testTargetURL = oldURL
	})
	return srv
}

// --- resolver unit tests (no network / no yt-dlp) ---------------------------

func TestValidVideoID(t *testing.T) {
	ok := []string{"dQw4w9WgXcQ", "_-aA09zZ8x1"}
	bad := []string{"", "short", "toolongtoolong", "bad/id/12345", "abcdefghij!", "abcdefghijk1x"}
	for _, id := range ok {
		if !validVideoID(id) {
			t.Fatalf("expected valid: %q", id)
		}
	}
	for _, id := range bad {
		if validVideoID(id) {
			t.Fatalf("expected invalid: %q", id)
		}
	}
}

func TestExpiryOfParsesExpireParam(t *testing.T) {
	u := "https://x.googlevideo.com/videoplayback?expire=1779669071&itag=139"
	got := expiryOf(u)
	if got.Unix() != 1779669071 {
		t.Fatalf("expiryOf = %d want 1779669071", got.Unix())
	}
	// missing expire → short TTL in the future
	if expiryOf("https://x/y?itag=139").Before(time.Now()) {
		t.Fatalf("fallback expiry should be in the future")
	}
}

func TestResolverCacheHitSkipsExec(t *testing.T) {
	y := newYTDLPResolver()
	y.cache[testVideoID] = cacheEntry{url: "http://cached/url", expireAt: time.Now().Add(time.Hour)}
	// Non-force with a live cache entry must return without shelling to yt-dlp.
	got, err := y.resolve(context.Background(), testVideoID, false)
	if err != nil || got != "http://cached/url" {
		t.Fatalf("cache hit: got %q err %v", got, err)
	}
}

// --- integration: resolver -> relay -> stitching ----------------------------

func assertFullBody(t *testing.T, resp *http.Response, body, want []byte, status int) {
	t.Helper()
	if resp.StatusCode != status {
		t.Fatalf("status=%d want %d", resp.StatusCode, status)
	}
	cl, _ := strconv.ParseInt(resp.Header.Get("Content-Length"), 10, 64)
	if cl != int64(len(want)) {
		t.Fatalf("Content-Length=%d want %d", cl, len(want))
	}
	if int64(len(body)) != cl {
		t.Fatalf("delivered %d != advertised Content-Length %d (short body)", len(body), cl)
	}
	if !bytesEqual(body, want) {
		t.Fatalf("delivered bytes != expected source bytes")
	}
	assertCleanHTTP(t, resp)
}

// resolver -> relay -> bounded stitching, against a truncating upstream.
func TestRelayResolveByIDFullBody(t *testing.T) {
	blob := makeSeededBlob(1, 3*int(subChunk)+1234)
	up := newMultiBlobUpstream(map[string][]byte{testVideoID: blob}, 700_000)
	defer up.Close()
	fr := &fakeResolver{base: up.URL}
	relay := startRelayWithResolver(t, fr)

	resp, body := fetch(t, relay.URL+"/stream?id="+testVideoID, "")
	assertFullBody(t, resp, body, blob, http.StatusOK)
	if fr.resolveCount == 0 {
		t.Fatalf("resolver was never called")
	}
}

// Seek mid-track: an open-ended range from an offset returns the full tail.
func TestRelaySeekMidTrack(t *testing.T) {
	blob := makeSeededBlob(2, 3*int(subChunk)+99)
	total := int64(len(blob))
	up := newMultiBlobUpstream(map[string][]byte{testVideoID: blob}, 700_000)
	defer up.Close()
	relay := startRelayWithResolver(t, &fakeResolver{base: up.URL})

	const off = 1_500_000
	resp, body := fetch(t, relay.URL+"/stream?id="+testVideoID, fmt.Sprintf("bytes=%d-", off))
	assertFullBody(t, resp, body, blob[off:], http.StatusPartialContent)
	wantCR := fmt.Sprintf("bytes %d-%d/%d", off, total-1, total)
	if cr := resp.Header.Get("Content-Range"); cr != wantCR {
		t.Fatalf("Content-Range=%q want %q", cr, wantCR)
	}
}

// Queue transition: consecutive distinct ids each resolve and play in full.
func TestRelayQueueTransition(t *testing.T) {
	id1, id2 := "AAAAAAAAAAA", "BBBBBBBBBBB"
	b1 := makeSeededBlob(11, 2*int(subChunk)+11)
	b2 := makeSeededBlob(22, int(subChunk)+22222)
	up := newMultiBlobUpstream(map[string][]byte{id1: b1, id2: b2}, 700_000)
	defer up.Close()
	relay := startRelayWithResolver(t, &fakeResolver{base: up.URL})

	for _, tc := range []struct {
		id   string
		blob []byte
	}{{id1, b1}, {id2, b2}, {id1, b1}} { // includes replay of id1
		resp, body := fetch(t, relay.URL+"/stream?id="+tc.id, "")
		assertFullBody(t, resp, body, tc.blob, http.StatusOK)
	}
}

// Upstream URL expires mid-stream (403 after killAfter): relay re-resolves
// transparently and still delivers the complete body — no playback gap.
func TestRelayReResolvesOnMidStreamExpiry(t *testing.T) {
	blob := makeSeededBlob(3, 3*int(subChunk)+555)
	up := newExpiringUpstream(blob, 2) // each token good for 2 requests
	defer up.Close()
	fr := &fakeResolver{base: up.URL}
	relay := startRelayWithResolver(t, fr)

	resp, body := fetch(t, relay.URL+"/stream?id="+testVideoID, "bytes=0-")
	assertFullBody(t, resp, body, blob, http.StatusPartialContent)
	if fr.forceCount == 0 {
		t.Fatalf("expected at least one transparent re-resolve, got 0")
	}
}

// Initial (cached) URL already dead (403): relay re-resolves before committing
// headers, then streams the full body.
func TestRelayReResolvesOnDeadInitialURL(t *testing.T) {
	blob := makeSeededBlob(4, 2*int(subChunk)+7)
	up := newExpiringUpstream(blob, 1<<30) // live token always serves
	defer up.Close()
	// First resolve → dead URL (probe 403); forced resolve → live token URL.
	fr := &fakeResolver{seq: []string{
		up.URL + "?v={id}&tok=dead",
		up.URL + "?v={id}&tok=1",
	}}
	relay := startRelayWithResolver(t, fr)

	resp, body := fetch(t, relay.URL+"/stream?id="+testVideoID, "")
	assertFullBody(t, resp, body, blob, http.StatusOK)
	if fr.forceCount == 0 {
		t.Fatalf("expected a forced re-resolve after dead initial URL")
	}
}

// --- request validation -----------------------------------------------------

func TestRelayRejectsInvalidID(t *testing.T) {
	relay := startRelayWithResolver(t, &fakeResolver{base: "http://unused"})
	resp, _ := fetch(t, relay.URL+"/stream?id=not-valid", "")
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status=%d want 400", resp.StatusCode)
	}
}

func TestRelayMissingIDNoFallback(t *testing.T) {
	relay := startRelayWithResolver(t, &fakeResolver{base: "http://unused"})
	resp, _ := fetch(t, relay.URL+"/stream", "")
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status=%d want 503", resp.StatusCode)
	}
}

// HEAD on the id path returns headers with the full advertised length, no body.
func TestRelayHeadByID(t *testing.T) {
	blob := makeSeededBlob(5, int(subChunk)+1)
	up := newMultiBlobUpstream(map[string][]byte{testVideoID: blob}, 700_000)
	defer up.Close()
	relay := startRelayWithResolver(t, &fakeResolver{base: up.URL})

	req, _ := http.NewRequest(http.MethodHead, relay.URL+"/stream?id="+testVideoID, nil)
	resp, err := rawClient().Do(req)
	if err != nil {
		t.Fatalf("HEAD: %v", err)
	}
	b, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if len(b) != 0 {
		t.Fatalf("HEAD body=%d want 0", len(b))
	}
	if cl, _ := strconv.ParseInt(resp.Header.Get("Content-Length"), 10, 64); cl != int64(len(blob)) {
		t.Fatalf("HEAD Content-Length=%d want %d", cl, len(blob))
	}
}
