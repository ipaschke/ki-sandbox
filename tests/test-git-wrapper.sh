#!/bin/bash
# Tests for .devcontainer/git-wrapper.sh without docker.
# Uses SBX_REAL_GIT (stub that logs its argv) and SBX_REQUEST_DIR (temp dir).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="$HERE/../.devcontainer/git-wrapper.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAIL=0
ok()   { echo "ok: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# Stub for the real git: log argv, exit 0. "rev-parse" answers are needed by
# the wrapper when it records branch and head.
cat > "$T/git-stub" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$STUB_LOG"
case "$1" in
  rev-parse) [ "$2" = "--abbrev-ref" ] && echo "feature" || echo "0123456789abcdef0123456789abcdef01234567";;
esac
exit 0
EOF
chmod +x "$T/git-stub"
export SBX_REAL_GIT="$T/git-stub" STUB_LOG="$T/stub.log"
export SBX_REQUEST_DIR="$T/requests"; mkdir -p "$SBX_REQUEST_DIR"
export SBX_WEB_URL="http://127.0.0.1:7331"

run() { : > "$STUB_LOG"; "$WRAPPER" "$@" >"$T/out" 2>"$T/err"; echo $?; }

# 1. passthrough
rc=$(run status --short); [ "$rc" = 0 ] && [ "$(head -1 "$STUB_LOG")" = status ] && ok "status passes through" || fail "status passthrough (rc=$rc)"
rc=$(run --git-dir=/x/.git log -n 1); [ "$rc" = 0 ] && grep -qx log "$STUB_LOG" && ok "--git-dir=... log passes through" || fail "--git-dir passthrough"
rc=$(run -c core.pager=cat commit -m x); [ "$rc" = 0 ] && grep -qx commit "$STUB_LOG" && ok "-c k=v commit passes through" || fail "-c passthrough"
rc=$(run remote add evil https://example.com/x.git); [ "$rc" = 0 ] && ok "remote add passes through" || fail "remote add passthrough"
[ -z "$(ls "$SBX_REQUEST_DIR")" ] && ok "no request written for local commands" || fail "request written for local command"

# 2. intercepted commands
rc=$(run push origin feature)
[ "$rc" != 0 ] && ok "push exits non-zero" || fail "push exit code $rc"
[ ! -s "$STUB_LOG" ] || ! grep -qx push "$STUB_LOG" && ok "real git not called with push" || fail "real git called with push"
req=$(ls "$SBX_REQUEST_DIR"/*.req 2>/dev/null | head -1)
[ -n "$req" ] && ok "request file written" || fail "no request file"
grep -q '^op: push$' "$req" && grep -q '^arg: origin$' "$req" && grep -q '^arg: feature$' "$req" && ok "request has op and args" || fail "request content: $(cat "$req")"
grep -q '^branch: feature$' "$req" && grep -q '^head: 0123456789abcdef' "$req" && ok "request records branch and head" || fail "branch/head missing"
grep -q "^cwd: $PWD\$" "$req" && ok "request records cwd" || fail "cwd missing"
id="$(basename "$req" .req)"
grep -q "http://127.0.0.1:7331/r/$id" "$T/err" && ok "message contains web link with id" || fail "no web link in message: $(cat "$T/err")"
grep -qi "not run\|was not" "$T/err" && ok "message says push was not run" || fail "message wording"
grep -q "done/$id" "$T/err" && ok "message names result location" || fail "result location missing"

rc=$(run -C /some/repo fetch --all); req2=$(ls -t "$SBX_REQUEST_DIR"/*.req | head -1)
[ "$rc" != 0 ] && grep -q '^op: fetch$' "$req2" && grep -q '^arg: --all$' "$req2" && ok "-C dir fetch intercepted, -C skipped" || fail "-C fetch"
grep -q '^cwd: /some/repo$' "$req2" && ok "cwd follows -C" || fail "cwd with -C: $(grep cwd "$req2")"
rc=$(run pull); req3=$(ls -t "$SBX_REQUEST_DIR"/*.req | head -1)
[ "$rc" != 0 ] && grep -q '^op: pull$' "$req3" && ok "pull intercepted" || fail "pull"
[ "$(ls "$SBX_REQUEST_DIR"/*.req | wc -l)" = 3 ] && ok "three requests, unique ids" || fail "request count $(ls "$SBX_REQUEST_DIR")"

# 3. request dir missing: clear message, non-zero, no crash
export SBX_REQUEST_DIR="$T/missing"
rc=$(run push); [ "$rc" != 0 ] && grep -qi "sbx-git" "$T/err" && ok "missing request dir handled" || fail "missing dir: rc=$rc $(cat "$T/err")"

[ "$FAIL" = 0 ] && echo "test-git-wrapper: ok"
exit "$FAIL"
