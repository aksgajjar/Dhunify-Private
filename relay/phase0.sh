#!/usr/bin/env bash
# Phase 0 LIVE check — prove REAL googlevideo serves bounded subranges fully,
# with NO 403, before any device test. The relay's stitching is already
# validated offline (go test); this confirms the one remaining unknown:
# does real googlevideo honor bounded Range requests from this machine's IP?
#
# Run on the SAME machine/Wi-Fi that resolved the URL (IP-bound, ~6h TTL).
#
# Usage:
#   TEST_URL='https://...googlevideo.../videoplayback?...&itag=140...' ./phase0.sh
set -euo pipefail

UA='Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36'
: "${TEST_URL:?set TEST_URL to a fresh googlevideo itag-139/140 URL}"

hdr() { curl -s -A "$UA" -H 'Accept-Encoding: identity' "$@"; }

echo "== probe total (Range: bytes=0-0) =="
PROBE=$(hdr -D - -o /dev/null -r 0-0 "$TEST_URL")
printf '%s\n' "$PROBE" | tr -d '\r' | grep -iE '^HTTP/|content-range:|content-type:' || true
CODE=$(printf '%s' "$PROBE" | tr -d '\r' | awk 'NR==1{print $2}')
TOTAL=$(printf '%s' "$PROBE" | tr -d '\r' | awk -F/ 'tolower($0) ~ /content-range:/{print $2}')
if [ "$CODE" != "206" ]; then
  echo "FAIL: probe status=$CODE (need 206). 403 => URL expired or egress IP != URL's bound IP."
  exit 1
fi
echo "total=$TOTAL"

echo "== bug confirm: giant open-ended (Range: bytes=0-) — truncation/throttle expected =="
OE=$(hdr -o /dev/null -w '%{http_code} %{size_download}' -r 0- "$TEST_URL" || true)
echo "  open-ended -> code+size = $OE"

echo "== fix path: advancing bounded 1 MiB subranges (Range header) — must be 206, exact size, no 403 =="
fail=0
for off in 0 1048576 2097152 3145728; do
  end=$((off + 1048575))
  exp=1048576
  if [ -n "$TOTAL" ] && [ "$end" -ge "$TOTAL" ]; then end=$((TOTAL - 1)); exp=$((TOTAL - off)); fi
  R=$(hdr -o /dev/null -w '%{http_code} %{size_download}' -r ${off}-${end} "$TEST_URL")
  code=${R% *}; size=${R#* }
  status='OK'
  [ "$code" = "403" ] && { status='FAIL-403'; fail=1; }
  [ "$size" != "$exp" ] && { status="FAIL-short(got=$size want=$exp)"; fail=1; }
  echo "  bytes=${off}-${end}: code=$code size=$size -> $status"
done

echo "== A/B fallback: native &range= query param (used only if Range header 403s) =="
sep='?'; case "$TEST_URL" in *\?*) sep='&';; esac
RQ=$(hdr -o /dev/null -w '%{http_code} %{size_download}' "${TEST_URL}${sep}range=0-1048575" || true)
echo "  &range=0-1048575 -> code+size = $RQ"

if [ "$fail" -eq 0 ]; then
  echo "PASS: bounded subranges complete with no 403 — relay stitching will deliver full bodies."
else
  echo "FAIL: bounded Range-header path broke. If &range= above returned 206+1048576,"
  echo "      switch relay subrange fetch to the query-param mechanism."
  exit 1
fi
