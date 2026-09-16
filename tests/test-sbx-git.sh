#!/bin/bash
# Tests for sbx-git.py (host side) without docker: temp HOME/state, a repo with
# a bare origin, requests written by the container wrapper, terminal approval
# via stdin, validation rejections, and the web UI over a random port.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SBXGIT="$HERE/../sbx-git.py"
WRAPPER="$HERE/../.devcontainer/git-wrapper.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null' EXIT
FAIL=0
ok()   { echo "ok: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

export HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_CONFIG_HOME="$T/config"
mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x

# Repo with bare origin, one pushed commit and one local commit ahead.
git init -q --bare "$T/origin.git"
proj="$T/proj"; git init -q -b main "$proj"
git -C "$proj" remote add origin "$T/origin.git"
echo a > "$proj/a"; git -C "$proj" add a; git -C "$proj" commit -qm "first"
git -C "$proj" push -q origin main
echo b > "$proj/a"; git -C "$proj" commit -qam "second"

key="${proj//\//-}"
reqdir="$XDG_STATE_HOME/sbx/projects/$key/requests"; mkdir -p "$reqdir"
echo "$proj" > "$reqdir/../project"   # written by the sbx wrapper, outside the mounted dir

# Write requests the way the container wrapper does (real git, request dir on host).
file_request() { # file_request <cwd> <git args...>
    local cwd="$1"; shift
    (cd "$cwd" && SBX_REAL_GIT=/usr/bin/git SBX_REQUEST_DIR="$reqdir" "$WRAPPER" "$@" >/dev/null 2>&1)
    ls -t "$reqdir"/*.req | head -1
}

# 1. valid push, approved via terminal
r1="$(file_request "$proj" push origin main)"
out="$(printf 'y\n' | python3 "$SBXGIT" --project "$proj" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "terminal run exits 0" || fail "terminal rc=$rc: $out"
echo "$out" | grep -q "second" && ok "preview lists the pending commit" || fail "preview missing commit: $out"
echo "$out" | grep -q "origin.git" && ok "preview shows remote URL" || fail "preview missing remote url"
[ "$(git -C "$T/origin.git" log -1 --format=%s main)" = "second" ] && ok "push executed on host" || fail "push not executed"
id1="$(basename "$r1" .req)"
[ -f "$reqdir/done/$id1.req" ] && [ -f "$reqdir/done/$id1.result" ] && ok "request moved to done/ with result" || fail "done files missing: $(ls -R "$reqdir")"
grep -q '^exit: 0$' "$reqdir/done/$id1.result" && ok "result records exit 0" || fail "result content: $(cat "$reqdir/done/$id1.result")"

# 2. declined via terminal -> rejected/
echo c > "$proj/a"; git -C "$proj" commit -qam "third"
r2="$(file_request "$proj" push origin main)"; id2="$(basename "$r2" .req)"
printf 'n\n' | python3 "$SBXGIT" --project "$proj" >/dev/null 2>&1
[ -f "$reqdir/rejected/$id2.req" ] && grep -qi 'declined' "$reqdir/rejected/$id2.result" && ok "declined request moved to rejected/" || fail "decline handling: $(ls -R "$reqdir")"
[ "$(git -C "$T/origin.git" log -1 --format=%s main)" = "second" ] && ok "declined push not executed" || fail "declined push executed"

# 3. validation rejections happen without asking
for args in "push --force origin main" "push -f origin main" "push origin +main" "push origin :main" "push --delete origin main" "push --mirror origin" "push https://example.com/x.git main" "push origin main --force-with-lease"; do
    r="$(file_request "$proj" $args)"; id="$(basename "$r" .req)"
    python3 "$SBXGIT" --project "$proj" </dev/null >/dev/null 2>&1
    [ -f "$reqdir/rejected/$id.req" ] && ok "rejected: git $args" || fail "not rejected: git $args ($(ls "$reqdir"))"
done
[ "$(git -C "$T/origin.git" log -1 --format=%s main)" = "second" ] && ok "no rejected request reached the remote" || fail "remote changed by rejected request"

# 4. cwd outside project -> rejected
mkdir -p "$T/elsewhere"; git init -q "$T/elsewhere"; git -C "$T/elsewhere" remote add origin "$T/origin.git"
r="$(file_request "$T/elsewhere" push origin main)"; id="$(basename "$r" .req)"
python3 "$SBXGIT" --project "$proj" </dev/null >/dev/null 2>&1
[ -f "$reqdir/rejected/$id.req" ] && grep -qi 'outside' "$reqdir/rejected/$id.result" && ok "cwd outside project rejected" || fail "outside cwd: $(ls -R "$reqdir" | head -20)"

# 5. fetch approved
r="$(file_request "$proj" fetch origin)"; id="$(basename "$r" .req)"
printf 'y\n' | python3 "$SBXGIT" --project "$proj" >/dev/null 2>&1
grep -q '^exit: 0$' "$reqdir/done/$id.result" 2>/dev/null && ok "fetch executed" || fail "fetch: $(ls -R "$reqdir" | head)"

# 6. nothing pending
out="$(python3 "$SBXGIT" --project "$proj" </dev/null 2>&1)"; echo "$out" | grep -qi "no pending" && ok "empty queue message" || fail "empty queue: $out"

# 7. web UI
port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 "$SBXGIT" --serve --port "$port" >"$T/web.log" 2>&1 & SRV_PID=$!
for i in $(seq 1 30); do curl -fs "http://127.0.0.1:$port/" >/dev/null 2>&1 && break; sleep 0.2; done
r="$(file_request "$proj" push origin main)"; id="$(basename "$r" .req)"
page="$(curl -fs "http://127.0.0.1:$port/")"; echo "$page" | grep -q "$id" && ok "web list shows request" || fail "web list: $(echo "$page" | head -5)"
detail="$(curl -fs "http://127.0.0.1:$port/r/$id")"
echo "$detail" | grep -q "third" && ok "web detail shows commit preview" || fail "web detail: $(echo "$detail" | head -20)"
token="$(echo "$detail" | grep -o 'name="token" value="[^"]*"' | head -1 | sed 's/.*value="//;s/"$//')"
[ -n "$token" ] && ok "page carries a token" || fail "no token in page"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "token=wrong" "http://127.0.0.1:$port/r/$id/approve")
[ "$code" = 403 ] && ok "approve without valid token -> 403" || fail "wrong token gave $code"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/r/$id/approve")
[ "$code" = 405 ] || [ "$code" = 403 ] && ok "GET approve refused" || fail "GET approve gave $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: http://evil.example" -d "token=$token" "http://127.0.0.1:$port/r/$id/approve")
[ "$code" = 403 ] && ok "foreign Origin -> 403" || fail "foreign origin gave $code"
[ "$(git -C "$T/origin.git" log -1 --format=%s main)" = "second" ] && ok "remote unchanged after refused attempts" || fail "remote changed by refused web attempts"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "token=$token" "http://127.0.0.1:$port/r/$id/approve")
[ "$code" = 200 ] || [ "$code" = 303 ] && ok "approve with token accepted ($code)" || fail "approve gave $code"
[ "$(git -C "$T/origin.git" log -1 --format=%s main)" = "third" ] && ok "web approval executed the push" || fail "web push not executed"
[ -f "$reqdir/done/$id.result" ] && ok "web approval wrote result" || fail "web result missing"
r="$(file_request "$proj" fetch origin)"; id="$(basename "$r" .req)"
detail="$(curl -fs "http://127.0.0.1:$port/r/$id")"; token="$(echo "$detail" | grep -o 'name="token" value="[^"]*"' | head -1 | sed 's/.*value="//;s/"$//')"
curl -s -o /dev/null -X POST -d "token=$token" "http://127.0.0.1:$port/r/$id/reject"
[ -f "$reqdir/rejected/$id.req" ] && ok "web reject moves to rejected/" || fail "web reject"
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""

[ "$FAIL" = 0 ] && echo "test-sbx-git: ok"
exit "$FAIL"
