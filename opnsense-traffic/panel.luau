--!nonstrict
-- Panel: the selected interface with both directions against the line speed,
-- then every OPNsense interface with its live rates so the right name for the
-- "interface" setting is easy to find (click a row to copy its identifier).

local format = require("./lib/format.luau")

local SNAPSHOT_KEY = "opnsense_snapshot"
local COMMAND_KEY = "opnsense_command"

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {}

local function sendRefresh()
	noctalia.state.set(COMMAND_KEY, { action = "refresh", nonce = tostring(noctalia.nowMs()) })
end

local function lineBytes(key)
	return (tonumber(noctalia.getConfig(key)) or 0) * 125000
end

-- Time of day for today's timestamps, with the date for older ones.
local function clock(unixSeconds)
	if os.time() - unixSeconds >= 20 * 3600 then
		return noctalia.formatTime("{:%Y-%m-%d %H:%M}", unixSeconds)
	end
	return noctalia.formatTime(noctalia.timeFormat(), unixSeconds)
end

-- "Peak 87.3 Mbit/s at 18:03 · since 17:55", or nil before the first sample.
local function peakText(peak, peakAt, since)
	if (tonumber(peak) or 0) <= 0 or peakAt == nil or since == nil then
		return nil
	end
	return noctalia.tr("panel.peak", { peak = format.mbit(peak), at = clock(peakAt), since = clock(since) })
end

local function directionRow(glyph, labelKey, value, lineKey, peak, peakAt, since)
	local line = lineBytes(lineKey)
	local max = line > 0 and line or (tonumber(peak) or 0)
	local progress = max > 0 and math.max(0, math.min(1, value / max)) or 0
	local meta = format.mbit(value)
	if line > 0 then
		meta = meta .. " · " .. noctalia.tr("panel.of_line", { line = format.mbit(line) })
	end
	local lines = {
		ui.label({ text = noctalia.tr(labelKey), fontSize = 13, fontWeight = "medium", color = "on_surface" }),
		ui.label({ text = meta, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
	}
	local peakLine = peakText(peak, peakAt, since)
	if peakLine ~= nil then
		table.insert(lines, ui.label({ text = peakLine, fontSize = 11, color = "on_surface_variant", maxLines = 1 }))
	end
	return ui.column({ gap = 6 }, {
		ui.row({ align = "center", gap = 10 }, {
			ui.glyph({ name = glyph, size = 18, color = "primary" }),
			ui.column({ flexGrow = 1, gap = 1 }, lines),
			ui.label({ text = format.rate(value, "auto", false), fontSize = 13, color = "on_surface", textAlign = "end" }),
		}),
		ui.progress({ progress = progress, flexGrow = 1, radius = 3, height = 6 }),
	})
end

local function interfaceRow(iface)
	local selected = iface.id == snapshot.selected
	local meta = iface.id
	if iface.device ~= "" then
		meta = meta .. " · " .. iface.device
	end
	return ui.row({
		key = "iface-" .. iface.id,
		align = "center",
		gap = 10,
		paddingH = 8,
		paddingV = 6,
		radius = 8,
		fill = selected and "primary/0.12" or nil,
		tooltip = noctalia.tr("panel.copy_hint", { id = iface.id }),
		onClick = function()
			noctalia.copyToClipboard(iface.id)
		end,
	}, {
		ui.column({ flexGrow = 1, gap = 1 }, {
			ui.label({ text = iface.name, fontSize = 13, fontWeight = selected and "bold" or "medium", color = "on_surface", maxLines = 1 }),
			ui.label({ text = meta, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
		}),
		ui.label({ text = "↓ " .. format.rate(iface.rx, "auto", true), fontSize = 12, color = "on_surface", textAlign = "end" }),
		ui.row({ minWidth = 64, justify = "end" }, {
			ui.label({ text = "↑ " .. format.rate(iface.tx, "auto", true), fontSize = 12, color = "on_surface", textAlign = "end" }),
		}),
	})
end

local function render()
	local body = {}
	local err = tostring(snapshot.error or "")
	if err ~= "" then
		table.insert(body, ui.label({ text = err, fontSize = 12, color = "error" }))
	end
	if snapshot.selected ~= nil and snapshot.selected ~= "" then
		local history = snapshot.history or {}
		local title = tostring(snapshot.selectedName or snapshot.selected)
		if snapshot.selectedDevice ~= nil and snapshot.selectedDevice ~= "" then
			title = title .. " (" .. snapshot.selectedDevice .. ")"
		end
		table.insert(body, ui.label({ text = title, fontSize = 12, color = "on_surface_variant" }))
		table.insert(body, directionRow("download", "panel.download", tonumber(snapshot.rx) or 0, "line_down_mbit", history.peakRx, history.peakRxAt, history.since))
		table.insert(body, directionRow("upload", "panel.upload", tonumber(snapshot.tx) or 0, "line_up_mbit", history.peakTx, history.peakTxAt, history.since))
		local hold = tonumber(history.hold) or 0
		local holdText = hold > 0 and noctalia.trp("panel.hold_hours", hold) or noctalia.tr("panel.hold_unlimited")
		table.insert(body, ui.row({ align = "center", gap = 8 }, {
			ui.label({ text = holdText, fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 2 }),
			ui.button({
				text = noctalia.tr("panel.reset_peaks"),
				glyph = "rotate",
				fontSize = 11,
				glyphSize = 12,
				variant = "ghost",
				controlSize = "sm",
				onClick = "onResetPeaksClicked",
			}),
		}))
	end

	local interfaces = snapshot.interfaces or {}
	if #interfaces > 0 then
		table.insert(body, ui.separator({}))
		table.insert(body, ui.label({ text = noctalia.tr("panel.interfaces"), fontSize = 12, fontWeight = "medium", color = "on_surface_variant" }))
		local rows = {}
		for _, iface in ipairs(interfaces) do
			table.insert(rows, interfaceRow(iface))
		end
		table.insert(body, ui.column({ gap = 2 }, rows))
	end

	panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.glyph({ name = "router", size = 20, color = "primary" }),
			ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefreshClicked" }),
			ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
		}),
		ui.scroll({ flexGrow = 1, gap = 12 }, body),
	}))
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
	if type(value) == "table" then
		snapshot = value
		render()
	end
end)

function onOpen(_context)
	render()
end

function onResetPeaksClicked()
	noctalia.state.set(COMMAND_KEY, { action = "reset_peaks", nonce = tostring(noctalia.nowMs()) })
end

function onRefreshClicked()
	sendRefresh()
end

function onCloseClicked()
	panel.close()
end

render()
