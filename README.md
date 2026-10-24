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

Still missing for the submission: `opnsense-traffic/thumbnail.webp` (960×540, from the
[thumbnail generator](https://assets.noctalia.dev/plugins/thumbnail-generator.html)).

Written with help from Claude Code.
