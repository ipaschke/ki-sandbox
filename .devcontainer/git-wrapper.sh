#!/bin/bash
# git wrapper for the agent sandbox, installed as /usr/local/bin/git (first on
# PATH). Every command is forwarded to the real git except push, fetch and
# pull: those become approval requests that the developer reviews and runs on
# the host with the host's credentials (see README, "Git: remote operations").
#
# For pull the host runs only the fetch half and leaves done/<id>.merge behind.
# The next `git pull` in the same directory finds it and runs the merge or
# rebase half here, with the real git and the recorded options.
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

if [ ! -d "$REQ_DIR" ]; then
    fail "git $sub was not run: remote operations need developer approval on the host," \
         "but the request directory $REQ_DIR does not exist (container not started via sbx-*?)." \
         "Ask the developer to run 'git $sub' on the host, or 'sbx-git' after restarting the sandbox."
fi
if [ ! -w "$REQ_DIR" ]; then
    fail "git $sub was not run: remote operations need developer approval on the host," \
         "but the request directory $REQ_DIR is not writable from here. Inside Claude's Bash sandbox" \
         "this means the managed settings lack $REQ_DIR in sandbox.filesystem.allowWrite" \
         "(sync-vorgaben.sh adds it; then sbx-rebuild). Ask the developer to run 'git $sub' on the host."
fi
for a in "${rest[@]}"; do
    case "$a" in *$'\n'*) fail "git $sub was not run: argument contains a newline." ;; esac
done

cwd="$(realpath -m "$cwd" 2>/dev/null || printf '%s' "$cwd")"

# The merge or rebase half of a pull whose fetch half the host has completed.
finish_pull() {
    local mode="" ff="" a cfg branch i=0 n=$#
    local -a all=("$@") opts=()
    while [ "$i" -lt "$n" ]; do
        a="${all[$i]}"
        case "$a" in
            --rebase|--rebase=*|-r) mode=rebase ;;
            --no-rebase) mode=merge ;;
            --ff|--no-ff|--ff-only) ff="$a" ;;
            -s|-X|--strategy|--strategy-option)          # option with a separate value
                opts+=("$a" "${all[$((i + 1))]:-}"); i=$((i + 1)) ;;
            --tags|--no-tags|--prune|--no-prune|--depth=*|--deepen=*|--unshallow|--update-shallow|--progress|--no-progress|-4|-6|--ipv4|--ipv6|-f|--force|--dry-run|--set-upstream|--jobs=*|-j*|--refmap=*|--negotiation-tip=*|--server-option=*|-o*|--recurse-submodules*|--no-recurse-submodules|--filter=*|--append|-a|--keep|-k|--update-head-ok|-u)
                ;;                                       # fetch half, done on the host
            -*) opts+=("$a") ;;
            *) ;;                                        # remote and refspecs: fetch half
        esac
        i=$((i + 1))
    done
    if [ -z "$mode" ]; then
        branch="$("$REAL_GIT" symbolic-ref -q --short HEAD 2>/dev/null || true)"
        cfg=""
        [ -n "$branch" ] && cfg="$("$REAL_GIT" config --get "branch.$branch.rebase" 2>/dev/null || true)"
        [ -n "$cfg" ] || cfg="$("$REAL_GIT" config --get pull.rebase 2>/dev/null || true)"
        case "$cfg" in true|merges|interactive|preserve) mode=rebase ;; *) mode=merge ;; esac
    fi
    if [ "$mode" = merge ]; then
        if [ -z "$ff" ]; then
            case "$("$REAL_GIT" config --get pull.ff 2>/dev/null || true)" in
                only) ff=--ff-only ;; false) ff=--no-ff ;; true) ff=--ff ;;
            esac
        fi
        [ -n "$ff" ] && opts+=("$ff")
    fi
    "$REAL_GIT" rev-parse -q --verify FETCH_HEAD >/dev/null 2>&1 \
        || fail "git pull: the host reports a completed fetch but FETCH_HEAD is missing; run 'git fetch' again."
    if [ "$mode" = rebase ]; then
        exec "$REAL_GIT" rebase ${opts[@]+"${opts[@]}"} FETCH_HEAD
    fi
    exec "$REAL_GIT" merge ${opts[@]+"${opts[@]}"} FETCH_HEAD
}

if [ "$sub" = pull ]; then
    marker=""
    for m in "$REQ_DIR"/done/*.merge; do
        [ -f "$m" ] || continue
        [ "$(sed -n 's/^cwd: //p' "$m" | head -1)" = "$cwd" ] && marker="$m"   # newest wins (sorted by id)
    done
    if [ -n "$marker" ]; then
        mv "$marker" "${marker%.merge}.merged" 2>/dev/null || true
        cd "$cwd" 2>/dev/null || fail "git pull: cannot enter $cwd"
        finish_pull ${rest[@]+"${rest[@]}"}
    fi
fi
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
sbx: Do not retry before it is approved; tell the developer the request is waiting.
EOF
if [ "$sub" = pull ]; then
    cat >&2 <<EOF
sbx: The host runs only the fetch half of a pull. Once done/$id.result reports exit 0, run the
sbx: same 'git pull' again in this directory: the wrapper then merges or rebases FETCH_HEAD locally.
EOF
fi
exit 1
