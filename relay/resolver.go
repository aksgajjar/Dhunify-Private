package main

import (
	"bytes"
	"context"
	"fmt"
	"net/url"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// YouTube video IDs are exactly 11 chars of [A-Za-z0-9_-]. Validating before
// shelling out keeps untrusted query input out of the subprocess arg list.
var videoIDRe = regexp.MustCompile(`^[A-Za-z0-9_-]{11}$`)

func validVideoID(id string) bool { return videoIDRe.MatchString(id) }

// urlResolver maps a YouTube videoID to a fresh, IP-bound itag-139/140
// googlevideo URL. force bypasses any cache (used on upstream 403 / expiry).
type urlResolver interface {
	resolve(ctx context.Context, id string, force bool) (string, error)
}

// streamResolver is the active resolver. Swapped in tests for a fake so the
// integration suite never touches the network.
var streamResolver urlResolver = newYTDLPResolver()

// expirySkew refreshes a cached URL slightly before its googlevideo `expire`
// timestamp, so a stream never starts on an about-to-die URL.
const expirySkew = 60 * time.Second

type cacheEntry struct {
	url      string
	expireAt time.Time
}

// ytdlpResolver resolves via the yt-dlp binary and caches per id until expiry.
// yt-dlp owns all YouTube signature / n-param / client-fingerprint handling.
type ytdlpResolver struct {
	mu    sync.Mutex
	cache map[string]cacheEntry
}

func newYTDLPResolver() *ytdlpResolver {
	return &ytdlpResolver{cache: make(map[string]cacheEntry)}
}

func (y *ytdlpResolver) resolve(ctx context.Context, id string, force bool) (string, error) {
	if !force {
		y.mu.Lock()
		e, ok := y.cache[id]
		y.mu.Unlock()
		if ok && time.Now().Before(e.expireAt.Add(-expirySkew)) {
			return e.url, nil
		}
	}

	var stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, "yt-dlp",
		"-f", "139/140", // m4a/AAC only, 139 preferred, 140 fallback
		"-g", // print direct media URL(s)
		"--no-playlist",
		"--", "https://www.youtube.com/watch?v="+id,
	)
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("yt-dlp resolve %s: %w: %s", id, err, strings.TrimSpace(stderr.String()))
	}
	resolved := strings.TrimSpace(firstLine(string(out)))
	if resolved == "" {
		return "", fmt.Errorf("yt-dlp returned no url for %s", id)
	}

	y.mu.Lock()
	y.cache[id] = cacheEntry{url: resolved, expireAt: expiryOf(resolved)}
	y.mu.Unlock()
	return resolved, nil
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// expiryOf reads googlevideo's `expire` (unix seconds) query param. Falls back
// to a short TTL when absent/unparseable so a bad URL is retried soon.
func expiryOf(raw string) time.Time {
	u, err := url.Parse(raw)
	if err != nil {
		return time.Now().Add(5 * time.Minute)
	}
	if ts, perr := strconv.ParseInt(u.Query().Get("expire"), 10, 64); perr == nil && ts > 0 {
		return time.Unix(ts, 0)
	}
	return time.Now().Add(5 * time.Minute)
}
