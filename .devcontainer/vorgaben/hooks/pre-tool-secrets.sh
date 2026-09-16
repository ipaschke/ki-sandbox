#!/usr/bin/env bash
# Zweck   : PreToolUse-Hook für Claude Code. Blockiert Bash-Befehle, die Zugangsdaten
#           enthalten oder Secret-Dateien lesen, sowie Write/Edit auf Secret-Dateien
#           oder mit Zugangsdaten im Inhalt.
# Ablage  : .claude/hooks/pre-tool-secrets.sh, ausführbar (chmod +x).
#           Eingetragen in .claude/settings.json unter hooks.PreToolUse.
# Eingabe : JSON auf stdin (tool_name, tool_input.command bzw. tool_input.file_path, content).
# Exit    : 0 = erlauben, 2 = blockieren (Begründung auf stderr).
# Abhängigkeiten: nur bash, grep, sed. Kein jq, damit der Hook überall läuft.
# Geprüft : 2026-09-10 gegen https://code.claude.com/docs/en/hooks
set -uo pipefail

EINGABE="$(cat)"

tool_name="$(printf '%s' "$EINGABE" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"

blockiere() {
  echo "Blockiert durch pre-tool-secrets.sh: $1" >&2
  exit 2
}

# Muster für Zugangsdaten (Reihenfolge: Beschreibung|regex)
SECRET_MUSTER=(
  'AWS Access Key|AKIA[0-9A-Z]{16}'
  'GitHub Token|gh[pousr]_[A-Za-z0-9]{30,}'
  'GitHub Fine-grained Token|github_pat_[A-Za-z0-9_]{20,}'
  'OpenAI oder Anthropic API-Key|sk-[A-Za-z0-9_-]{20,}'
  'Slack Token|xox[baprs]-[A-Za-z0-9-]{10,}'
  'Google API-Key|AIza[0-9A-Za-z_-]{35}'
  'Privater Schlüssel|-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'Passwort oder Secret als Zuweisung|(password|passwd|secret|token|api[_-]?key)[a-z0-9_]*\\?["'"'"']?[[:space:]]*[:=][[:space:]]*\\?["'"'"'][^"'"'"'\\]{8,}'
)

pruefe_secrets() { # pruefe_secrets <text>
  local text="$1" eintrag beschr regex
  for eintrag in "${SECRET_MUSTER[@]}"; do
    beschr="${eintrag%%|*}"
    regex="${eintrag#*|}"
    if printf '%s' "$text" | grep -qiE -- "$regex"; then
      blockiere "$beschr erkannt. Zugangsdaten gehören in Umgebungsvariablen oder einen Secret-Store, nicht in Befehle oder Dateien."
    fi
  done
}

# Dateipfade, die weder gelesen noch geschrieben werden dürfen
SECRET_PFAD='(^|/)\.env(\.[A-Za-z0-9_-]+)?$|\.(pem|key|p12|pfx|jks|keystore)$|(^|/)id_(rsa|ed25519|ecdsa|dsa)(\.pub)?$|(^|/)\.(ssh|aws|kube|gnupg)/|(^|/)\.config/gh/|(^|/)\.netrc$|(^|/)\.npmrc$|(^|/)\.pypirc$|(^|/)\.codex/auth\.json$|(^|/)\.claude/settings\.local\.json$'
AUSNAHME_PFAD='(^|/)\.env\.(example|sample|template)$'
AUSNAHME_BEFEHL='\.env\.(example|sample|template)([[:space:];&|]|$)'

case "$tool_name" in
  Bash|PowerShell)
    befehl="$(printf '%s' "$EINGABE" | grep -oE '"command"[[:space:]]*:[[:space:]]*"(\\.|[^"\\])*"' | head -1 | sed -E 's/^"command"[[:space:]]*:[[:space:]]*"//; s/"$//')"
    pruefe_secrets "$befehl"
    # Lesen oder Einbinden von Secret-Dateien. Der Befehl wird an ;, &&, || und |
    # in Segmente zerlegt, damit ein erlaubtes Segment kein verbotenes deckt.
    LESE_MUSTER='(^|[[:space:];&|(])(cat|less|more|head|tail|source|\.|bat|type|Get-Content|strings|xxd|base64)[[:space:]]+([^;&|]*[[:space:]])?[^[:space:];&|]*(\.env([.][A-Za-z0-9_-]+)?|\.pem|\.key|\.p12|\.pfx|id_rsa|id_ed25519|\.ssh/|\.aws/|\.kube/|\.gnupg/|\.netrc|\.npmrc|\.pypirc)([[:space:];&|]|$)'
    while IFS= read -r segment; do
      [ -z "$segment" ] && continue
      if printf '%s' "$segment" | grep -qE "$LESE_MUSTER"; then
        if ! printf '%s' "$segment" | grep -qE "$AUSNAHME_BEFEHL"; then
          blockiere "Befehl liest eine Datei mit Zugangsdaten. Wenn ein Wert benötigt wird, frage die Person in der Sitzung."
        fi
      fi
    done < <(printf '%s\n' "$befehl" | sed -E 's/(&&|\|\||[;|])/\n/g')
    # Installationsskripte aus dem Netz
    if printf '%s' "$befehl" | grep -qE '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([[:space:]]|$)'; then
      blockiere "Skript aus dem Netz direkt in eine Shell geleitet. Herunterladen, prüfen, dann ausführen."
    fi
    ;;
  Write|Edit|MultiEdit|NotebookEdit)
    pfad="$(printf '%s' "$EINGABE" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"(\\.|[^"\\])*"' | head -1 | sed -E 's/^"file_path"[[:space:]]*:[[:space:]]*"//; s/"$//')"
    if printf '%s' "$pfad" | grep -qE "$SECRET_PFAD"; then
      if ! printf '%s' "$pfad" | grep -qE "$AUSNAHME_PFAD"; then
        blockiere "Schreiben in eine Datei für Zugangsdaten ($pfad) ist untersagt."
      fi
    fi
    pruefe_secrets "$EINGABE"
    ;;
  *)
    ;;
esac

exit 0
