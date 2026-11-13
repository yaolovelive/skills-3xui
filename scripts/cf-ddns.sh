#!/usr/bin/env bash
# Cloudflare Dual-Stack (IPv4 A + IPv6 AAAA) DDNS Updater
# Config file: /etc/cf-ddns.env (mode 600)
set -euo pipefail

ENV_FILE="${CF_DDNS_ENV:-/etc/cf-ddns.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

: "${CF_TOKEN:?CF_TOKEN is required}"
: "${CF_RECORD_NAME:?CF_RECORD_NAME is required (e.g. node.example.com)}"
CF_ROOT_DOMAIN="${CF_ROOT_DOMAIN:-$(echo "$CF_RECORD_NAME" | awk -F. '{print $(NF-1)"."$NF}')}"
CF_PROXIED="${CF_PROXIED:-false}"
CF_TTL="${CF_TTL:-60}"
ENABLE_IPV4="${ENABLE_IPV4:-true}"
ENABLE_IPV6="${ENABLE_IPV6:-true}"

cf_api() {
  local method="$1" endpoint="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -fsSL -X "$method" "https://api.cloudflare.com/client/v4${endpoint}" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -fsSL -X "$method" "https://api.cloudflare.com/client/v4${endpoint}" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json"
  fi
}

# Resolve Zone ID dynamically if not hardcoded
if [[ -z "${CF_ZONE_ID:-}" ]]; then
  CF_ZONE_ID=$(cf_api GET "/zones?name=${CF_ROOT_DOMAIN}" | jq -r '.result[0].id // empty')
  if [[ -z "$CF_ZONE_ID" ]]; then
    echo "[ERROR] Could not resolve Cloudflare Zone ID for ${CF_ROOT_DOMAIN}" >&2
    exit 1
  fi
fi

get_public_ipv4() {
  local url ip
  for url in "https://api4.ipify.org" "https://ipv4.icanhazip.com" "https://4.ident.me"; do
    ip=$(curl -4 -fsSL --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

get_public_ipv6() {
  local url ip
  for url in "https://api6.ipify.org" "https://ipv6.icanhazip.com" "https://6.ident.me"; do
    ip=$(curl -6 -fsSL --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$ip" =~ : ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

sync_record() {
  local rtype="$1" target_ip="$2"
  local existing_json record_id current_ip payload resp

  existing_json=$(cf_api GET "/zones/${CF_ZONE_ID}/dns_records?type=${rtype}&name=${CF_RECORD_NAME}")
  record_id=$(echo "$existing_json" | jq -r '.result[0].id // empty')
  current_ip=$(echo "$existing_json" | jq -r '.result[0].content // empty')

  payload=$(jq -nc \
    --arg type "$rtype" \
    --arg name "$CF_RECORD_NAME" \
    --arg content "$target_ip" \
    --argjson ttl "$CF_TTL" \
    --argjson proxied "$CF_PROXIED" \
    '{type: $type, name: $name, content: $content, ttl: $ttl, proxied: $proxied}')

  if [[ -z "$record_id" ]]; then
    resp=$(cf_api POST "/zones/${CF_ZONE_ID}/dns_records" "$payload")
    if [[ $(echo "$resp" | jq -r '.success') == "true" ]]; then
      echo "[OK] Created ${rtype} ${CF_RECORD_NAME} -> ${target_ip}"
    else
      echo "[ERROR] Failed to create ${rtype} ${CF_RECORD_NAME}: $resp" >&2
      return 1
    fi
  elif [[ "$current_ip" == "$target_ip" ]]; then
    echo "[SKIP] ${rtype} ${CF_RECORD_NAME} unchanged (${current_ip})"
  else
    resp=$(cf_api PUT "/zones/${CF_ZONE_ID}/dns_records/${record_id}" "$payload")
    if [[ $(echo "$resp" | jq -r '.success') == "true" ]]; then
      echo "[OK] Updated ${rtype} ${CF_RECORD_NAME}: ${current_ip} -> ${target_ip}"
    else
      echo "[ERROR] Failed to update ${rtype} ${CF_RECORD_NAME}: $resp" >&2
      return 1
    fi
  fi
}

if [[ "$ENABLE_IPV4" == "true" ]]; then
  if ipv4=$(get_public_ipv4); then
    sync_record "A" "$ipv4"
  else
    echo "[WARN] Could not detect public IPv4" >&2
  fi
fi

if [[ "$ENABLE_IPV6" == "true" ]]; then
  if ipv6=$(get_public_ipv6); then
    sync_record "AAAA" "$ipv6"
  else
    echo "[INFO] No public IPv6 detected; skipping AAAA sync"
  fi
fi
