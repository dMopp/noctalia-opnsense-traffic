# OPNsense Traffic

Shows the download and upload rate of one OPNsense interface in the Noctalia
bar. The widget looks and behaves like the built-in `network_rx` /
`network_tx` widgets: glyph, gauge or graph, value, same units and the same
highlight gradient. A left-click opens a panel with both directions against the
line speed and the live rates of every interface on the firewall.

## Plugin

| Field | Value |
| --- | --- |
| ID | `dmopp/opnsense-traffic` |
| Entries | Bar widget: `traffic`; panel: `panel`; service: `service` |
| API calls | `GET /api/diagnostics/traffic/interface` (every poll), `GET /api/interfaces/overview/interfaces_info` (auto-detect only, every 10 min) |

The service reads the byte counters of all interfaces and turns the difference
between two polls into a rate. Counters that go backwards (firewall reboot,
interface re-attached) are skipped for one sample.

## Creating the API key

The plugin only reads. Give it its own user with exactly these privileges, not
an admin key.

1. **System → Access → Users → +** (Add).
   - Username: e.g. `noctalia-traffic`
   - Password: tick **Generate a scrambled password** - the user never logs in
     to the web GUI.
   - Description: e.g. `Noctalia traffic widget (read-only)`
   - Leave group membership empty (no `admins`).
2. In the same dialog, field **Privileges**, select:
   - **Reporting: Traffic** - required (`api/diagnostics/traffic/*`).
   - **Status: Interfaces** - only for auto-detect
     (`api/interfaces/overview/*`). Leave it out when you set the interface by
     hand.
   Save.
3. **API keys → +** on the same user. OPNsense downloads a file
   `<hostname>_<user>_apikey.txt` with two lines, `key=…` and `secret=…`. The
   secret is shown only this once.
4. Put that file where the plugin looks for it and lock it down:

   ```sh
   mkdir -p ~/.config/noctalia-opnsense
   mv ~/Downloads/*_noctalia-traffic_apikey.txt ~/.config/noctalia-opnsense/apikey.txt
   chmod 600 ~/.config/noctalia-opnsense/apikey.txt
   ```

5. Check it - the first call must answer 200, the second 403:

   ```sh
   f=~/.config/noctalia-opnsense/apikey.txt
   u="$(sed -n 's/^key=//p' $f):$(sed -n 's/^secret=//p' $f)"
   curl -s -o /dev/null -w '%{http_code}\n' -u "$u" https://opnsense.lan/api/diagnostics/traffic/interface
   curl -s -o /dev/null -w '%{http_code}\n' -u "$u" https://opnsense.lan/api/core/firmware/status
   ```

The key lives only in that file. It is never stored in the Noctalia settings,
so it does not end up in `settings.toml` or in anything exported from it.

The same steps over the API (with an admin key), if you prefer that:

```sh
curl -u "$ADMIN" -X POST -H 'Content-Type: application/json' \
  https://opnsense.lan/api/auth/user/add \
  -d '{"user":{"name":"noctalia-traffic","scrambled_password":"1","priv":"page-status-trafficgraph,page-status-interfaces"}}'
curl -u "$ADMIN" -X POST https://opnsense.lan/api/auth/user/add_api_key/noctalia-traffic
```

`add_api_key` takes the user name, not the UUID, and returns `key` and
`secret` as JSON.

## Settings

Plugin settings (Settings → Plugins → gear on the row):

| Setting | Default | Meaning |
| --- | --- | --- |
| OPNsense URL | - | Base URL of the web GUI incl. port, e.g. `https://opnsense.lan:4443` |
| API key file | `~/.config/noctalia-opnsense/apikey.txt` | `key=`/`secret=` file from step 3 |
| Interface | - | Identifier (`opt1`), description (`WAN`) or device (`pppoe0`), case-insensitive. The panel lists all of them; click a row to copy its identifier. |
| Detect WAN automatically | off | Only used while *Interface* is empty: takes the interface that carries the default route. Needs **Status: Interfaces**. |
| Refresh interval | 2 s | Time between two API calls |
| Line speed down / up | 0 | Bandwidth of your line in Mbit/s (e.g. from the provider contract). Scales gauge and graph and turns on the highlight. 0 scales to the highest rate seen and never highlights. |
| Highlight from / full at | 50 % / 90 % | Share of the line speed where the value starts fading to the highlight color and where it reaches it. |
| Allow untrusted certificate | off | Advanced. Skips certificate checks - only for a self-signed GUI certificate. |

Widget settings (per bar widget, like the built-in network widgets):
direction (download/upload), unit, compact, visualization (gauge/graph/none),
show value, show units, minimum value width, show glyph, glyph, glyph position,
highlight color.

Download and upload are seen from the firewall interface: on the WAN interface
"bytes received" is your download. On a LAN/VLAN interface the directions are
the other way round (traffic received from clients is their upload).

## Usage

Add the widget `dmopp/opnsense-traffic:traffic` twice to a bar, one with
direction *Download*, one with *Upload*:

```toml
[widget.opnsense_rx]
type = "dmopp/opnsense-traffic:traffic"
direction = "download"

[widget.opnsense_tx]
type = "dmopp/opnsense-traffic:traffic"
direction = "upload"
```

```sh
noctalia msg panel-toggle dmopp/opnsense-traffic:panel
noctalia msg plugin dmopp/opnsense-traffic:service all refresh
```

Errors (no URL, key file missing, HTTP 401/403, unknown interface) show `--`
in the bar and the reason in the tooltip and the panel.

## Local development

```sh
noctalia msg plugins source add opnsense-traffic-local path ~/coding-projects/noctalia-opnsense-traffic
noctalia msg plugins enable dmopp/opnsense-traffic
```

`.luau` edits hot-reload; manifest changes need `noctalia msg config-reload`.

Written with help from Claude Code.
