#!/bin/bash
# git wrapper for the agent sandbox, installed as /usr/local/bin/git (first on
# PATH). Every command is forwarded to the real git except push, fetch and
# pull: those become approval requests that the developer reviews and runs on
# the host with the host's credentials (see README, "Git: remote operations").
#
# Only the arguments after the subcommand are recorded; global options
# (-c key=value, --git-dir, ...) are dropped, -C only moves the working dir.
# The wrapper is convenience, not the security boundary: the container holds
# no credentials, so /usr/bin/git push fails on its own.
#
# Env (for tests): SBX_REAL_GIT, SBX_REQUEST_DIR, SBX_WEB_URL.
set -uo pipefail

REAL_GIT="${SBX_REAL_GIT:-/usr/bin/git}"
REQ_DIR="${SBX_REQUEST_DIR:-/run/sbx/requests}"
WEB_URL="${SBX_WEB_URL:-http://127.0.0.1:7331}"

# Locate the subcommand, skipping global options. -C moves the working dir.
cwd="$PWD"
sub=""
sub_index=-1
i=0
n=$#
args=("$@")
while [ "$i" -lt "$n" ]; do
    a="${args[$i]}"
    case "$a" in
        -C)
            i=$((i + 1))
            dir="${args[$i]:-}"
            case "$dir" in /*) cwd="$dir" ;; *) cwd="$cwd/$dir" ;; esac
            ;;
        -c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env|--list-cmds)
            i=$((i + 1)) ;;                 # option with a separate value
        --*=*|-*)
            ;;                              # flag or option=value
        *)
            sub="$a"; sub_index="$i"; break ;;
    esac
    i=$((i + 1))
done

case "$sub" in
    push|fetch|pull) ;;
    *) exec "$REAL_GIT" "$@" ;;
esac

rest=("${args[@]:$((sub_index + 1))}")

fail() { printf 'sbx: %s\n' "$@" >&2; exit 1; }

if [ ! -d "$REQ_DIR" ] || [ ! -w "$REQ_DIR" ]; then
    fail "git $sub was not run: remote operations need developer approval on the host," \
         "but the request directory $REQ_DIR is not available (container not started via sbx-*?)." \
         "Ask the developer to run 'git $sub' on the host, or 'sbx-git' after restarting the sandbox."
fi
for a in "${rest[@]}"; do
    case "$a" in *$'\n'*) fail "git $sub was not run: argument contains a newline." ;; esac
done

cwd="$(realpath -m "$cwd" 2>/dev/null || printf '%s' "$cwd")"
branch="$(cd "$cwd" 2>/dev/null && "$REAL_GIT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
head="$(cd "$cwd" 2>/dev/null && "$REAL_GIT" rev-parse HEAD 2>/dev/null || true)"

while :; do
    id="$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%04x%04x' "$RANDOM" "$RANDOM")"
    [ -e "$REQ_DIR/$id.req" ] || break
done
tmp="$REQ_DIR/.$id.tmp"
{
    printf 'sbx-request: 1\n'
    printf 'id: %s\n' "$id"
    printf 'op: %s\n' "$sub"
    printf 'cwd: %s\n' "$cwd"
    printf 'branch: %s\n' "${branch:-?}"
    printf 'head: %s\n' "${head:-?}"
    printf 'time: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for a in "${rest[@]}"; do printf 'arg: %s\n' "$a"; done
} > "$tmp" && mv "$tmp" "$REQ_DIR/$id.req" || fail "git $sub was not run: could not write request to $REQ_DIR."

cat >&2 <<EOF
sbx: git $sub was not run. Remote operations run only after the developer approves them on the host.
sbx: Request $id filed. Approve in the browser: $WEB_URL/r/$id  or on the host: sbx-git
sbx: The outcome will appear in $REQ_DIR/done/$id.result (or rejected/$id.result).
sbx: Do not retry; tell the developer the request is waiting.
EOF
exit 1
