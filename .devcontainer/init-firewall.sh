#!/bin/bash
# Egress allowlist for the agent sandbox. Runs as root via sudo at container start.
# Default-deny outbound; allow DNS, localhost, the docker host network, and
# the domains the agent CLIs need (Anthropic, OpenAI, GitHub, npm, PyPI).
# Extra domains: /etc/sbx/allow, one per line. /etc/sbx is a read-only bind
# mount of the per-project host config dir (see sbx). Nothing the container
# user can write is read here, and arguments are ignored: sudoers permits this
# script only without arguments.
set -euo pipefail

ALLOW_DOMAINS=(
    api.anthropic.com
    statsig.anthropic.com
    sentry.io
    claude.ai
    api.openai.com
    chatgpt.com
    auth.openai.com
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
ALLOW_FILE=/etc/sbx/allow
if [ -f "$ALLOW_FILE" ]; then
    # Only trust the file if it arrives via a read-only mount; a writable
    # /etc/sbx would let the container user extend the allowlist.
    if findmnt -no OPTIONS --target /etc/sbx 2>/dev/null | tr ',' '\n' | grep -qx ro; then
        while read -r d; do
            d="${d%%#*}"; d="${d//[[:space:]]/}"
            [ -z "$d" ] && continue
            if [[ "$d" =~ ^[A-Za-z0-9.-]+(/[0-9]+)?$ ]]; then
                ALLOW_DOMAINS+=("$d")
            else
                echo "warn: ignoring malformed allow entry: $d" >&2
            fi
        done < "$ALLOW_FILE"
    else
        echo "warn: ignoring $ALLOW_FILE: /etc/sbx is not a read-only mount" >&2
    fi
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
echo "firewall: verified"
