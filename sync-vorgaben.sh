#!/bin/bash
# Copies the Claude Code requirements of the KI-Leitfaden into the image
# sources. Source: konfiguration/claude-code/ of the ki-leitfaden checkout.
# Target: .devcontainer/vorgaben/, baked into /etc/claude-code/ by the
# Dockerfile as managed settings, managed CLAUDE.md and hook. Commit the result.
#
#   sync-vorgaben.sh [path-to-ki-leitfaden]      default: $SBX_LEITFADEN_DIR or ~/ki-leitfaden
#
# Transformation of settings.json -> managed-settings.json:
#   - entries containing placeholders (<<...>>) are dropped and listed
#   - allowedMcpServers becomes an empty list (blocks every server)
#   - the hook path becomes /etc/claude-code/hooks/pre-tool-secrets.sh
#   - the sandbox block is kept as is; the container's seccomp profile
#     (.devcontainer/seccomp.json) lets bubblewrap run with a fresh /proc, so
#     enableWeakerNestedSandbox is not needed and not set
# CLAUDE.md.vorlage -> CLAUDE.md without the "Projektspezifisches" section,
# which belongs into each project's own CLAUDE.md.
set -euo pipefail

SANDBOX_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")")" && pwd -P)"
SRC="${1:-${SBX_LEITFADEN_DIR:-$HOME/ki-leitfaden}}"
OUT="${SBX_VORGABEN_OUT:-$SANDBOX_DIR/.devcontainer/vorgaben}"
CC="$SRC/konfiguration/claude-code"

for f in settings.json hooks/pre-tool-secrets.sh CLAUDE.md.vorlage; do
    if [ ! -f "$CC/$f" ]; then
        echo "sync-vorgaben: $CC/$f not found. Pass the path of the ki-leitfaden checkout" >&2
        echo "               (expects konfiguration/claude-code/ inside it)." >&2
        exit 1
    fi
done

commit="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git -C "$SRC" status --porcelain -- konfiguration/claude-code 2>/dev/null)" ]; then
    commit="$commit+local-changes"
fi
datum="$(date -u +%Y-%m-%d)"

mkdir -p "$OUT/hooks"

python3 - "$CC/settings.json" "$OUT/managed-settings.json" <<'PY'
import json, re, sys
src, out = sys.argv[1:3]
d = json.load(open(src, encoding="utf-8"))
PH = re.compile(r"<<[A-ZÄÖÜ0-9-]+>>")
removed = []

def clean(items, where):
    kept = []
    for x in items:
        s = json.dumps(x, ensure_ascii=False)
        (removed.append(f"{where}: {s}") if PH.search(s) else kept.append(x))
    return kept

perm = d.setdefault("permissions", {})
for k in ("deny", "ask", "allow"):
    if k in perm:
        perm[k] = clean(perm[k], f"permissions.{k}")
sb = d.setdefault("sandbox", {})
net = sb.get("network", {})
if "allowedDomains" in net:
    net["allowedDomains"] = clean(net["allowedDomains"], "sandbox.network.allowedDomains")
if "allowedMcpServers" in d:
    d["allowedMcpServers"] = clean(d["allowedMcpServers"], "allowedMcpServers")
for entries in d.get("hooks", {}).values():
    for e in entries:
        for h in e.get("hooks", []):
            if "pre-tool-secrets.sh" in h.get("command", ""):
                h["command"] = "/etc/claude-code/hooks/pre-tool-secrets.sh"
d.pop("$schema", None)
left = PH.findall(json.dumps(d, ensure_ascii=False))
if left:
    sys.exit(f"sync-vorgaben: placeholders left in settings: {sorted(set(left))}")
with open(out, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write("\n")
for r in removed:
    print(f"sync-vorgaben: removed placeholder entry {r}")
PY

cp -p "$CC/hooks/pre-tool-secrets.sh" "$OUT/hooks/pre-tool-secrets.sh"
chmod 755 "$OUT/hooks/pre-tool-secrets.sh"

{
    printf '<!-- Verwaltete Verhaltensregeln der Agent-Sandbox. Quelle: ki-leitfaden@%s,\n' "$commit"
    printf '     konfiguration/claude-code/CLAUDE.md.vorlage, übernommen am %s durch sync-vorgaben.sh.\n' "$datum"
    printf '     Nicht von Hand bearbeiten; Änderungen in konfiguration/gemeinsam/verhaltensregeln.md. -->\n\n'
    # Drop "## Projektspezifisches" up to the next second-level heading.
    awk '/^## Projektspezifisches/ {skip=1; next} /^## / {skip=0} !skip' "$CC/CLAUDE.md.vorlage"
} > "$OUT/CLAUDE.md"

{
    printf 'quelle: ki-leitfaden (konfiguration/claude-code)\n'
    printf 'commit: %s\n' "$commit"
    printf 'datum: %s\n' "$datum"
    printf 'pfad: %s\n' "$SRC"
} > "$OUT/VERSION"

echo "sync-vorgaben: wrote $OUT (ki-leitfaden@$commit). Rebuild the image with sbx-rebuild and commit the result."
