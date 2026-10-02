#!/bin/bash

# Print one JSON document describing Cloudflare WARP for the bar panel.
# Every warp-cli call is optional: a missing or failing answer becomes null and
# Model.js decides what that means.

if ! command -v warp-cli >/dev/null 2>&1; then
  echo '{"installed":false}'
  exit 0
fi

if ! systemctl is-active --quiet warp-svc.service; then
  echo '{"installed":true,"service":false}'
  exit 0
fi

warp_json() {
  local output
  if output=$(timeout 5 warp-cli --accept-tos -j "$@" 2>/dev/null) && jq -e . >/dev/null 2>&1 <<<"$output"; then
    printf '%s' "$output"
  else
    printf 'null'
  fi
}

status=$(warp_json status)
registration=$(warp_json registration show)
settings=$(warp_json settings)
vnet=$(warp_json vnet)
local_network=$(warp_json override local-network show)

stats=null
if [[ $(jq -r '.status // empty' <<<"$status" 2>/dev/null) == "Connected" ]]; then
  stats=$(warp_json tunnel stats)
fi

# Settings carry a lot the panel never reads (speed test servers, fallback
# domains, ...), so keep only what it shows.
jq -cn \
  --argjson status "$status" \
  --argjson registration "$registration" \
  --argjson settings "$settings" \
  --argjson vnet "$vnet" \
  --argjson localNetwork "$local_network" \
  --argjson stats "$stats" \
  '{
    installed: true,
    service: true,
    status: $status,
    registration: $registration,
    settings: (if $settings == null then null else {
      settings: (($settings.settings // {}) | {
        always_on, switch_locked, operation_mode, allow_mode_switch, organization,
        proxy_port, warp_tunnel_protocol, split_tunnel_mode, split_tunnel_hosts, split_tunnel_ips
      })
    } end),
    vnet: $vnet,
    localNetwork: $localNetwork,
    stats: $stats
  }'
