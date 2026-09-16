#!/bin/bash
# Egress allowlist for the agent sandbox. Runs as root via sudo at container start.
# Default-deny outbound; allow DNS, localhost, the docker host network, and
# the domains the agent CLIs need. Two profiles (README, "Profile local"):
#   cloud  (default) cloud AI endpoints + GitHub, npm, PyPI, nodesource, Ubuntu
#   local  no cloud AI endpoint at all; instead the internal model server
# Profile, extra domains and model host come from /etc/sbx, a read-only bind
# mount generated on the host by sbx. Nothing the container user can write is
# read here, and arguments are ignored: sudoers permits this script only
# without arguments. If /etc/sbx exists but is writable, the start fails.
set -euo pipefail

CLOUD_AI_DOMAINS=(
    api.anthropic.com
    statsig.anthropic.com
    sentry.io
    claude.ai
    api.openai.com
    chatgpt.com
    auth.openai.com
)
BASE_DOMAINS=(
    registry.npmjs.org
    pypi.org
    files.pythonhosted.org
    github.com
    api.github.com
    raw.githubusercontent.com
    objects.githubusercontent.com
    codeload.github.com
    deb.nodesource.com
    archive.ubuntu.com
    security.ubuntu.com
)

PROFILE=cloud
LOCAL_HOST=""
LOCAL_URL=""
ETC_RO=0
if findmnt -no OPTIONS --target /etc/sbx 2>/dev/null | tr ',' '\n' | grep -qx ro; then
    ETC_RO=1
fi
if [ -d /etc/sbx ] && [ -n "$(ls -A /etc/sbx 2>/dev/null)" ] && [ "$ETC_RO" != 1 ]; then
    echo "firewall: ERROR /etc/sbx is not a read-only mount; refusing to start" >&2
    exit 1
fi
if [ "$ETC_RO" = 1 ] && [ -f /etc/sbx/profile ]; then
    PROFILE="$(tr -d '[:space:]' < /etc/sbx/profile)"
fi
case "$PROFILE" in
    cloud) ALLOW_DOMAINS=("${CLOUD_AI_DOMAINS[@]}" "${BASE_DOMAINS[@]}") ;;
    local)
        ALLOW_DOMAINS=("${BASE_DOMAINS[@]}")
        if [ -f /etc/sbx/local-model.env ]; then
            LOCAL_HOST="$(sed -n 's/^SBX_LOCAL_HOST=//p' /etc/sbx/local-model.env | head -1)"
            LOCAL_URL="$(sed -n 's/^SBX_LOCAL_BASE_URL=//p' /etc/sbx/local-model.env | head -1)"
        fi
        if [[ ! "$LOCAL_HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
            echo "firewall: ERROR profile local without a valid SBX_LOCAL_HOST in /etc/sbx/local-model.env" >&2
            exit 1
        fi
        ALLOW_DOMAINS+=("$LOCAL_HOST")
        ;;
    *) echo "firewall: ERROR unknown profile '$PROFILE'" >&2; exit 1 ;;
esac

ALLOW_FILE=/etc/sbx/allow
if [ "$ETC_RO" = 1 ] && [ -f "$ALLOW_FILE" ]; then
    while read -r d; do
        d="${d%%#*}"; d="${d//[[:space:]]/}"
        [ -z "$d" ] && continue
        if [[ ! "$d" =~ ^[A-Za-z0-9.-]+(/[0-9]+)?$ ]]; then
            echo "warn: ignoring malformed allow entry: $d" >&2
        elif [ "$PROFILE" = local ] && printf '%s\n' "${CLOUD_AI_DOMAINS[@]}" | grep -qx "$d"; then
            echo "warn: profile local: ignoring cloud AI domain $d from allow file" >&2
        else
            ALLOW_DOMAINS+=("$d")
        fi
    done < "$ALLOW_FILE"
fi

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# DNS and localhost first, before default-deny.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

ipset create allowed-domains hash:net

# GitHub publishes its IP ranges; pull them so git push/pull works over any of them.
gh_ranges=$(curl -fsS --max-time 10 https://api.github.com/meta || true)
if [ -n "$gh_ranges" ]; then
    echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | sort -u | while read -r cidr; do
        ipset add allowed-domains "$cidr" 2>/dev/null || true
    done
fi

for domain in "${ALLOW_DOMAINS[@]}"; do
    # Raw IPv4 address or CIDR: add as-is, no DNS lookup.
    if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
        ipset add allowed-domains "$domain" 2>/dev/null || true
        continue
    fi
    ips=$(dig +short A "$domain" | grep -E '^[0-9.]+$' || true)
    if [ -z "$ips" ]; then
        echo "warn: no A record for $domain" >&2
        continue
    fi
    for ip in $ips; do
        ipset add allowed-domains "$ip" 2>/dev/null || true
    done
done

# Docker host / bridge network so port forwards keep working.
HOST_IP=$(ip route | awk '/default/ {print $3; exit}')
HOST_NET=$(echo "$HOST_IP" | sed 's/\.[0-9]*$/.0\/24/')
iptables -A INPUT -s "$HOST_NET" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NET" -j ACCEPT

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "firewall: allowlist active (${#ALLOW_DOMAINS[@]} domains)"
# Negative check, skipped if someone allowlisted the canary itself.
if ! printf '%s\n' "${ALLOW_DOMAINS[@]}" | grep -qx example.com; then
    if curl -fsS --max-time 5 https://example.com >/dev/null 2>&1; then
        echo "firewall: ERROR example.com reachable, default-deny not working" >&2
        exit 1
    fi
fi
if ! curl -fsS --max-time 10 https://api.github.com/zen >/dev/null 2>&1; then
    echo "firewall: ERROR api.github.com unreachable" >&2
    exit 1
fi
if [ "$PROFILE" = local ]; then
    # Cloud AI endpoint must be closed; the model server should answer.
    if curl -sS --max-time 5 -o /dev/null https://api.anthropic.com/ 2>/dev/null; then
        echo "firewall: ERROR profile local but api.anthropic.com reachable" >&2
        exit 1
    fi
    if curl -sS --max-time 5 -o /dev/null "$LOCAL_URL/" 2>/dev/null; then
        echo "firewall: model server $LOCAL_HOST reachable"
    else
        echo "firewall: WARN model server $LOCAL_URL not reachable (VPN? server down?); agents will fail until it is" >&2
    fi
fi
echo "firewall: verified (profile $PROFILE, ${#ALLOW_DOMAINS[@]} domains)"
