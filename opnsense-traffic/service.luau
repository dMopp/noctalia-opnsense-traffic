--!nonstrict
-- OPNsense traffic backend. Polls /api/diagnostics/traffic/interface, turns the
-- byte counters of every interface into rates and publishes one snapshot for
-- widget and panel. With auto_detect on and no interface configured it picks
-- the interface that carries the default route (/api/interfaces/overview).
--
-- The API key never goes into the Noctalia settings: it is read from a
-- key=/secret= file (the format OPNsense offers for download), so it does not
-- end up in settings.toml or anything mirrored from it.

local peaks = require("./lib/peaks.luau")

local SNAPSHOT_KEY = "opnsense_snapshot"
local COMMAND_KEY = "opnsense_command"
local HISTORY = 40
local DETECT_EVERY_MS = 10 * 60 * 1000

local running = false
local lastRun = 0
local counters = {} -- id -> { rx, tx, t }
local rates = {} -- id -> { rx, tx }
local history = { id = "", rx = {}, tx = {}, peakRx = 0, peakTx = 0 }

peaks.load()
local detected = { id = "", at = 0, error = "" }

local function config(key, fallback)
	local value = noctalia.getConfig(key)
	if value == nil then
		return fallback
	end
	return value
end

local function baseUrl()
	local url = noctalia.string.trim(tostring(config("url", "")))
	url = url:gsub("/+$", ""):gsub("/api$", "")
	return url
end

local function readCredentials()
	local path = noctalia.expandPath(tostring(config("credentials_file", "")))
	if path == "" or not noctalia.fileExists(path) then
		return nil, noctalia.tr("errors.no_credentials", { path = path })
	end
	local raw = noctalia.readFile(path)
	if raw == nil then
		return nil, noctalia.tr("errors.no_credentials", { path = path })
	end
	local key = raw:match("key%s*=%s*([^%s]+)")
	local secret = raw:match("secret%s*=%s*([^%s]+)")
	if key == nil or secret == nil then
		return nil, noctalia.tr("errors.bad_credentials", { path = path })
	end
	return { key = key, secret = secret }
end

local function request(creds, path, cb)
	return noctalia.http({
		url = baseUrl() .. "/api/" .. path,
		headers = { "Accept: application/json" },
		basic_username = creds.key,
		basic_password = creds.secret,
		allow_insecure_tls = config("allow_insecure_tls", false) == true,
	}, cb)
end

-- Turns a failed response into a message; nil when the response is usable.
local function responseError(response, privilege)
	if not response.ok or (response.status or 0) == 0 then
		return noctalia.tr("errors.unreachable", { url = baseUrl() })
	elseif response.status == 401 then
		return noctalia.tr("errors.unauthorized")
	elseif response.status == 403 then
		return noctalia.tr("errors.forbidden", { privilege = privilege })
	elseif response.status ~= 200 then
		return noctalia.tr("errors.http", { status = tostring(response.status) })
	end
	return nil
end

local function publish(snapshot)
	snapshot.updatedAt = noctalia.nowMs()
	noctalia.state.set(SNAPSHOT_KEY, snapshot)
end

local function publishError(err)
	publish({ error = err, interfaces = {}, selected = "", rx = 0, tx = 0, history = history })
end

local function detect(creds)
	request(creds, "interfaces/overview/interfaces_info", function(response)
		detected.at = noctalia.nowMs()
		local err = responseError(response, "Status: Interfaces")
		if err ~= nil then
			detected.error = err
			return
		end
		local data = noctalia.json.decode(response.body or "")
		detected.error = noctalia.tr("errors.no_default_route")
		for _, row in ipairs(type(data) == "table" and data.rows or {}) do
			local id = tostring(row.identifier or "")
			if id ~= "" and type(row.routes) == "table" then
				for _, route in ipairs(row.routes) do
					if route == "default" then
						detected.id = id
						detected.error = ""
						return
					end
				end
			end
		end
	end)
end

-- Matches the configured name against identifier (opt1), description (WAN) and
-- device (pppoe0), case-insensitively.
local function resolve(interfaces)
	local wanted = noctalia.string.trim(tostring(config("interface", ""))):lower()
	if wanted == "" then
		if config("auto_detect", false) ~= true then
			return nil, noctalia.tr("errors.no_interface")
		end
		if detected.id == "" then
			return nil, detected.error ~= "" and detected.error or noctalia.tr("errors.detecting")
		end
		wanted = detected.id:lower()
	end
	for _, iface in ipairs(interfaces) do
		if iface.id:lower() == wanted or iface.name:lower() == wanted or iface.device:lower() == wanted then
			return iface
		end
	end
	return nil, noctalia.tr("errors.unknown_interface", { name = wanted })
end

local function push(list, value)
	table.insert(list, value)
	while #list > HISTORY do
		table.remove(list, 1)
	end
end

local function handleTraffic(response)
	local err = responseError(response, "Reporting: Traffic")
	if err ~= nil then
		publishError(err)
		return
	end
	local data = noctalia.json.decode(response.body or "")
	if type(data) ~= "table" or type(data.interfaces) ~= "table" then
		publishError(noctalia.tr("errors.bad_response"))
		return
	end

	local now = noctalia.nowMs()
	local interfaces = {}
	for id, info in pairs(data.interfaces) do
		local rx = tonumber(info["bytes received"])
		local tx = tonumber(info["bytes transmitted"])
		if rx ~= nil and tx ~= nil then
			local prev = counters[id]
			if prev ~= nil and now > prev.t then
				local dt = (now - prev.t) / 1000
				-- A counter that went backwards was reset (reboot, interface reattach): skip one sample.
				if rx >= prev.rx and tx >= prev.tx then
					rates[id] = { rx = (rx - prev.rx) / dt, tx = (tx - prev.tx) / dt }
				end
			end
			counters[id] = { rx = rx, tx = tx, t = now }
			local rate = rates[id] or { rx = 0, tx = 0 }
			table.insert(interfaces, {
				id = id,
				name = tostring(info.name or id),
				device = tostring(info.device or ""),
				rx = rate.rx,
				tx = rate.tx,
				ready = rates[id] ~= nil,
			})
		end
	end
	table.sort(interfaces, function(a, b)
		return a.name:lower() < b.name:lower()
	end)

	local iface, resolveErr = resolve(interfaces)
	if iface == nil then
		publish({ error = resolveErr, interfaces = interfaces, selected = "", rx = 0, tx = 0, history = history })
		return
	end
	if history.id ~= iface.id then
		history = { id = iface.id, rx = {}, tx = {} }
	end
	local now = os.time()
	if iface.ready then
		push(history.rx, iface.rx)
		push(history.tx, iface.tx)
		peaks.record(iface.id, iface.rx, iface.tx, now)
		peaks.save(false)
	end
	-- Peaks of the selected interface within the hold time; `since` and the
	-- *At fields are Unix seconds for the panel.
	local hold = math.max(tonumber(config("peak_hold_hours", 0)) or 0, 0)
	local peak = peaks.current(iface.id, hold, now)
	history.peakRx = peak.rx
	history.peakRxAt = peak.rxAt
	history.peakTx = peak.tx
	history.peakTxAt = peak.txAt
	history.since = peak.since
	history.hold = hold
	publish({
		error = "",
		interfaces = interfaces,
		selected = iface.id,
		selectedName = iface.name,
		selectedDevice = iface.device,
		ready = iface.ready,
		rx = iface.rx,
		tx = iface.tx,
		history = history,
	})
end

local function poll()
	if running then
		return
	end
	lastRun = noctalia.nowMs()
	if baseUrl() == "" then
		publishError(noctalia.tr("errors.no_url"))
		return
	end
	local creds, err = readCredentials()
	if creds == nil then
		publishError(err)
		return
	end
	local wantsDetect = config("auto_detect", false) == true
		and noctalia.string.trim(tostring(config("interface", ""))) == ""
	if wantsDetect and (detected.at == 0 or noctalia.nowMs() - detected.at >= DETECT_EVERY_MS) then
		detected.at = noctalia.nowMs()
		detect(creds)
	end
	running = true
	local accepted = request(creds, "diagnostics/traffic/interface", function(response)
		running = false
		handleTraffic(response)
	end)
	if not accepted then
		running = false
		publishError(noctalia.tr("errors.unreachable", { url = baseUrl() }))
	end
end

local function resetPeaks()
	if history.id ~= "" then
		peaks.reset(history.id, os.time())
	end
	poll()
end

noctalia.state.watch(COMMAND_KEY, function(cmd)
	if type(cmd) ~= "table" then
		return
	end
	if cmd.action == "refresh" then
		detected.at = 0
		poll()
	elseif cmd.action == "reset_peaks" then
		resetPeaks()
	end
end)

function onIpc(event, _payload)
	if event == "refresh" then
		detected.at = 0
		poll()
	elseif event == "reset-peaks" then
		resetPeaks()
	end
end

-- Tick fast and poll once the configured interval passed, so a changed
-- poll_interval takes effect without a restart.
noctalia.setUpdateInterval(250)

function update()
	local interval = math.max(tonumber(config("poll_interval", 2)) or 2, 1) * 1000
	if noctalia.nowMs() - lastRun >= interval then
		poll()
	end
end

poll()
