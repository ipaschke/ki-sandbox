#!/bin/bash
# Seed the sandbox's claude/codex config volumes from the host's ~/.claude and
# ~/.codex. Runs once per fresh volume (or on `sbx seed`). Copies auth plus
# portable config; skips hooks, plugins, statusline and MCP entries because
# they reference host-only paths and tools.
#   seed-config.sh <container-id>
set -euo pipefail
id="${1:?container id}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---- claude ----
mkdir -p "$tmp/claude"
src="$HOME/.claude"
for f in .credentials.json CLAUDE.md keybindings.json; do
    [ -f "$src/$f" ] && cp -p "$src/$f" "$tmp/claude/"
done
for d in agents commands skills; do
    [ -d "$src/$d" ] && cp -rp "$src/$d" "$tmp/claude/"
done
if [ -f "$src/settings.json" ]; then
    python3 - "$src/settings.json" "$tmp/claude/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("hooks", "enabledPlugins", "extraKnownMarketplaces", "statusLine"):
    d.pop(k, None)
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
fi
if [ -f "$HOME/.claude.json" ]; then
    python3 - "$HOME/.claude.json" "$tmp/claude/.claude.json" <<'PY'
import json, sys
src = json.load(open(sys.argv[1]))
keep = ("hasCompletedOnboarding", "lastOnboardingVersion", "oauthAccount",
        "userID", "theme", "installMethod", "autoUpdates")
json.dump({k: src[k] for k in keep if k in src}, open(sys.argv[2], "w"), indent=2)
PY
fi
tar -C "$tmp/claude" -cf - . | docker exec -i -u dev "$id" tar -xf - -C /home/dev/.claude
echo "seeded claude config: $(ls -A "$tmp/claude" | tr '\n' ' ')"

# ---- codex ----
if [ -f "$HOME/.codex/auth.json" ]; then
    mkdir -p "$tmp/codex"
    cp -p "$HOME/.codex/auth.json" "$tmp/codex/"
    tar -C "$tmp/codex" -cf - . | docker exec -i -u dev "$id" tar -xf - -C /home/dev/.codex
    echo "seeded codex auth"
fi
