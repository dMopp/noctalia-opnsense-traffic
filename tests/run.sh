#!/bin/sh
# Runs tests/plugin.luau against the real plugin files, from the repo root:
#   nix shell nixpkgs#luau -c sh tests/run.sh
# The luau CLI keeps _G read-only, so the plugin cannot see a stubbed noctalia
# table through its own require. This bundles modules and tests into one chunk.
set -eu
bundle=$(mktemp --suffix=.luau)
trap 'rm -f "$bundle"' EXIT
{
	echo 'local __modules, __loaded, require = {}, {}, nil'
	echo 'local clockMs = 1000000'
	echo 'local os = { time = function() return math.floor(clockMs / 1000) end }'
	for f in opnsense-traffic/lib/*.luau opnsense-traffic/service.luau opnsense-traffic/widget.luau opnsense-traffic/panel.luau; do
		name=$(basename "$f" .luau)
		echo "__modules[\"$name\"] = function()"
		cat "$f"
		echo 'end'
	done
	cat <<'LUA'
require = function(path)
	local name = path:match("([^/]+)%.luau$")
	if __loaded[name] == nil then
		__loaded[name] = __modules[name]() or true
	end
	return __loaded[name]
end
LUA
	cat tests/plugin.luau
} >"$bundle"
luau "$bundle"
