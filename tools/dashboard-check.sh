#!/usr/bin/env bash
# M4's dashboard surface, driven by `curl` (D94).
#
# What this asserts that unit tests cannot:
#
#   - every path in D88's table is served *with no cookie*, with the right
#     Content-Type and the Cache-Control D89 assigns it;
#   - the digest-bearing URLs match the digest the binary actually computed, so a
#     stale reference in the HTML is a failed check rather than a broken page;
#   - both HTML documents carry the CSP, nosniff and Referrer-Policy, and no
#     response head exceeds max_response_head_bytes;
#   - /favicon.ico is a 404 and not a 401;
#   - GET /app/account with no cookie is 401, and with one is 200 carrying a
#     synchroniser token (the bootstrap contract D90 rests on);
#   - GET /app/tags returns this account's tags, never another's, and reports
#     truncation;
#   - GET /app/stream answers immediately with a cursor under Accept:
#     application/json, and opens a stream under Accept: text/event-stream (both
#     branches of D93's fallback, from outside);
#   - a write through /v1 appears in a subsequent /app/entries listing for its tag
#     (the server half of the conversion moment).
#
# The 60 seconds is a timed manual drill, written down (D94). A shell script cannot
# answer a stopwatch, so this script deliberately does not try.
#
# Usage: tools/dashboard-check.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1" >&2
  [ -n "${2:-}" ] && printf '        %s\n' "$2" >&2
  return 0
}
hdr() { printf '\n=== %s ===\n' "$1"; }

equals() { # label expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}
contains() { # label needle haystack
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "'$2' not in: $3" ;; esac
}
lacks() { # label needle haystack
  case "$3" in *"$2"*) fail "$1" "'$2' unexpectedly in: $3" ;; *) pass "$1" ;; esac
}

WORK="$(mktemp -d /tmp/doot_dashcheck.XXXXXX)"
LOG="$WORK/harness.log"
COOKIES="$WORK/cookies"
HPID=""

cleanup() {
  [ -n "$HPID" ] && kill "$HPID" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

zig build >/dev/null 2>&1 || { echo "build failed" >&2; exit 1; }

# stderr, because that is where the harness announces itself and its mail.
./zig-out/bin/app 127.0.0.1:0 "$WORK/data" >"$LOG" 2>&1 &
HPID=$!

PORT=""
for _ in $(seq 1 100); do
  PORT="$(grep -oE '^LISTENING [0-9]+' "$LOG" 2>/dev/null | head -1 | cut -d' ' -f2)"
  [ -n "$PORT" ] && break
  kill -0 "$HPID" 2>/dev/null || { echo "harness died:"; cat "$LOG"; exit 1; }
  sleep 0.1
done
[ -n "$PORT" ] || { echo "harness never listened:"; cat "$LOG"; exit 1; }
BASE="http://127.0.0.1:$PORT"

CLIENT_IP="203.0.113.1"
status() { curl -sS -o /dev/null -w '%{http_code}' -H "CF-Connecting-IP: $CLIENT_IP" "$@"; }
body() { curl -sS -H "CF-Connecting-IP: $CLIENT_IP" "$@"; }
headers() { curl -sS -D- -o /dev/null -H "CF-Connecting-IP: $CLIENT_IP" "$@"; }
json_field() { grep -o "\"$1\":\"[^\"]*\"" | head -1 | cut -d'"' -f4; }

# Waits for the harness to print a code for an address (same shape as app-check.sh).
mail_count() { grep -cE "^MAIL $1 " "$LOG" 2>/dev/null | head -1; }
otp_for() { # address
  for _ in $(seq 1 100); do
    if [ "$(mail_count "$1")" -gt 0 ]; then
      grep -E "^MAIL $1 " "$LOG" | tail -1 | awk '{print $3}'
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# ---------------------------------------------------------------------------
hdr "the document plane serves with no cookie (D88)"
# ---------------------------------------------------------------------------

equals "the landing page is 200 with no cookie" 200 "$(status "$BASE/")"
contains "as HTML" "text/html" "$(headers "$BASE/" | grep -i '^content-type:')"
contains "and never cached" "no-store" "$(headers "$BASE/" | grep -i '^cache-control:')"

equals "the shell is 200 with no cookie" 200 "$(status "$BASE/app")"
contains "as HTML" "text/html" "$(headers "$BASE/app" | grep -i '^content-type:')"
contains "and never cached" "no-store" "$(headers "$BASE/app" | grep -i '^cache-control:')"

equals "robots.txt is 200" 200 "$(status "$BASE/robots.txt")"
contains "as text" "text/plain" "$(headers "$BASE/robots.txt" | grep -i '^content-type:')"
contains "and cached" "immutable" "$(headers "$BASE/robots.txt" | grep -i '^cache-control:')"

equals "the icon is 200" 200 "$(status "$BASE/favicon.svg")"
contains "as SVG" "image/svg+xml" "$(headers "$BASE/favicon.svg" | grep -i '^content-type:')"
contains "and cached" "immutable" "$(headers "$BASE/favicon.svg" | grep -i '^cache-control:')"

# The one path a browser fetches unprompted must answer in this plane's shape: a 404,
# not the data plane's 401 (D89).
equals "/favicon.ico is 404, not 401" 404 "$(status "$BASE/favicon.ico")"

# A stale digest is unreachable after a deploy, which is what makes caching without
# revalidation safe (D89).
equals "a stale asset URL is 404" 404 "$(status "$BASE/app.000000000000.css")"

# ---------------------------------------------------------------------------
hdr "the digest in the HTML is the digest the binary serves (D89)"
# ---------------------------------------------------------------------------

SHELL="$(body "$BASE/app")"
CSS_URL="$(printf '%s' "$SHELL" | grep -o '/app\.[0-9a-f]*\.css' | head -1)"
JS_URL="$(printf '%s' "$SHELL" | grep -o '/app\.[0-9a-f]*\.js' | head -1)"
[ -n "$CSS_URL" ] && pass "the shell references a digest-bearing stylesheet" ||
  fail "the shell references a digest-bearing stylesheet" "$SHELL"
[ -n "$JS_URL" ] && pass "the shell references a digest-bearing script" ||
  fail "the shell references a digest-bearing script" "$SHELL"

if [ -n "$CSS_URL" ] && [ -n "$JS_URL" ]; then
  equals "the referenced stylesheet is served" 200 "$(status "$BASE$CSS_URL")"
  equals "the referenced script is served" 200 "$(status "$BASE$JS_URL")"
  contains "the stylesheet is immutable" "immutable" "$(headers "$BASE$CSS_URL" | grep -i '^cache-control:')"
  contains "the script is immutable" "immutable" "$(headers "$BASE$JS_URL" | grep -i '^cache-control:')"
  contains "the stylesheet is CSS" "text/css" "$(headers "$BASE$CSS_URL" | grep -i '^content-type:')"
  contains "the script is JavaScript" "javascript" "$(headers "$BASE$JS_URL" | grep -i '^content-type:')"
  lacks "no unsubstituted digest token survives" "@@DOOT_DIGEST@@" "$SHELL"
fi

LANDING="$(body "$BASE/")"
contains "the landing page references the same stylesheet" "$CSS_URL" "$LANDING"
contains "and the same script" "$JS_URL" "$LANDING"

# ---------------------------------------------------------------------------
hdr "both HTML documents carry the security headers (D89)"
# ---------------------------------------------------------------------------

for path in / /app; do
  H="$(headers "$BASE$path")"
  contains "$path carries a CSP" "Content-Security-Policy:" "$H"
  contains "$path forbids inline" "'none'" "$H"
  lacks "$path has no unsafe-inline" "unsafe-inline" "$H"
  contains "$path carries nosniff" "nosniff" "$H"
  contains "$path carries Referrer-Policy" "no-referrer" "$H"
  # No response head may exceed the transport's ceiling.
  SIZE="$(printf '%s' "$H" | head -40 | wc -c | tr -d ' ')"
  if [ "$SIZE" -lt 2048 ]; then
    pass "$path response head is under the 2 KiB ceiling (${SIZE}B)"
  else
    fail "$path response head is under the 2 KiB ceiling" "${SIZE}B"
  fi
done

equals "a write to the shell is 405, not 404" 405 \
  "$(status -X POST "$BASE/app" --data '')"
contains "and says GET is allowed" "GET" \
  "$(headers -X POST "$BASE/app" --data '' | grep -i '^allow:')"

# ---------------------------------------------------------------------------
hdr "the bootstrap contract: GET /app/account (D90)"
# ---------------------------------------------------------------------------

equals "with no cookie the bootstrap is 401" 401 "$(status "$BASE/app/account")"

USER="dash@example.com"
PW="correct horse battery staple"
CLIENT_IP="203.0.113.2"
status -X POST "$BASE/app/auth/signup" --data-urlencode "email=$USER" --data-urlencode "password=$PW" >/dev/null
CODE="$(otp_for "$USER")" || fail "a verification code was queued" "none printed"
VERIFY_BODY="$(curl -sS -c "$COOKIES" -X POST "$BASE/app/auth/verify" \
  --data-urlencode "email=$USER" --data-urlencode "code=$CODE")"
SYNC="$(printf '%s' "$VERIFY_BODY" | json_field synchroniser)"

ACCOUNT="$(body -b "$COOKIES" "$BASE/app/account")"
equals "with a session the bootstrap is 200" 200 "$(status -b "$COOKIES" "$BASE/app/account")"
contains "and carries the account id" "acct_" "$ACCOUNT"
contains "and the credit balance" "credits" "$ACCOUNT"
contains "and the plan limits" "rate_limit" "$ACCOUNT"
contains "and a synchroniser token" "synchroniser" "$ACCOUNT"

# ---------------------------------------------------------------------------
hdr "GET /app/tags names this account's tags and no other's (D92)"
# ---------------------------------------------------------------------------
CLIENT_IP="203.0.113.3"

# Empty before anything is written: an empty list, not an error.
TAGS_EMPTY="$(body -b "$COOKIES" "$BASE/app/tags")"
contains "with no writes the tag list is empty" '"tags":[]' "$TAGS_EMPTY"
contains "and not truncated" '"truncated":false' "$TAGS_EMPTY"

KEY="$(body -b "$COOKIES" -X POST "$BASE/app/keys" --data '' -H "X-Doot-Synchroniser: $SYNC" | json_field api_key)"
curl -sS -o /dev/null -H "Authorization: Bearer $KEY" -H 'X-Doot-Tags: ci,main' \
  -X PUT "$BASE/v1/entries/ci/green" --data-binary 'ok' >/dev/null
curl -sS -o /dev/null -H "Authorization: Bearer $KEY" -H 'X-Doot-Tags: ci' \
  -X PUT "$BASE/v1/entries/ci/red" --data-binary 'bad' >/dev/null

TAGS="$(body -b "$COOKIES" "$BASE/app/tags")"
contains "a written tag is named" '"ci"' "$TAGS"
contains "and the second tag too" '"main"' "$TAGS"
contains "and truncation is reported" '"truncated":false' "$TAGS"

# A second account, so isolation is testable rather than assumed.
OTHER="stranger@example.com"
curl -sS -o /dev/null -H "CF-Connecting-IP: $CLIENT_IP" -X POST "$BASE/app/auth/signup" \
  --data-urlencode "email=$OTHER" --data-urlencode "password=$PW" >/dev/null
OTHER_CODE="$(otp_for "$OTHER")"
OTHER_BODY="$(curl -sS -H "CF-Connecting-IP: $CLIENT_IP" -c "$WORK/other_cookies" \
  -X POST "$BASE/app/auth/verify" --data-urlencode "email=$OTHER" --data-urlencode "code=$OTHER_CODE")"
OTHER_SYNC="$(printf '%s' "$OTHER_BODY" | json_field synchroniser)"
OTHER_KEY="$(body -b "$WORK/other_cookies" -X POST "$BASE/app/keys" --data '' \
  -H "X-Doot-Synchroniser: $OTHER_SYNC" | json_field api_key)"
curl -sS -o /dev/null -H "Authorization: Bearer $OTHER_KEY" -H 'X-Doot-Tags: theirs' \
  -X PUT "$BASE/v1/entries/theirs/secret" --data-binary 'x' >/dev/null

lacks "another account's tag never appears" "theirs" "$(body -b "$COOKIES" "$BASE/app/tags")"
contains "and the other account sees only its own" '"theirs"' \
  "$(body -b "$WORK/other_cookies" "$BASE/app/tags")"

equals "the tag list needs a session" 401 "$(status "$BASE/app/tags")"
equals "a write to the tag list is 405" 405 \
  "$(status -b "$COOKIES" -X POST "$BASE/app/tags" --data '')"

# ---------------------------------------------------------------------------
hdr "both live-view framings answer from outside (D93)"
# ---------------------------------------------------------------------------
CLIENT_IP="203.0.113.4"

POLL_ONE="$(body -b "$COOKIES" -H 'Accept: application/json' "$BASE/app/stream")"
contains "the same path answers JSON when JSON is asked for" '"events"' "$POLL_ONE"
contains "and carries a cursor to ask from next" '"cursor"' "$POLL_ONE"

STREAM_HEAD="$(curl -sS -D- -o /dev/null --max-time 3 -b "$COOKIES" \
  -H 'Accept: text/event-stream' "$BASE/app/stream" 2>/dev/null || true)"
contains "and opens a stream when SSE is asked for" "text/event-stream" "$STREAM_HEAD"

# ---------------------------------------------------------------------------
hdr "a /v1 write appears in the explorer listing (D94)"
# ---------------------------------------------------------------------------

contains "the entry is listed under its tag" "ci/green" \
  "$(body -b "$COOKIES" "$BASE/app/entries?tag=ci")"

# ---------------------------------------------------------------------------
hdr "summary"
# ---------------------------------------------------------------------------

if [ "$FAIL" -eq 0 ]; then
  printf '\nDASHBOARD CHECKS PASSED: %d passed, 0 failed\n' "$PASS"
  exit 0
fi
printf '\nDASHBOARD CHECKS FAILED: %d passed, %d failed\n' "$PASS" "$FAIL" >&2
exit 1
