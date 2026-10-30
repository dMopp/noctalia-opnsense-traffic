# noctalia-opnsense-traffic

Development repo for the Noctalia plugin [`dmopp/opnsense-traffic`](opnsense-traffic/README.md).

- `opnsense-traffic/` - the plugin, laid out for
  [noctalia-dev/community-plugins](https://github.com/noctalia-dev/community-plugins)
  (submit that directory as is).
- `i18n/de.json` - German strings. Community plugins ship `translations/en.json`
  only; other languages go through [Noctalia Translate](https://i18n.noctalia.dev),
  so enter these there once the plugin is merged.

Local use:

```sh
noctalia msg plugins source add opnsense-traffic-local path ~/coding-projects/noctalia-opnsense-traffic
noctalia msg plugins enable dmopp/opnsense-traffic
```

Tests (not part of the plugin directory):

```sh
nix shell nixpkgs#luau -c sh tests/run.sh
```

Written with help from Claude Code.
