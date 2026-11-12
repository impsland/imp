<!-- generated from design/tokens.json, do not edit. Run: node design/generate.mjs -->
# Android

Everything here is generated. Do not edit it: change `design/tokens.json`, `design/components.json` or `design/strings/*.json` and run `node design/generate.mjs` (or `make tokens`). `node design/generate.mjs --check` fails when a file is out of date.

The language is Pebble: [docs/design](../../../docs/design/index.md). The components every platform builds the same way are in [docs/design/components.md](../../../docs/design/components.md).

## Files

| File | What it is |
| --- | --- |
| `ImpTheme.kt` | Palettes (`ImpDarkPalette`, `ImpLightPalette`), `ImpSpacing`, `ImpRadius`, `ImpStroke`, `ImpOpacity`, `ImpSizing`, `ImpIcon`, `ImpType`, `ImpShadows`, `ImpMotions`, `ImpBehavior` and the `ImpTheme` composable |
| `ImpComponents.kt` | `ImpComponents.Pebble`, `.Row`, `.ButtonPrimary`, ...: each spec as typed values |
| `values/strings.xml`, `values-es`, `values-b+zh+Hans` | Every word, by key with dots turned into underscores (`home.title` is `R.string.home_title`). Plurals are `<plurals>` |

## Use

1. Copy the Kotlin files into the module's `app/imp/design` package and the `values*` folders into `src/main/res`.
2. Wrap the app in `ImpTheme { ... }`. It picks the dark or light palette from the system and offers it as `LocalImpPalette.current`.
3. Read colours as `LocalImpPalette.current.card`, never as a literal. Sizes, spacing and radii are `Dp` values: `ImpSpacing.large`.
4. Build components from `ImpComponents`: `Modifier.background(ImpComponents.Pebble.fill(palette), RoundedCornerShape(ImpComponents.Pebble.radius))`. A colour in a spec is a function of the palette.
5. Animate with `ImpMotions.hover.spec(reduceMotion)`. Read Reduce Motion from the system's animator duration scale being 0.
6. The type scale is rounded on Apple platforms. Android has no system rounded face: `ImpTextStyle.design` says "rounded", so bundle a rounded family (for example Google Sans Rounded or Nunito) and use it for every style.
7. Text sizes are `sp` and follow the system font scale. Hit areas are at least `ImpSizing.hit` (48 dp).
