<!-- generated from design/tokens.json, do not edit. Run: node design/generate.mjs -->
# Linux (GTK 4 and libadwaita)

Everything here is generated. Do not edit it: change `design/tokens.json`, `design/components.json` or `design/strings/*.json` and run `node design/generate.mjs` (or `make tokens`). `node design/generate.mjs --check` fails when a file is out of date.

The language is Pebble: [docs/design](../../../docs/design/index.md). The components every platform builds the same way are in [docs/design/components.md](../../../docs/design/components.md).

## Files

| File | What it is |
| --- | --- |
| `imp-colors-dark.css`, `imp-colors-light.css` | `@define-color` for libadwaita's named colours (window, card, popover, accent, ...) and for every token as `@imp_<name>` |
| `imp-tokens.css` | Spacing, radii, sizes, icons and type as `--imp-*` custom properties (GTK 4.16 or newer) and one `.imp-motion-<name>` class per animation |
| `imp-components.css` | One class per component: `.imp-pebble`, `.imp-row`, `.imp-button-primary`, ... with the values filled in |
| `../gettext/imp.pot`, `es.po`, `zh_Hans.po` | Every word. The message context is the key (`msgctxt`), the message id is the English text |

## Use

1. Load `imp-colors-dark.css` or `imp-colors-light.css` with `Gtk.CssProvider` at `STYLE_PROVIDER_PRIORITY_APPLICATION`, following `Adw.StyleManager.get_dark()`, and swap the provider when it changes. Then load `imp-tokens.css` and `imp-components.css`.
2. Add the class to a widget: `box.add_css_class("imp-pebble")`. Never write a colour in the app's own CSS: use `@imp_card`, `@imp_text`, `@imp_muted`.
3. Compile the catalogs with `msgfmt` into `locale/<lang>/LC_MESSAGES/imp.mo` and read words with `pgettext(key, english)` (`GLib.dpgettext2`).
4. Reduce Motion is `gtk-enable-animations = false`: GTK then skips the transitions by itself.
5. The type is rounded on Apple platforms. On Linux use "Cantarell" or a bundled rounded face for every style.
