#!/bin/bash
# Tests for sync-vorgaben.sh: runs the sync from the ki-leitfaden checkout into
# a temp dir and checks the transformed Claude Code files.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SYNC="$HERE/../sync-vorgaben.sh"
SRC="${SBX_LEITFADEN_DIR:-$HOME/ki-leitfaden}"
if [ ! -d "$SRC/konfiguration/claude-code" ]; then
    echo "test-sync-vorgaben: skipped (no ki-leitfaden checkout at $SRC)"; exit 0
fi
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAIL=0
ok()   { echo "ok: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

out="$(SBX_VORGABEN_OUT="$T/vorgaben" "$SYNC" "$SRC" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "sync exits 0" || fail "sync rc=$rc: $out"
V="$T/vorgaben"
for f in managed-settings.json CLAUDE.md hooks/pre-tool-secrets.sh VERSION; do
    [ -s "$V/$f" ] && ok "$f written" || fail "$f missing"
done
[ -x "$V/hooks/pre-tool-secrets.sh" ] && ok "hook executable" || fail "hook not executable"
cmp -s "$V/hooks/pre-tool-secrets.sh" "$SRC/konfiguration/claude-code/hooks/pre-tool-secrets.sh" && ok "hook copied verbatim" || fail "hook differs from source"

# managed-settings.json
python3 - "$V/managed-settings.json" <<'PY' && ok "managed-settings.json checks" || fail "managed-settings.json checks"
import json, sys, re
d = json.load(open(sys.argv[1]))
s = json.dumps(d)
assert "<<" not in s, "placeholder left: " + s
p = d["permissions"]
assert "Read(**/.env)" in p["deny"], "deny .env missing"
assert "Bash(git push --force*)" in p["deny"], "deny force push missing"
assert "Bash(git push *)" in p["ask"], "ask git push missing"
assert p["disableBypassPermissionsMode"] == "disable"
assert "disableAutoMode" not in d, "auto mode is allowed in the container (Leitfaden 3.5); host keeps disableAutoMode"
assert d["allowedMcpServers"] == [], "allowedMcpServers must be empty list: %r" % d.get("allowedMcpServers")
assert d["enableAllProjectMcpServers"] is False
assert d["remoteControlAtStartup"] is False
assert d["sandbox"]["enabled"] is True
assert d["sandbox"]["failIfUnavailable"] is True
assert not d["sandbox"].get("enableWeakerNestedSandbox"), "weaker nested sandbox must stay off (seccomp profile makes it unnecessary)"
assert "api.anthropic.com" in d["sandbox"]["network"]["allowedDomains"]
cmds = [h["command"] for ev in d["hooks"].values() for e in ev for h in e["hooks"]]
assert cmds and all(c == "/etc/claude-code/hooks/pre-tool-secrets.sh" for c in cmds), cmds
assert "$schema" not in d
PY
echo "$out" | grep -q "PROJEKT-TESTBEFEHL" && ok "sync reports removed placeholder entries" || fail "removed entries not reported: $out"

# CLAUDE.md
grep -q '^## Vertrauensgrenzen' "$V/CLAUDE.md" && ok "CLAUDE.md has Vertrauensgrenzen" || fail "CLAUDE.md content"
grep -q '^## Hinweise für Claude Code' "$V/CLAUDE.md" && ok "CLAUDE.md keeps agent-specific footer" || fail "footer missing"
grep -q 'Projektspezifisches' "$V/CLAUDE.md" && fail "Projektspezifisches section not removed" || ok "Projektspezifisches section removed"
grep -q '<<' "$V/CLAUDE.md" && { grep -v 'API-KEY' "$V/CLAUDE.md" | grep -q '<<' && fail "placeholder left in CLAUDE.md" || ok "only the API-KEY example placeholder remains"; } || ok "no placeholders in CLAUDE.md"
head -5 "$V/CLAUDE.md" | grep -q 'ki-leitfaden' && ok "CLAUDE.md header names the source" || fail "header: $(head -5 "$V/CLAUDE.md")"

# VERSION
grep -qE '^commit: [0-9a-f]{7,}' "$V/VERSION" && ok "VERSION has commit" || fail "VERSION: $(cat "$V/VERSION")"
grep -qE '^datum: 20[0-9]{2}-' "$V/VERSION" && ok "VERSION has date" || fail "VERSION date"

# missing source -> clear error
SBX_VORGABEN_OUT="$T/x" "$SYNC" "$T/nope" >/dev/null 2>"$T/err"; rc=$?
[ "$rc" != 0 ] && grep -q "konfiguration/claude-code" "$T/err" && ok "missing source reported" || fail "missing source: rc=$rc $(cat "$T/err")"

[ "$FAIL" = 0 ] && echo "test-sync-vorgaben: ok"
exit "$FAIL"
