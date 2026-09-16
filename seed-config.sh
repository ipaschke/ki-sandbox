#!/bin/bash
# Seed the sandbox's claude/codex config volumes from the host's ~/.claude and
# ~/.codex. Runs once per fresh volume (or on `sbx seed`). Copies portable
# config; skips hooks, plugins, statusline and MCP entries because they
# reference host-only paths and tools.
#   seed-config.sh <container-id> [cloud|local]
# cloud (default): also copies claude credentials and codex auth.json.
# local: no cloud credentials at all, auto mode disabled (the classifier needs
#        an Anthropic model), host "model" setting dropped (env pins the model).
set -euo pipefail
id="${1:?container id}"
profile="${2:-cloud}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---- claude ----
mkdir -p "$tmp/claude"
src="$HOME/.claude"
files=(CLAUDE.md keybindings.json)
[ "$profile" = cloud ] && files+=(.credentials.json)
for f in "${files[@]}"; do
    [ -f "$src/$f" ] && cp -p "$src/$f" "$tmp/claude/"
done
for d in agents commands skills; do
    [ -d "$src/$d" ] && cp -rp "$src/$d" "$tmp/claude/"
done
python3 - "$src/settings.json" "$tmp/claude/settings.json" "$profile" <<'PY'
import json, os, sys
src, out, profile = sys.argv[1:4]
d = json.load(open(src)) if os.path.isfile(src) else {}
for k in ("hooks", "enabledPlugins", "extraKnownMarketplaces", "statusLine"):
    d.pop(k, None)
if profile == "local":
    d.pop("model", None)
    d["disableAutoMode"] = "disable"
json.dump(d, open(out, "w"), indent=2)
PY
if [ -f "$HOME/.claude.json" ]; then
    python3 - "$HOME/.claude.json" "$tmp/claude/.claude.json" "$profile" <<'PY'
import json, sys
src, out, profile = sys.argv[1:4]
d = json.load(open(src))
keep = ["hasCompletedOnboarding", "lastOnboardingVersion", "userID", "theme", "installMethod", "autoUpdates"]
if profile == "cloud":
    keep.append("oauthAccount")
json.dump({k: d[k] for k in keep if k in d}, open(out, "w"), indent=2)
PY
fi
printf 'profile=%s\nseeded=%s\n' "$profile" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp/claude/.sbx-seeded"
tar -C "$tmp/claude" -cf - . | docker exec -i -u dev "$id" tar -xf - -C /home/dev/.claude
echo "seeded claude config ($profile): $(ls -A "$tmp/claude" | tr '\n' ' ')"

# ---- codex ----
if [ "$profile" = cloud ] && [ -f "$HOME/.codex/auth.json" ]; then
    mkdir -p "$tmp/codex"
    cp -p "$HOME/.codex/auth.json" "$tmp/codex/"
    tar -C "$tmp/codex" -cf - . | docker exec -i -u dev "$id" tar -xf - -C /home/dev/.codex
    echo "seeded codex auth"
fi
