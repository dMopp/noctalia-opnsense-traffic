--!nonstrict
-- Tests with a stubbed noctalia table, run through tests/run.sh.

local failed = 0
local function check(name, got, want)
	if got ~= want then
		failed += 1
		print("FAIL " .. name .. ": got " .. tostring(got) .. ", want " .. tostring(want))
	end
end

-- Stub --------------------------------------------------------------------

local files = {}
local writes = {}
local settings = {}
local httpQueue = {}
local spawned = {}
local watchers = {}
local published = nil

local function decodeFixture(text)
	return files["json:" .. text]
end

noctalia = {
	pluginDataDir = function()
		return "/data"
	end,
	fileExists = function(p)
		return files[p] ~= nil
	end,
	readFile = function(p)
		return files[p]
	end,
	writeFile = function(p, text)
		if settings.failWrites then
			return false
		end
		files[p] = text
		table.insert(writes, p)
		return true
	end,
	renameFile = function(from, to)
		files[to] = files[from]
		files[from] = nil
		return true
	end,
	-- Fixtures: the tests register decoded values under the text they pass.
	json = {
		decode = decodeFixture,
		encode = function(value)
			local text = "encoded" .. tostring(#writes)
			files["json:" .. text] = value
			return text
		end,
	},
	string = {
		trim = function(s)
			return (s:gsub("^%s+", ""):gsub("%s+$", ""))
		end,
	},
	getConfig = function(key)
		return settings[key]
	end,
	expandPath = function(p)
		return p
	end,
	tr = function(key)
		return key
	end,
	nowMs = function()
		return clockMs
	end,
	commandExists = function()
		return true
	end,
	setUpdateInterval = function() end,
	runAsync = function(args, cb)
		table.insert(spawned, { args = args, cb = cb })
		return true
	end,
	http = function(request, cb)
		table.insert(httpQueue, { request = request, cb = cb })
		return true
	end,
	state = {
		set = function(key, value)
			if key == "opnsense_snapshot" then
				published = value
			end
		end,
		get = function()
			return nil
		end,
		watch = function(key, fn)
			watchers[key] = fn
		end,
	},
}

-- checks ------------------------------------------------------------------

local checks = require("./lib/checks.luau")

for _, url in ipairs({ "https://opnsense.lan", "HTTPS://a:4443", "https://10.0.0.1:8443" }) do
	check("secure " .. url, checks.isSecureUrl(url), true)
end
for _, url in ipairs({ "http://opnsense.lan", "opnsense.lan", "file:///etc/passwd", "-K", "https://", "https:// a", "" }) do
	check("insecure " .. url, checks.isSecureUrl(url), false)
end

local function parsed(raw)
	local c = checks.parseCredentials(raw)
	return c and (c.key .. "|" .. c.secret) or "nil"
end
check("plain", parsed("key=K\nsecret=S\n"), "K|S")
check("spaces", parsed("key = K\nsecret = S"), "K|S")
check("crlf", parsed("key=K\r\nsecret=S\r\n"), "K|S")
check("base64 padding", parsed("key=K==\nsecret=S=\n"), "K==|S=")
check("first wins", parsed("key=K\nsecret=S\nkey=OLD\n"), "K|S")
check("other names ignored", parsed("apikey=X\nkey=K\nsecret=S\n"), "K|S")
check("comment ignored", parsed("# key=X\nkey=K\nsecret=S\n"), "K|S")
check("two words rejected", parsed("key=K x\nsecret=S\n"), "nil")
check("missing secret", parsed("key=K\n"), "nil")
check("empty", parsed(""), "nil")

check("stale without snapshot", checks.isStale(nil, 1000, 2), true)
check("fresh", checks.isStale(1000, 30000, 2), false)
check("stale after a minute", checks.isStale(1000, 62000, 2), true)
check("long poll not stale", checks.isStale(1000, 100000, 60), false)
check("long poll stale", checks.isStale(1000, 182000, 60), true)

-- peaks: damaged file -----------------------------------------------------

local peaks = require("./lib/peaks.luau")

files["/data/peaks.json"] = "damaged"
files["json:damaged"] = {
	good = { since = 5, all = { rx = 9, rxAt = 6, tx = 1 }, buckets = { { t = 0, rx = 2, tx = 3 }, "x", { rx = 1 } } },
	noAll = { since = 5 },
	noSince = { all = {} },
	wrongNumbers = { since = 5, all = { rx = "a", tx = {} }, buckets = "x" },
	notTable = 3,
	[1] = { since = 5, all = {} },
}
peaks.load()
check("kept peak", peaks.current("good", 0, 100).rx, 9)
check("kept bucket peak", peaks.current("good", 1, 1000).tx, 3)
check("record on repaired entry", pcall(peaks.record, "wrongNumbers", 1, 1, 200), true)
check("bad number repaired", peaks.current("wrongNumbers", 0, 200).rx, 1)
check("record on dropped entry", pcall(peaks.record, "noAll", 1, 1, 200), true)
check("current on dropped entry", pcall(peaks.current, "noSince", 1, 200), true)

-- peaks: saving -----------------------------------------------------------

writes = {}
settings.failWrites = true
peaks.record("good", 50, 50, 300)
peaks.save(true)
check("failed save wrote nothing", #writes, 0)
settings.failWrites = false
peaks.save(true)
check("retried after failure", writes[1], "/data/peaks.json.tmp")
check("no temp file left", files["/data/peaks.json.tmp"], nil)
check("target written", files["/data/peaks.json"] ~= nil, true)
files["/data/peaks.json"] = nil

-- service -----------------------------------------------------------------

settings.url = "https://fw"
settings.credentials_file = "/key"
settings.interface = "wan"
settings.poll_interval = 2
files["/key"] = "key=K\nsecret=S\n"

require("./service.luau")

local function respond(status, value)
	local entry = table.remove(httpQueue)
	local text = "body" .. tostring(clockMs)
	files["json:" .. text] = value
	entry.cb({ ok = status ~= 0, status = status, body = text })
end

local function counters(time, rx, tx)
	return { time = time, interfaces = { wan = { name = "WAN", device = "pppoe0", ["bytes received"] = rx, ["bytes transmitted"] = tx } } }
end

local function tick(seconds)
	clockMs += seconds * 1000
	update()
end

check("first poll asks both", #httpQueue, 2)
table.remove(httpQueue, 1)
respond(200, counters(1000, 0, 0))
check("first sample not ready", published.ready, false)

tick(2)
respond(200, counters(1002, 2000, 4000))
check("rx rate", published.rx, 1000)
check("tx rate", published.tx, 2000)
check("one history sample", #published.history.rx, 1)

-- A refresh right after the poll: tiny span, huge apparent rate.
watchers["opnsense_command"]({ action = "refresh" })
table.remove(httpQueue, 1) -- detect again
respond(200, counters(1002.01, 3000, 5000))
check("too soon keeps the rate", published.rx, 1000)
check("too soon adds no sample", #published.history.rx, 1)
check("too soon sets no peak", published.history.peakRx, 1000)

tick(2)
respond(200, counters(1004, 4000, 8000))
check("next poll measures the whole span", published.rx, 1000)

-- A failed request keeps the rows, a rejected key clears them.
tick(2)
respond(0, nil)
check("failure shows an error", published.error, "errors.unreachable")
check("failure keeps rows", #published.interfaces, 1)
check("failure keeps the selection", published.selected, "wan")
check("failure has no rate", published.rx, 0)

-- That failure switched to curl and retried at once.
check("curl retry started", #spawned, 1)
check("curl gets no key", table.concat(spawned[1].args, " "):find("secret=", 1, true), nil)
local fallback = table.remove(spawned)
fallback.cb({ exitCode = 0, stdout = "\n401" })
check("401 clears rows", #published.interfaces, 0)
check("401 message", published.error, "errors.unauthorized")

-- Malformed answers must not raise: repeated errors would stop the service.
for name, body in pairs({
	numberRow = { time = 1, interfaces = { wan = 3 } },
	stringRow = { time = 1, interfaces = { wan = "x" } },
	arrayRows = { time = 1, interfaces = { { name = "WAN" } } },
	noCounters = { time = 1, interfaces = { wan = { name = "WAN" } } },
	textCounters = { time = "x", interfaces = { wan = { ["bytes received"] = "a", ["bytes transmitted"] = {} } } },
	interfacesText = { time = 1, interfaces = "x" },
	notTable = 3,
}) do
	tick(2)
	local entry = table.remove(spawned)
	local text = "malformed" .. name
	files["json:" .. text] = body
	check("no error on " .. name, pcall(entry.cb, { exitCode = 0, stdout = text .. "\n200" }), true)
end

-- Waking up: no rate from before the suspend, even if the firewall's own clock
-- says the next sample is close by.
tick(2)
local entry = table.remove(spawned)
files["json:good1"] = counters(2000, 0, 0)
entry.cb({ exitCode = 0, stdout = "good1\n200" })
tick(2)
entry = table.remove(spawned)
files["json:good2"] = counters(2002, 2000, 2000)
entry.cb({ exitCode = 0, stdout = "good2\n200" })
check("rate before the suspend", published.rx, 1000)
tick(60)
entry = table.remove(spawned)
files["json:good3"] = counters(2004, 9000, 9000)
entry.cb({ exitCode = 0, stdout = "good3\n200" })
check("no old rate after waking up", published.rx, 0)
check("not ready after waking up", published.ready, false)

-- An insecure URL reaches neither client.
local before = #httpQueue + #spawned
settings.url = "http://fw"
tick(2)
check("http refused", published.error, "errors.insecure_url")
check("no request over http", #httpQueue + #spawned, before)

-- Widget and panel: a dead service must not leave an old rate on screen -------

local good = {
	error = "",
	updatedAt = clockMs,
	selected = "wan",
	selectedName = "WAN",
	selectedDevice = "",
	rx = 1000,
	tx = 2000,
	interfaces = {},
	history = { rx = {}, tx = {} },
}

local function texts(node, out)
	out = out or {}
	if type(node) == "table" then
		if node.props and node.props.text then
			table.insert(out, node.props.text)
		end
		for _, kid in ipairs(node.kids or {}) do
			texts(kid, out)
		end
	end
	return table.concat(out, " ")
end

ui = setmetatable({}, {
	__index = function(_, kind)
		return function(props, kids)
			return { kind = kind, props = props, kids = kids }
		end
	end,
})
noctalia.getSetting = function()
	return {}
end
noctalia.getColor = function()
	return "#000000"
end
noctalia.trp = noctalia.tr
noctalia.timeFormat = function()
	return ""
end
noctalia.formatTime = function()
	return ""
end

local shown, tip = nil, nil
barWidget = {
	isVertical = function()
		return false
	end,
	render = function(node)
		shown = node
	end,
	setTooltip = function(rows)
		tip = rows
	end,
}
require("./widget.luau")
check("widget without snapshot", texts(shown), "--")
watchers["opnsense_snapshot"](good)
check("widget shows the rate", texts(shown), "1.0 kB/s")
update()
check("widget stays current", texts(shown), "1.0 kB/s")
clockMs += 61000
update()
check("widget marks stale", texts(shown), "--")
check("stale tooltip", tip[1].value, "errors.stale")
good.updatedAt = clockMs
watchers["opnsense_snapshot"](good)
check("widget recovers", texts(shown), "1.0 kB/s")

local panelNode = nil
panel = {
	render = function(node)
		panelNode = node
	end,
}
require("./panel.luau")
watchers["opnsense_snapshot"](good)
check("panel has no error", texts(panelNode):find("errors.stale", 1, true), nil)
clockMs += 61000
update()
check("panel marks stale", texts(panelNode):find("errors.stale", 1, true) ~= nil, true)

if failed == 0 then
	print("all tests passed")
end
