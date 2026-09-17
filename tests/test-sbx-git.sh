#!/bin/bash
# Tests for sbx-git.py (host side) without docker: temp HOME/state, a repo with
# a bare origin, requests written by the container wrapper, terminal approval
# via stdin, validation rejections, the remote allowlist, execution outside the
# agent's repository (hooks and config never run), fetch import, the split
# pull, and the web UI over a random port including the changed-after-preview
# check.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SBXGIT="$HERE/../sbx-git.py"
WRAPPER="$HERE/../.devcontainer/git-wrapper.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null' EXIT
FAIL=0
ok()   { echo "ok: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

export HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_CONFIG_HOME="$T/config"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/sbx"
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
origin_head() { git -C "$T/origin.git" log -1 --format=%s main; }

# Write requests the way the container wrapper does (real git, request dir on host).
file_request() { # file_request <cwd> <git args...>
    local cwd="$1"; shift
    (cd "$cwd" && SBX_REAL_GIT=/usr/bin/git SBX_REQUEST_DIR="$reqdir" "$WRAPPER" "$@" >/dev/null 2>&1)
    ls -t "$reqdir"/*.req | head -1
}
review() { python3 "$SBXGIT" --project "$proj" </dev/null >/dev/null 2>&1; }   # terminal, skip everything
approve() { printf 'y\n' | python3 "$SBXGIT" --project "$proj" 2>&1; }

# 0. remote allowlist: without a matching entry even a local path remote is rejected
r0="$(file_request "$proj" push origin main)"; id0="$(basename "$r0" .req)"
review
[ -f "$reqdir/rejected/$id0.req" ] && grep -q 'not allowed' "$reqdir/rejected/$id0.result" && ok "local remote rejected without allowlist entry" || fail "allowlist default: $(ls -R "$reqdir" | head; cat "$reqdir"/rejected/*.result 2>/dev/null)"
printf '# test allowlist\n%s/\n' "$T" > "$XDG_CONFIG_HOME/sbx/remote-hosts"

# URL classification, checked directly against the module
cat > "$T/urls.py" <<PY
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sbxgit", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.REMOTE_HOSTS_FILE.write_text("github.com\n$T/\n")
cases = {
    "https://github.com/o/r.git": "", "git@github.com:o/r.git": "", "ssh://git@github.com/o/r.git": "",
    "https://api.github.com/x": "", "https://evil.example.com/o/r.git": "bad", "https://github.com.evil.example/o": "bad",
    "http://github.com/o/r.git": "bad", "git://github.com/o/r.git": "bad", "ext::sh -c evil": "bad",
    "$T/origin.git": "", "file://$T/origin.git": "", "/etc/repo.git": "bad", "../up.git": "bad",
}
bad = [u for u, want in cases.items() if bool(m.check_remote_url(u)) != (want == "bad")]
print("bad:", bad) if bad else print("ok")
PY
out="$(python3 "$T/urls.py" "$SBXGIT")"; [ "$out" = ok ] && ok "remote URL classification" || fail "remote URL classification: $out"

# 1. valid push, approved via terminal; a pre-push hook in the agent's repo must not run
mkdir -p "$proj/.git/hooks"
printf '#!/bin/sh\ntouch "%s"\nexit 0\n' "$T/hook-ran" > "$proj/.git/hooks/pre-push"; chmod +x "$proj/.git/hooks/pre-push"
r1="$(file_request "$proj" push origin main)"
out="$(approve)"; rc=$?
[ "$rc" = 0 ] && ok "terminal run exits 0" || fail "terminal rc=$rc: $out"
echo "$out" | grep -q "second" && ok "preview lists the pending commit" || fail "preview missing commit: $out"
echo "$out" | grep -q "origin.git" && ok "preview shows remote URL" || fail "preview missing remote url"
[ "$(origin_head)" = "second" ] && ok "push executed on host" || fail "push not executed: $out"
[ ! -e "$T/hook-ran" ] && ok "repository pre-push hook did not run on the host" || fail "pre-push hook ran on the host"
id1="$(basename "$r1" .req)"
[ -f "$reqdir/done/$id1.req" ] && [ -f "$reqdir/done/$id1.result" ] && ok "request moved to done/ with result" || fail "done files missing: $(ls -R "$reqdir")"
grep -q '^exit: 0$' "$reqdir/done/$id1.result" && ok "result records exit 0" || fail "result content: $(cat "$reqdir/done/$id1.result")"

# 2. declined via terminal -> rejected/
echo c > "$proj/a"; git -C "$proj" commit -qam "third"
r2="$(file_request "$proj" push origin main)"; id2="$(basename "$r2" .req)"
printf 'n\n' | python3 "$SBXGIT" --project "$proj" >/dev/null 2>&1
[ -f "$reqdir/rejected/$id2.req" ] && grep -qi 'declined' "$reqdir/rejected/$id2.result" && ok "declined request moved to rejected/" || fail "decline handling: $(ls -R "$reqdir")"
[ "$(origin_head)" = "second" ] && ok "declined push not executed" || fail "declined push executed"

# 3. validation rejections happen without asking
for args in "push --force origin main" "push -f origin main" "push origin +main" "push origin :main" "push --delete origin main" "push --mirror origin" "push https://example.com/x.git main" "push origin main --force-with-lease" "fetch --all" "fetch --multiple origin" "fetch --recurse-submodules origin"; do
    r="$(file_request "$proj" $args)"; id="$(basename "$r" .req)"
    review
    [ -f "$reqdir/rejected/$id.req" ] && ok "rejected: git $args" || fail "not rejected: git $args ($(ls "$reqdir"))"
done
[ "$(origin_head)" = "second" ] && ok "no rejected request reached the remote" || fail "remote changed by rejected request"

# 3b. remote host outside the allowlist is rejected, not just flagged
git -C "$proj" remote add evil https://evil.example.com/o/r.git
r="$(file_request "$proj" push evil main)"; id="$(basename "$r" .req)"
review
[ -f "$reqdir/rejected/$id.req" ] && grep -q "not allowed" "$reqdir/rejected/$id.result" && ok "disallowed remote host rejected" || fail "disallowed host: $(ls -R "$reqdir" | head)"
git -C "$proj" remote remove evil

# 3c. repositories that borrow objects from elsewhere are refused
echo "$T/origin.git/objects" > "$proj/.git/objects/info/alternates"
r="$(file_request "$proj" push origin main)"; id="$(basename "$r" .req)"
review
[ -f "$reqdir/rejected/$id.req" ] && grep -q "alternates" "$reqdir/rejected/$id.result" && ok "objects/info/alternates rejected" || fail "alternates: $(ls -R "$reqdir" | head)"
rm "$proj/.git/objects/info/alternates"

# 4. cwd outside project -> rejected
mkdir -p "$T/elsewhere"; git init -q "$T/elsewhere"; git -C "$T/elsewhere" remote add origin "$T/origin.git"
r="$(file_request "$T/elsewhere" push origin main)"; id="$(basename "$r" .req)"
review
[ -f "$reqdir/rejected/$id.req" ] && grep -qi 'outside' "$reqdir/rejected/$id.result" && ok "cwd outside project rejected" || fail "outside cwd: $(ls -R "$reqdir" | head -20)"

# 5. fetch approved: results land in the agent's repository, repo config never executes
git clone -q -b main "$T/origin.git" "$T/other"; echo d > "$T/other/d"; git -C "$T/other" add d; git -C "$T/other" commit -qm "fourth"; git -C "$T/other" push -q origin main
printf '#!/bin/sh\ntouch "%s"\necho "ignored"\n' "$T/fsmon-ran" > "$T/fsmon.sh"; chmod +x "$T/fsmon.sh"
git -C "$proj" config core.fsmonitor "$T/fsmon.sh"
git -C "$proj" config core.sshCommand "$T/fsmon.sh"
r="$(file_request "$proj" fetch origin)"; id="$(basename "$r" .req)"
out="$(approve)"
grep -q '^exit: 0$' "$reqdir/done/$id.result" 2>/dev/null && ok "fetch executed" || fail "fetch: $out $(ls -R "$reqdir" | head)"
[ "$(git -C "$proj" rev-parse origin/main)" = "$(git -C "$T/origin.git" rev-parse main)" ] && ok "fetch updated origin/main in the agent repo" || fail "origin/main not updated: $out"
[ -f "$proj/.git/FETCH_HEAD" ] && grep -q "branch 'main' of" "$proj/.git/FETCH_HEAD" && ok "FETCH_HEAD written" || fail "FETCH_HEAD missing or unexpected: $(cat "$proj/.git/FETCH_HEAD" 2>&1)"
git -C "$proj" cat-file -e "$(git -C "$T/origin.git" rev-parse main)" 2>/dev/null && ok "fetched objects present in the agent repo" || fail "fetched objects missing"
[ ! -e "$T/fsmon-ran" ] && ok "core.fsmonitor from the agent repo did not run" || fail "fsmonitor script ran on the host"
git -C "$proj" config --unset core.fsmonitor; git -C "$proj" config --unset core.sshCommand

# 5b. pull: the host runs the fetch half only, the wrapper finishes it on the next pull
echo e > "$T/other/e"; git -C "$T/other" add e; git -C "$T/other" commit -qm "fifth"; git -C "$T/other" push -q origin main
git -C "$proj" reset -q --hard origin/main   # local main = fourth, origin = fifth
before="$(git -C "$proj" rev-parse HEAD)"
r="$(file_request "$proj" pull origin main)"; id="$(basename "$r" .req)"
out="$(approve)"
grep -q '^exit: 0$' "$reqdir/done/$id.result" 2>/dev/null && ok "pull fetch half executed" || fail "pull: $out"
[ -f "$reqdir/done/$id.merge" ] && ok "merge marker left for the container" || fail "merge marker missing: $(ls "$reqdir/done")"
[ "$(git -C "$proj" rev-parse HEAD)" = "$before" ] && ok "host did not merge into the work tree" || fail "host merged"
(cd "$proj" && SBX_REAL_GIT=/usr/bin/git SBX_REQUEST_DIR="$reqdir" "$WRAPPER" pull origin main >"$T/pull.out" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "second git pull in the container completes with exit 0" || fail "wrapper pull rc=$rc: $(cat "$T/pull.out")"
[ "$(git -C "$proj" rev-parse HEAD)" = "$(git -C "$T/origin.git" rev-parse main)" ] && ok "wrapper merged FETCH_HEAD" || fail "not merged: $(cat "$T/pull.out")"
[ ! -f "$reqdir/done/$id.merge" ] && [ -f "$reqdir/done/$id.merged" ] && ok "merge marker consumed" || fail "marker state: $(ls "$reqdir/done")"
[ -z "$(ls "$reqdir"/*.req 2>/dev/null)" ] && ok "no new request filed by the completing pull" || fail "request filed: $(ls "$reqdir")"

# 6. nothing pending
out="$(python3 "$SBXGIT" --project "$proj" </dev/null 2>&1)"; echo "$out" | grep -qi "no pending" && ok "empty queue message" || fail "empty queue: $out"

# 7. web UI
port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 "$SBXGIT" --serve --port "$port" >"$T/web.log" 2>&1 & SRV_PID=$!
for i in $(seq 1 30); do curl -fs "http://127.0.0.1:$port/" >/dev/null 2>&1 && break; sleep 0.2; done
form_field() { echo "$1" | grep -o "name=\"$2\" value=\"[^\"]*\"" | head -1 | sed 's/.*value="//;s/"$//'; }
echo f > "$proj/a"; git -C "$proj" commit -qam "sixth"
r="$(file_request "$proj" push origin main)"; id="$(basename "$r" .req)"
page="$(curl -fs "http://127.0.0.1:$port/")"; echo "$page" | grep -q "$id" && ok "web list shows request" || fail "web list: $(echo "$page" | head -5)"
detail="$(curl -fs "http://127.0.0.1:$port/r/$id")"
echo "$detail" | grep -q "sixth" && ok "web detail shows commit preview" || fail "web detail: $(echo "$detail" | head -20)"
token="$(form_field "$detail" token)"; fp="$(form_field "$detail" fp)"
[ -n "$token" ] && ok "page carries a token" || fail "no token in page"
[ -n "$fp" ] && ok "page carries a fingerprint" || fail "no fingerprint in page"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "token=wrong&fp=$fp" "http://127.0.0.1:$port/r/$id/approve")
[ "$code" = 403 ] && ok "approve without valid token -> 403" || fail "wrong token gave $code"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/r/$id/approve")
[ "$code" = 405 ] || [ "$code" = 403 ] && ok "GET approve refused" || fail "GET approve gave $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: http://evil.example" -d "token=$token&fp=$fp" "http://127.0.0.1:$port/r/$id/approve")
[ "$code" = 403 ] && ok "foreign Origin -> 403" || fail "foreign origin gave $code"

# 7b. changed after preview: remote URL swapped to another allowed target -> refused, stays pending
git init -q --bare "$T/origin2.git"
git -C "$proj" remote set-url origin "$T/origin2.git"
code=$(curl -s -o "$T/toctou.html" -w '%{http_code}' -X POST -d "token=$token&fp=$fp" "http://127.0.0.1:$port/r/$id/approve")
[ "$code" = 409 ] && grep -q "changed after" "$T/toctou.html" && ok "URL changed after preview -> 409" || fail "url swap gave $code: $(head -c 300 "$T/toctou.html")"
[ -z "$(git -C "$T/origin2.git" rev-parse -q --verify main 2>/dev/null)" ] && ok "nothing pushed to the swapped remote" || fail "pushed to swapped remote"
[ -f "$reqdir/$id.req" ] && ok "request still pending after refusal" || fail "request consumed by refusal"
git -C "$proj" remote set-url origin "$T/origin.git"
# 7c. changed after preview: a new commit on the pushed branch -> refused as well
detail="$(curl -fs "http://127.0.0.1:$port/r/$id")"; token="$(form_field "$detail" token)"; fp="$(form_field "$detail" fp)"
echo g > "$proj/a"; git -C "$proj" commit -qam "seventh"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "token=$token&fp=$fp" "http://127.0.0.1:$port/r/$id/approve")
[ "$code" = 409 ] && ok "new commit after preview -> 409" || fail "commit after preview gave $code"
[ "$(origin_head)" = "fifth" ] && ok "remote unchanged after refused attempts" || fail "remote changed by refused web attempts"

# 7d. fresh preview, then approve
detail="$(curl -fs "http://127.0.0.1:$port/r/$id")"; token="$(form_field "$detail" token)"; fp="$(form_field "$detail" fp)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "token=$token&fp=$fp" "http://127.0.0.1:$port/r/$id/approve")
[ "$code" = 200 ] || [ "$code" = 303 ] && ok "approve with token and fingerprint accepted ($code)" || fail "approve gave $code"
[ "$(origin_head)" = "seventh" ] && ok "web approval executed the push" || fail "web push not executed"
[ -f "$reqdir/done/$id.result" ] && ok "web approval wrote result" || fail "web result missing"
[ ! -e "$T/hook-ran" ] && ok "pre-push hook still never ran" || fail "pre-push hook ran via web approval"
r="$(file_request "$proj" fetch origin)"; id="$(basename "$r" .req)"
detail="$(curl -fs "http://127.0.0.1:$port/r/$id")"; token="$(form_field "$detail" token)"; fp="$(form_field "$detail" fp)"
curl -s -o /dev/null -X POST -d "token=$token&fp=$fp" "http://127.0.0.1:$port/r/$id/reject"
[ -f "$reqdir/rejected/$id.req" ] && ok "web reject moves to rejected/" || fail "web reject"
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""

[ "$FAIL" = 0 ] && echo "test-sbx-git: ok"
exit "$FAIL"
