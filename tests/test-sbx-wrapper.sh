#!/bin/bash
# Tests for the sbx wrapper with stubbed docker/devcontainer: profile
# resolution (cloud/local), generated /etc/sbx dir, container env and volumes
# for the local profile, refusal without endpoint file, container separation.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SBX="$HERE/../sbx"
T="$(mktemp -d)"; trap 'rm -rf "$T"; rm -rf "$HERE/../.devcontainer/gen/"*/' EXIT
FAIL=0
ok()   { echo "ok: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
replace_in_file() { # replace_in_file <file> <old> <new>   (portable: no sed -i)
    python3 - "$@" <<'PY'
import sys
f, old, new = sys.argv[1:4]
s = open(f).read()
open(f, "w").write(s.replace(old, new))
PY
}

mkdir -p "$T/bin" "$T/home" "$T/proj" "$T/proj2"
cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$T/bin/devcontainer" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$SBX_TEST_LOG"; exit 0
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" HOME="$T/home" XDG_CONFIG_HOME="$T/config" XDG_STATE_HOME="$T/state" SBX_TEST_LOG="$T/dc.log" SBX_WEB=0
key="${T//\//-}-proj"
state="$XDG_STATE_HOME/sbx/projects/$key"
cfg="$XDG_CONFIG_HOME/sbx/projects/$key"
gen_config() { grep -A1 -- '^--config$' "$SBX_TEST_LOG" | tail -1; }
id_labels() { grep -A1 -- '^--id-label$' "$SBX_TEST_LOG" | grep -v -- '--id-label' | tr '\n' ' '; }

# 1. default: cloud profile, /etc/sbx generated and mounted read-only
"$SBX" shell "$T/proj" >/dev/null 2>&1
[ "$(cat "$state/etc-sbx/profile")" = cloud ] && ok "default profile is cloud" || fail "profile: $(cat "$state/etc-sbx/profile" 2>&1)"
c="$(gen_config)"; grep -q 'target=/etc/sbx,type=bind,readonly' "$c" && ok "/etc/sbx mounted read-only" || fail "etc-sbx mount missing in $c"
grep -q 'ANTHROPIC_BASE_URL' "$c" && fail "cloud profile must not set ANTHROPIC_BASE_URL" || ok "cloud profile leaves Claude env alone"
grep -q 'sandbox-claude-config-local' "$c" && fail "cloud profile must use the normal volumes" || ok "cloud profile uses normal volumes"
grep -qE 'source=sandbox-claude-config-[0-9a-f]{16},target=/home/dev/.claude' "$c" && ok "claude volume is per project" || fail "claude volume name: $(grep -o 'source=sandbox-claude[^,]*' "$c")"
grep -qE 'source=sandbox-codex-config-[0-9a-f]{16},' "$c" && grep -qE 'source=sandbox-bash-history-[0-9a-f]{16},' "$c" && ok "codex and history volumes are per project" || fail "codex/history volume names"
vol1="$(grep -oE 'source=sandbox-claude-config-[0-9a-f]{16}' "$c")"
"$SBX" shell "$T/proj2" >/dev/null 2>&1; c2="$(gen_config)"
vol2="$(grep -oE 'source=sandbox-claude-config-[0-9a-f]{16}' "$c2")"
[ -n "$vol1" ] && [ -n "$vol2" ] && [ "$vol1" != "$vol2" ] && ok "different projects get different volumes" || fail "volumes: $vol1 vs $vol2"
"$SBX" shell "$T/proj" >/dev/null 2>&1; c="$(gen_config)"
[ "$(grep -oE 'source=sandbox-claude-config-[0-9a-f]{16}' "$c")" = "$vol1" ] && ok "volume name is stable per project" || fail "volume name changed for the same project"
labels_cloud="$(id_labels)"

# 2. --local without endpoint file -> refused, names the file
"$SBX" shell --local "$T/proj" >/dev/null 2>"$T/err"; rc=$?
[ "$rc" != 0 ] && grep -q 'local-model.env' "$T/err" && ok "--local without endpoint file refused" || fail "missing env file: rc=$rc $(cat "$T/err")"

# 3. --local with endpoint file
mkdir -p "$XDG_CONFIG_HOME/sbx"
cat > "$XDG_CONFIG_HOME/sbx/local-model.env" <<'EOF'
# test endpoint
SBX_LOCAL_BASE_URL=https://inferenz.example.intern:8443
SBX_LOCAL_MODEL=qwen3-coder:32b
SBX_LOCAL_API_KEY=s3cret-local
SBX_LOCAL_CONTEXT_TOKENS=196608
EOF
"$SBX" shell --local "$T/proj" >/dev/null 2>"$T/err"
[ "$(cat "$state/etc-sbx/profile")" = local ] && ok "--local sets profile local" || fail "profile after --local: $(cat "$state/etc-sbx/profile" 2>&1) $(cat "$T/err")"
grep -q '^SBX_LOCAL_HOST=inferenz.example.intern$' "$state/etc-sbx/local-model.env" && ok "firewall gets the model host" || fail "local-model.env: $(cat "$state/etc-sbx/local-model.env" 2>&1)"
grep -q 's3cret-local' "$state/etc-sbx/local-model.env" && fail "API key must not be written into /etc/sbx" || ok "API key kept out of /etc/sbx"
c="$(gen_config)"
python3 - "$c" <<'PY' && ok "local container env and volumes" || fail "local gen config"
import json, sys
d = json.load(open(sys.argv[1]))
e = d["containerEnv"]
assert e["ANTHROPIC_BASE_URL"] == "https://inferenz.example.intern:8443", e
assert e["ANTHROPIC_AUTH_TOKEN"] == "s3cret-local"
for k in ("ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
          "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL", "ANTHROPIC_SMALL_FAST_MODEL"):
    assert e[k] == "qwen3-coder:32b", k
assert e["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1"
assert e["DISABLE_AUTOUPDATER"] == "1" and e["DISABLE_TELEMETRY"] == "1" and e["DISABLE_ERROR_REPORTING"] == "1"
assert e["ENABLE_CLAUDEAI_MCP_SERVERS"] == "false"
assert e["SBX_LOCAL_API_KEY"] == "s3cret-local" and e["SBX_PROFILE"] == "local"
assert e["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] == "196608"
m = d["mounts"]
import re
assert any(re.match(r"source=sandbox-claude-config-local-[0-9a-f]{16},target=/home/dev/.claude", x) for x in m), m
assert any(re.match(r"source=sandbox-codex-config-local-[0-9a-f]{16},target=/home/dev/.codex", x) for x in m), m
assert any(re.match(r"source=sandbox-bash-history-local-[0-9a-f]{16},", x) for x in m), m
assert not any(x.startswith("source=sandbox-claude-config,") or re.match(r"source=sandbox-claude-config-[0-9a-f]{16},", x) for x in m), m
PY
python3 - "$state/etc-sbx/codex/config.toml" <<'PY' && ok "codex config.toml for local provider" || fail "codex config"
import sys
try:
    import tomllib
except ImportError:          # Python < 3.11 (e.g. macOS system python): minimal parser for this flat file
    import re
    class tomllib:
        @staticmethod
        def load(fh):
            d, cur = {}, None
            for line in fh.read().decode().splitlines():
                line = line.split("#", 1)[0].strip()
                if not line: continue
                m = re.match(r"^\[([\w.]+)\]$", line)
                if m:
                    cur = d
                    for part in m.group(1).split("."): cur = cur.setdefault(part, {})
                    continue
                k, v = [x.strip() for x in line.split("=", 1)]
                k = k.strip('"')
                v = {"true": True, "false": False}.get(v, v.strip('"') if v.startswith('"') else (int(v) if v.isdigit() else v))
                (cur if cur is not None else d)[k] = v
            return d
d = tomllib.load(open(sys.argv[1], "rb"))
assert d["model_provider"] == "local" and d["model"] == "qwen3-coder:32b"
p = d["model_providers"]["local"]
assert p["base_url"] == "https://inferenz.example.intern:8443/v1" and p["env_key"] == "SBX_LOCAL_API_KEY" and p["wire_api"] == "responses"
assert d["approval_policy"] == "on-request" and d["sandbox_mode"] == "workspace-write" and d["web_search"] == "disabled"
assert d["check_for_update_on_startup"] is False and d["analytics"]["enabled"] is False and d["feedback"]["enabled"] is False
assert d["shell_environment_policy"]["filters"]["SBX_LOCAL_API_KEY"] == "exclude"
PY
labels_local="$(id_labels)"
[ "$labels_local" != "$labels_cloud" ] && ok "local and cloud get different containers" || fail "same id labels: $labels_local"

# 4. project marked local runs local without flag and cannot be forced to cloud
mkdir -p "$cfg"; echo local > "$cfg/profile"
"$SBX" shell "$T/proj" >/dev/null 2>&1
[ "$(cat "$state/etc-sbx/profile")" = local ] && ok "project profile file selects local" || fail "project profile ignored"
[ "$(id_labels)" = "$labels_local" ] && ok "same container as --local" || fail "labels differ for project-local"

# 5. endpoint change recreates: different labels
replace_in_file "$XDG_CONFIG_HOME/sbx/local-model.env" 'qwen3-coder:32b' 'other-model'
"$SBX" shell "$T/proj" >/dev/null 2>&1
[ "$(id_labels)" != "$labels_local" ] && ok "changed model gives new container" || fail "model change not in hash"

# 6. invalid profile value refused; invalid base url refused
echo weird > "$cfg/profile"; "$SBX" shell "$T/proj" >/dev/null 2>"$T/err"; rc=$?
[ "$rc" != 0 ] && grep -qi 'profile' "$T/err" && ok "unknown profile refused" || fail "unknown profile: rc=$rc"
echo local > "$cfg/profile"; replace_in_file "$XDG_CONFIG_HOME/sbx/local-model.env" 'SBX_LOCAL_BASE_URL=https://inferenz.example.intern:8443' 'SBX_LOCAL_BASE_URL=inferenz.example.intern'
"$SBX" shell "$T/proj" >/dev/null 2>"$T/err"; rc=$?
[ "$rc" != 0 ] && grep -qi 'BASE_URL' "$T/err" && ok "base url without scheme refused" || fail "bad base url: rc=$rc $(cat "$T/err")"

[ "$FAIL" = 0 ] && echo "test-sbx-wrapper: ok"
exit "$FAIL"
