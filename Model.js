// Pure helpers for the Cloudflare WARP panel. state.sh hands over one JSON
// document built from `warp-cli -j ...` calls; everything here turns that into
// plain values the QML binds to, so it can be tested under node.

var MODES = [
  { id: "warp", label: "WARP", detail: "Tunnel all traffic, DNS over UDP" },
  { id: "warp+doh", label: "WARP + DoH", detail: "Tunnel all traffic, DNS over HTTPS" },
  { id: "doh", label: "DNS only (DoH)", detail: "No tunnel, 1.1.1.1 over HTTPS" },
  { id: "tunnel_only", label: "Tunnel only", detail: "Tunnel traffic, leave DNS alone" },
  { id: "proxy", label: "Local proxy", detail: "SOCKS5/HTTPS proxy on localhost only" }
]

var DEFAULT_PROXY_PORT = 40000

function str(value) {
  return value === undefined || value === null ? "" : String(value)
}

// warp-cli answers errors in JSON too ({ code, error }), so a parsed object
// is only useful when it doesn't carry an error.
function usable(value) {
  return !!value && typeof value === "object" && value.error === undefined && value.code === undefined
}

// "NetworkHealthy" -> "Network healthy", "SettingsChanged" -> "Settings changed"
function humanize(value) {
  var text = str(value).trim()
  if (text === "") return ""
  if (/\s/.test(text)) return text
  var spaced = text.replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/[_-]+/g, " ").toLowerCase()
  return spaced.charAt(0).toUpperCase() + spaced.slice(1)
}

function cleanTeamName(value) {
  return str(value).trim().toLowerCase()
    .replace(/^https?:\/\//, "")
    .replace(/\.cloudflareaccess\.com.*$/, "")
    .replace(/[^a-z0-9-]/g, "")
}

function modeLabel(mode) {
  var id = str(mode)
  for (var i = 0; i < MODES.length; i++) if (MODES[i].id === id) return MODES[i].label
  return humanize(id)
}

function formatBytes(value) {
  var n = Number(value)
  if (!isFinite(n) || n <= 0) return "0 B"
  var units = ["B", "KB", "MB", "GB", "TB"]
  var i = 0
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
  return (i === 0 || n >= 100 ? Math.round(n) : n.toFixed(1)) + " " + units[i]
}

function routes(list) {
  var result = []
  if (!Array.isArray(list)) return result
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    var value = typeof entry === "string" ? entry : str(entry && (entry.value || entry.address || entry.host))
    if (value === "") continue
    result.push({ value: value, description: typeof entry === "object" ? str(entry.description) : "" })
  }
  return result
}

function emptyState() {
  return {
    installed: false,
    serviceUp: false,
    registered: false,
    status: "",
    connected: false,
    connecting: false,
    reason: "",
    accountType: "",
    zeroTrust: false,
    organization: "",
    deviceId: "",
    managed: false,
    mode: "",
    modeLocked: false,
    switchLocked: false,
    alwaysOn: false,
    proxyPort: DEFAULT_PROXY_PORT,
    protocol: "",
    splitTunnelMode: "",
    splitTunnelRoutes: [],
    vnets: [],
    activeVnetId: "",
    localNetworkAllowed: false,
    localNetworkEndsInSecs: 0,
    edge: "",
    latencyMs: -1,
    bytesSent: 0,
    bytesReceived: 0,
    tunnelEndpoint: ""
  }
}

function parseState(raw) {
  var state = emptyState()
  var data
  try {
    data = JSON.parse(str(raw).trim() || "{}")
  } catch (e) {
    return state
  }
  if (!data || typeof data !== "object") return state

  state.installed = data.installed === true
  state.serviceUp = state.installed && data.service === true
  if (!state.serviceUp) return state

  var status = usable(data.status) ? data.status : {}
  state.status = str(status.status)
  var lowered = state.status.toLowerCase()
  state.connected = lowered === "connected"
  state.connecting = lowered.indexOf("connecting") !== -1
  state.reason = humanize(status.reason)

  var registration = usable(data.registration) ? data.registration : null
  state.registered = !!registration
  if (registration) {
    var account = registration.account || {}
    state.accountType = str(account.type)
    state.zeroTrust = state.accountType.toLowerCase() === "team"
    state.organization = str(account.organization)
    state.deviceId = str(registration.device_id || registration.id)
    state.managed = registration.managed === true
  }

  var settingsDoc = usable(data.settings) ? data.settings : {}
  var settings = settingsDoc.settings || {}
  state.mode = str(settings.operation_mode)
  // Zero Trust device profiles decide whether users may change the mode.
  state.modeLocked = settings.allow_mode_switch === false
  state.switchLocked = settings.switch_locked === true
  state.alwaysOn = settings.always_on === true
  var port = parseInt(str(settings.proxy_port), 10)
  if (isFinite(port) && port > 0) state.proxyPort = port
  state.protocol = str(settings.warp_tunnel_protocol)
  state.splitTunnelMode = str(settings.split_tunnel_mode)
  if (state.organization === "") state.organization = str(settings.organization)
  state.splitTunnelRoutes = routes(settings.split_tunnel_hosts).concat(routes(settings.split_tunnel_ips))

  var vnet = usable(data.vnet) ? data.vnet : {}
  state.activeVnetId = str(vnet.active_vnet_id)
  var networks = Array.isArray(vnet.virtual_networks) ? vnet.virtual_networks : []
  for (var i = 0; i < networks.length; i++) {
    var network = networks[i] || {}
    var id = str(network.id)
    if (id === "") continue
    state.vnets.push({
      id: id,
      name: str(network.name) || id,
      description: str(network.description),
      isDefault: network.default === true,
      active: id === state.activeVnetId
    })
  }

  var local = usable(data.localNetwork) ? data.localNetwork : {}
  state.localNetworkAllowed = local.allowed === true
  state.localNetworkEndsInSecs = Number(local.ends_in_secs) || 0

  var stats = usable(data.stats) ? data.stats : null
  if (stats && state.connected) {
    var edge = stats.edge || {}
    state.edge = str(edge.colo)
    var latency = Number(stats.estimated_latency_ms)
    state.latencyMs = isFinite(latency) ? latency : -1
    state.bytesSent = Number(stats.bytes_sent) || 0
    state.bytesReceived = Number(stats.bytes_received) || 0
    state.tunnelEndpoint = str(stats.v4_endpoint)
    if (str(stats.protocol) !== "") state.protocol = str(stats.protocol)
  }

  return state
}

// "loading" | "install" | "service" | "register" | "ready"
function stage(loaded, state) {
  if (!loaded) return "loading"
  if (!state || !state.installed) return "install"
  if (!state.serviceUp) return "service"
  if (!state.registered) return "register"
  return "ready"
}

function accountLabel(state) {
  if (!state || !state.registered) return ""
  if (state.zeroTrust) return state.organization !== "" ? "Zero Trust · " + state.organization : "Zero Trust"
  var type = str(state.accountType).toLowerCase()
  if (type === "free" || type === "") return "WARP (free)"
  return "WARP " + humanize(state.accountType)
}

function edgeSummary(state) {
  if (!state || !state.connected) return ""
  var parts = []
  if (state.edge !== "") parts.push(state.edge)
  if (state.latencyMs >= 0) parts.push(Math.round(state.latencyMs) + " ms")
  return parts.join(" · ")
}

function proxyAddress(state) {
  return "socks5://127.0.0.1:" + ((state && state.proxyPort) || DEFAULT_PROXY_PORT)
}

// The ordered keyboard stops for the panel. Each key names one row, so the
// QML only has to compare against the current key to draw the cursor.
function navKeys(panelStage, state, flags) {
  var opts = flags || {}
  var keys = []
  if (panelStage === "install") return ["install"]
  if (panelStage === "service") return ["start-service"]
  if (panelStage === "register") {
    keys.push("team", "register-team", "register-free")
    if (opts.registering && opts.hasLoginUrl) keys.push("open-login")
    if (opts.registering || opts.changingTeam) keys.push("cancel")
    return keys
  }
  if (panelStage !== "ready" || !state) return keys

  keys.push("toggle")
  if (!state.modeLocked) for (var m = 0; m < MODES.length; m++) keys.push("mode:" + MODES[m].id)
  if (state.mode === "proxy") keys.push("proxy")
  if (state.vnets.length > 1) for (var v = 0; v < state.vnets.length; v++) keys.push("vnet:" + state.vnets[v].id)
  if (state.zeroTrust) keys.push("local-network")
  for (var r = 0; r < state.splitTunnelRoutes.length; r++) keys.push("route:" + r)
  keys.push("change-team", "unregister")
  return keys
}

function moveKey(keys, current, delta) {
  if (!keys || keys.length === 0) return ""
  var index = keys.indexOf(current)
  if (index === -1) return delta < 0 ? keys[keys.length - 1] : keys[0]
  return keys[Math.max(0, Math.min(keys.length - 1, index + delta))]
}

function registerCommand(team) {
  var name = cleanTeamName(team)
  // A device carries a single registration, so replacing it means deleting the
  // old one first. warp-cli itself opens the team's login page in the browser.
  var script = "warp-cli --accept-tos registration delete >/dev/null 2>&1; "
    + (name !== "" ? "exec warp-cli --accept-tos registration new \"$1\"" : "exec warp-cli --accept-tos registration new")
  return name !== "" ? ["bash", "-c", script, "warp-register", name] : ["bash", "-c", script]
}

if (typeof module !== "undefined") {
  module.exports = {
    MODES: MODES,
    DEFAULT_PROXY_PORT: DEFAULT_PROXY_PORT,
    humanize: humanize,
    cleanTeamName: cleanTeamName,
    modeLabel: modeLabel,
    formatBytes: formatBytes,
    parseState: parseState,
    stage: stage,
    accountLabel: accountLabel,
    edgeSummary: edgeSummary,
    proxyAddress: proxyAddress,
    navKeys: navKeys,
    moveKey: moveKey,
    registerCommand: registerCommand
  }
}
