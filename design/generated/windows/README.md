<!-- generated from design/tokens.json, do not edit. Run: node design/generate.mjs -->
# Windows (WinUI 3)

Everything here is generated. Do not edit it: change `design/tokens.json`, `design/components.json` or `design/strings/*.json` and run `node design/generate.mjs` (or `make tokens`). `node design/generate.mjs --check` fails when a file is out of date.

The language is Pebble: [docs/design](../../../docs/design/index.md). The components every platform builds the same way are in [docs/design/components.md](../../../docs/design/components.md).

## Files

| File | What it is |
| --- | --- |
| `ImpTokens.xaml` | Colours and brushes for Default (dark) and Light, spacing, radii, strokes, opacities, sizes, icon sizes, type, motion and behaviour numbers as resources |
| `ImpComponents.xaml` | The component specs as resources (`ImpPebbleRadius`, `ImpRowMinHeight`, ...) and styles (`ImpPebbleStyle`, `ImpButtonPrimaryStyle`, ...) |
| `ImpTokens.cs` | The same numbers as typed constants for code (`ImpSpace.Large`, `ImpMotion.Hover`) |
| `en-US`, `es`, `zh-Hans` `/Resources.resw` | Every word. A plural is two strings: `key.one` and `key.other`. Pick with the count |

## Use

1. Merge both dictionaries in `App.xaml`: `ImpTokens.xaml` first, then `ImpComponents.xaml`.
2. Set the window background with `{ThemeResource ImpSurfaceBrush}`. Text is `ImpTextBrush`. Never write a hex colour in a view.
3. A group is `<Border Style="{StaticResource ImpPebbleStyle}">`. A button is `Style="{StaticResource ImpButtonPrimaryStyle}"`. They have no outline and no divider.
4. Animations: use the `ImpMotion<Name>Duration` and `...Easing` (a KeySpline string) resources, and the `...ReducedDuration` one when `UISettings.AnimationsEnabled` is false.
5. Read strings with `ResourceLoader.GetString("home.title")`. The .resw files are neutral: add `en-US`, `es` and `zh-Hans` as the app's languages in the project.
6. The type is rounded on Apple platforms. On Windows use Segoe UI Variable with its rounded optical size where available, or a bundled rounded face, for every style.
7. Hit areas are at least `ImpSizes.Hit` (32 px, 40 px for touch).
