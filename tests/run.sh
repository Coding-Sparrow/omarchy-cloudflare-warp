#!/bin/bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

command -v jq >/dev/null || fail "jq is required"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

mock_bin="$TMPDIR/bin"
mkdir -p "$mock_bin"

cat >"$mock_bin/systemctl" <<'SH'
#!/bin/bash
[[ ${OMARCHY_TEST_WARP_SVC:-1} == "1" ]]
SH

cat >"$mock_bin/warp-cli" <<'SH'
#!/bin/bash
set -euo pipefail

args="$*"
case "$args" in
  "--accept-tos -j status")
    printf '{"status":"%s","reason":"NetworkHealthy"}\n' "${OMARCHY_TEST_WARP_STATUS:-Connected}"
    ;;
  "--accept-tos -j registration show")
    if [[ ${OMARCHY_TEST_WARP_REGISTERED:-1} == "1" ]]; then
      echo '{"id":"dev-1","device_id":"dev-1","managed":false,"account":{"type":"team","organization":"acme"}}'
    else
      echo '{"code":"MissingRegistration","error":"Missing registration"}'
      exit 1
    fi
    ;;
  "--accept-tos -j settings")
    echo '{"settings":{"always_on":true,"switch_locked":false,"operation_mode":"warp","allow_mode_switch":true,"split_tunnel_mode":"exclude","split_tunnel_hosts":[{"value":"*.local","description":""}],"split_tunnel_ips":[{"value":"10.0.0.0/8","description":"office"}],"fallback_domains":[{"domain":"lan"}],"speed_test_settings":{}},"sources":{}}'
    ;;
  "--accept-tos -j vnet")
    echo '{"active_vnet_id":"b","virtual_networks":[{"id":"a","name":"default","description":"","default":true},{"id":"b","name":"staging","description":"Staging VPC","default":false}]}'
    ;;
  "--accept-tos -j override local-network show")
    echo '{"allowed":false,"ends_in_secs":0,"ends_after_reconnection":false}'
    ;;
  "--accept-tos -j tunnel stats")
    echo '{"v4_endpoint":"162.159.197.2","bytes_sent":2048,"bytes_received":1048576,"estimated_latency_ms":12,"protocol":"MASQUE","edge":{"colo":"AMS"}}'
    ;;
  *)
    exit 1
    ;;
esac
SH

chmod +x "$mock_bin"/*
state_script="$ROOT/scripts/state.sh"

# Only the tools state.sh needs, so a real warp-cli on this machine can't leak in.
tools="$TMPDIR/tools"
mkdir -p "$tools"
ln -s "$(command -v jq)" "$tools/jq"
ln -s "$(command -v timeout)" "$tools/timeout"
no_cli="$TMPDIR/no-cli"
mkdir -p "$no_cli"
cp "$mock_bin/systemctl" "$no_cli/"

run_state() {
  if [[ ${OMARCHY_TEST_WARP_CLI:-1} == "1" ]]; then
    PATH="$mock_bin:$tools" "$state_script"
  else
    PATH="$no_cli:$tools" "$state_script"
  fi
}

[[ $(OMARCHY_TEST_WARP_CLI=0 run_state) == '{"installed":false}' ]] || fail "state reports a missing warp-cli"
pass "state reports a missing warp-cli"

[[ $(OMARCHY_TEST_WARP_SVC=0 run_state) == '{"installed":true,"service":false}' ]] || fail "state reports a stopped warp-svc"
pass "state reports a stopped warp-svc"

run_state >"$TMPDIR/connected.json"
jq -e '
  .installed and .service and
  .status.status == "Connected" and
  .registration.account.organization == "acme" and
  .settings.settings.operation_mode == "warp" and
  (.settings.settings | has("fallback_domains") | not) and
  (.settings.settings | has("speed_test_settings") | not) and
  .vnet.active_vnet_id == "b" and
  .stats.edge.colo == "AMS"
' "$TMPDIR/connected.json" >/dev/null || fail "state collects a connected Zero Trust device"
pass "state collects a connected Zero Trust device and trims settings"

OMARCHY_TEST_WARP_STATUS=Disconnected OMARCHY_TEST_WARP_REGISTERED=0 run_state >"$TMPDIR/unregistered.json"
jq -e '.registration == null and .stats == null and .status.status == "Disconnected"' "$TMPDIR/unregistered.json" >/dev/null ||
  fail "state turns a missing registration into null and skips tunnel stats"
pass "state turns a missing registration into null and skips tunnel stats"

command -v node >/dev/null || fail "node is required for the model tests"

ROOT="$ROOT" WARP_CONNECTED="$TMPDIR/connected.json" WARP_UNREGISTERED="$TMPDIR/unregistered.json" node - <<'JS'
const fs = require('fs')
const util = require('util')
const root = process.env.ROOT
function fail(description, detail) { if (detail) console.error(detail); console.error(`not ok - ${description}`); process.exit(1) }
function assert(condition, description, detail) { if (!condition) fail(description, detail); console.log(`ok - ${description}`) }
function assertEqual(actual, expected, description) { assert(actual === expected, description, `expected ${util.inspect(expected)}, got ${util.inspect(actual)}`) }
function assertDeepEqual(actual, expected, description) { assert(util.isDeepStrictEqual(actual, expected), description, `expected ${util.inspect(expected)}, got ${util.inspect(actual)}`) }
const warp = require(root + '/Model.js')
const panelSource = fs.readFileSync(root + '/Widget.qml', 'utf8')

assert(/function toggleWarp\(\): string \{ warp\.toggle\(\); return "ok" \}/.test(panelSource), 'warp exposes the connection toggle over IPC')

assertEqual(warp.cleanTeamName(' https://Acme-Corp.cloudflareaccess.com/warp '), 'acme-corp', 'team names drop the access domain and URL noise')
assertEqual(warp.cleanTeamName('acme corp!'), 'acmecorp', 'team names keep only valid characters')
assertEqual(warp.humanize('NetworkHealthy'), 'Network healthy', 'reasons are humanized')
assertEqual(warp.humanize('Manual'), 'Manual', 'single-word reasons stay readable')
assertEqual(warp.modeLabel('warp+doh'), 'WARP + DoH', 'known modes get their label')
assertEqual(warp.modeLabel('posture_only'), 'Posture only', 'unknown modes fall back to a humanized id')
assertEqual(warp.formatBytes(0), '0 B', 'zero bytes')
assertEqual(warp.formatBytes(1536), '1.5 KB', 'kilobytes keep one decimal')
assertEqual(warp.formatBytes(1048576 * 250), '250 MB', 'large values round')

const empty = warp.parseState('')
assertEqual(warp.stage(false, empty), 'loading', 'nothing loaded yet')
assertEqual(warp.stage(true, warp.parseState('{"installed":false}')), 'install', 'missing client asks to install')
assertEqual(warp.stage(true, warp.parseState('{"installed":true,"service":false}')), 'service', 'stopped daemon asks to start it')
assertEqual(warp.stage(true, warp.parseState('not json')), 'install', 'garbage state is treated as not installed')

const connected = warp.parseState(fs.readFileSync(process.env.WARP_CONNECTED, 'utf8'))
assertEqual(warp.stage(true, connected), 'ready', 'registered device is ready')
assert(connected.connected && connected.zeroTrust, 'connected Zero Trust device')
assertEqual(warp.accountLabel(connected), 'Zero Trust · acme', 'account label names the team')
assertEqual(warp.edgeSummary(connected), 'AMS · 12 ms', 'edge summary shows colo and latency')
assertEqual(connected.reason, 'Network healthy', 'status reason is humanized')
assertEqual(connected.mode, 'warp', 'mode is read from settings')
assert(!connected.modeLocked, 'mode switching follows allow_mode_switch')
assertDeepEqual(connected.splitTunnelRoutes.map(route => route.value), ['*.local', '10.0.0.0/8'], 'split tunnel hosts come before IPs')
assertEqual(connected.splitTunnelMode, 'exclude', 'split tunnel mode is kept')
assertDeepEqual(connected.vnets.map(vnet => [vnet.name, vnet.active]), [['default', false], ['staging', true]], 'virtual networks mark the active one')
assertEqual(connected.bytesReceived, 1048576, 'tunnel stats are read while connected')
assertEqual(warp.proxyAddress(connected), 'socks5://127.0.0.1:40000', 'proxy address defaults to port 40000')

const unregistered = warp.parseState(fs.readFileSync(process.env.WARP_UNREGISTERED, 'utf8'))
assertEqual(warp.stage(true, unregistered), 'register', 'unregistered device asks to register')
assertEqual(warp.accountLabel(unregistered), '', 'no account label without a registration')
assertEqual(warp.edgeSummary(unregistered), '', 'no edge summary while disconnected')

const locked = warp.parseState(JSON.stringify({
  installed: true,
  service: true,
  status: { status: 'Connected' },
  registration: { account: { type: 'free' } },
  settings: { settings: { operation_mode: 'warp+doh', allow_mode_switch: false, proxy_port: 41000 } }
}))
assert(locked.modeLocked, 'device profiles can lock the mode')
assertEqual(warp.accountLabel(locked), 'WARP (free)', 'free accounts are labelled')
assertEqual(warp.proxyAddress(locked), 'socks5://127.0.0.1:41000', 'proxy address follows the configured port')

assertDeepEqual(warp.navKeys('install', empty, {}), ['install'], 'install stage has one stop')
assertDeepEqual(warp.navKeys('register', unregistered, {}), ['team', 'register-team', 'register-free'], 'register stage stops')
assertDeepEqual(
  warp.navKeys('register', connected, { changingTeam: true, registering: true, hasLoginUrl: true }),
  ['team', 'register-team', 'register-free', 'open-login', 'cancel'],
  'a pending team change can reopen the login or cancel'
)
const readyKeys = warp.navKeys('ready', connected, {})
assertEqual(readyKeys[0], 'toggle', 'the switch is the first stop')
assert(readyKeys.includes('mode:warp+doh') && readyKeys.includes('vnet:b') && readyKeys.includes('local-network') && readyKeys.includes('route:1'), 'ready stage reaches modes, vnets, local network and routes')
assertEqual(readyKeys[readyKeys.length - 1], 'unregister', 'unregister is the last stop')
assert(!warp.navKeys('ready', locked, {}).some(key => key.startsWith('mode:')), 'locked modes are not navigable')
assert(!warp.navKeys('ready', locked, {}).includes('local-network'), 'local network access is a Zero Trust feature')

assertEqual(warp.moveKey(['a', 'b', 'c'], 'b', 1), 'c', 'cursor moves down')
assertEqual(warp.moveKey(['a', 'b', 'c'], 'c', 1), 'c', 'cursor stops at the end')
assertEqual(warp.moveKey(['a', 'b', 'c'], 'gone', 1), 'a', 'a stale cursor restarts at the top')

assertDeepEqual(warp.registerCommand('acme').slice(-2), ['warp-register', 'acme'], 'team registration passes the team as an argument, not shell text')
assert(!warp.registerCommand('').join(' ').includes('$1'), 'free registration takes no team')
JS
