#!/usr/bin/env node
// Generates every platform's design tokens and user-facing strings from the two sources in this folder:
//
//   design/tokens.json     colours, spacing, radii, type, sizes, motion, behaviour numbers
//   design/strings/*.json  every word a user reads, one stable key each, in en, es and zh-Hans
//   spec/animations/catalog.json  the animations, of which the five marked bundled are cut into the Apple kit
//   spec/presets/*.json    the starter kit and the service presets, compiled into the Apple kit
//
//   node design/generate.mjs          write the generated files
//   node design/generate.mjs --check  write nothing, exit 1 when a generated file is out of date
//
// No dependencies. Needs Node 20 or newer.

import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const check = process.argv.includes('--check')
const LANGS = ['en', 'es', 'zh-Hans']
const SOURCE_NOTE = 'generated from design/tokens.json, do not edit. Run: node design/generate.mjs'
const STRINGS_NOTE = 'generated from design/strings, do not edit. Run: node design/generate.mjs'

const read = (path) => readFileSync(join(root, path), 'utf8')
const fail = (message) => {
  console.error(`generate.mjs: ${message}`)
  process.exit(2)
}

// ---------------------------------------------------------------- helpers

const words = (name) => name.replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase().split(' ')
const kebab = (name) => words(name).join('-')
const pascal = (name) => words(name).map((w) => w[0].toUpperCase() + w.slice(1)).join('')
const camel = (name) => { const p = pascal(name); return p[0].toLowerCase() + p.slice(1) }
const num = (n) => String(n)

function parseColor(hex) {
  const m = /^#([0-9a-f]{6})([0-9a-f]{2})?$/i.exec(hex)
  if (!m) fail(`bad colour ${hex}`)
  const v = parseInt(m[1], 16)
  return { r: (v >> 16) & 255, g: (v >> 8) & 255, b: v & 255, a: m[2] ? parseInt(m[2], 16) : 255 }
}
const alpha = (c) => Math.round((c.a / 255) * 1000) / 1000
const hex2 = (n) => n.toString(16).padStart(2, '0')
const cssColor = (hex) => {
  const c = parseColor(hex)
  return c.a === 255 ? `#${hex2(c.r)}${hex2(c.g)}${hex2(c.b)}` : `rgba(${c.r}, ${c.g}, ${c.b}, ${alpha(c)})`
}
const argb = (hex) => { const c = parseColor(hex); return `${hex2(c.a)}${hex2(c.r)}${hex2(c.g)}${hex2(c.b)}`.toUpperCase() }

const CURVES = {
  easeOut: [0, 0, 0.58, 1],
  easeInOut: [0.42, 0, 0.58, 1],
  snappy: [0.2, 0.9, 0.3, 1],
  spring: [0.2, 0.8, 0.2, 1],
  springBouncy: [0.34, 1.56, 0.64, 1],
}

// ---------------------------------------------------------------- tokens

const tokens = JSON.parse(read('design/tokens.json'))
const colorNames = Object.keys(tokens.colors)
const duration = (value) => {
  if (typeof value === 'number') return value
  const d = tokens.duration[value]
  if (!d) fail(`unknown duration ${value}`)
  return d.value
}
const presets = Object.entries(tokens.motion.presets).map(([name, p]) => ({
  name,
  curve: p.curve === 'spring' && (p.bounce ?? 0) > 0 ? 'springBouncy' : p.curve,
  swiftCurve: p.curve,
  seconds: duration(p.duration),
  bounce: p.bounce ?? 0,
  reduced: p.reduced,
  doc: p.doc,
}))
const reducedFade = tokens.motion.reducedFade.value
const platformKeys = ['ios', 'android', 'macos', 'windows', 'linux']
const sizes = Object.entries(tokens.size)
const types = Object.entries(tokens.type)
const WEIGHTS = { 400: 'regular', 500: 'medium', 600: 'semibold', 700: 'bold', 800: 'heavy' }
const behavior = Object.entries(tokens.behavior)
const strokes = Object.entries(tokens.stroke)
const opacities = Object.entries(tokens.opacity)
const icons = Object.entries(tokens.icon)

function swiftTokens() {
  const color = (hex) => {
    const c = parseColor(hex)
    const base = `Color(red: ${c.r} / 255, green: ${c.g} / 255, blue: ${c.b} / 255)`
    return c.a === 255 ? base : `${base}.opacity(${alpha(c)})`
  }
  const doc = (text, indent = '    ') => (text ? `${indent}/// ${text}\n` : '')
  let s = `// ${SOURCE_NOTE}\n\nimport SwiftUI\n#if canImport(UIKit)\nimport UIKit\n#elseif canImport(AppKit)\nimport AppKit\n#endif\n\n`
  const rgba = (hex) => { const c = parseColor(hex); return `(${c.r}, ${c.g}, ${c.b}, ${alpha(c)})` }
  s += `/// The palette. A colour that differs between Light and Dark follows the appearance of the view it is drawn in.\npublic enum Tone {\n`
  for (const [name, c] of Object.entries(tokens.colors)) {
    s += `${doc(c.doc)}    public static let ${name} = ${c.dark === c.light ? color(c.dark) : `Color(light: ${rgba(c.light)}, dark: ${rgba(c.dark)})`}\n`
  }
  s += `}\n\n`
  s += `extension Color {
    /// A colour with a value for Light and one for Dark (red, green and blue in 0...255, alpha in 0...1).
    init(light: (Double, Double, Double, Double), dark: (Double, Double, Double, Double)) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: c.3)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: c.3)
        })
        #endif
    }
}\n\n`
  s += `/// How a floating thing lifts off the surface.\npublic enum Elevation {\n`
  for (const [name, e] of Object.entries(tokens.shadows)) {
    s += `${doc(e.doc)}    public static let ${name}Y: CGFloat = ${e.y}\n    public static let ${name}Blur: CGFloat = ${e.blur}\n    public static let ${name}Color = Color(light: ${rgba(e.color.light)}, dark: ${rgba(e.color.dark)})\n`
  }
  s += `}\n\n`
  for (const [title, group, text] of [['Radius', tokens.radius, 'Corner radii, one scale for everything.'], ['Spacing', tokens.spacing, 'Spacing, one scale for gaps and padding.'], ['Stroke', tokens.stroke, 'Line widths.']]) {
    s += `/// ${text}\npublic enum ${title} {\n`
    for (const [name, t] of Object.entries(group)) s += `${doc(t.doc)}    public static let ${name}: CGFloat = ${t.value}\n`
    s += `}\n\n`
  }
  s += `/// Opacities, one scale for dimming and soft fills.\npublic enum Opacity {\n`
  for (const [name, t] of opacities) s += `${doc(t.doc)}    public static let ${name}: Double = ${t.value}\n`
  s += `}\n\n`
  s += `/// Sizes of things you point at.\npublic enum Sizing {\n`
  for (const [name, t] of sizes) {
    s += `${doc(t.doc)}    public static var ${name}: CGFloat {\n        #if os(iOS)\n        ${t.ios}\n        #else\n        ${t.macos}\n        #endif\n    }\n\n`
  }
  s = s.replace(/\n\n$/, '\n') + `}\n\n`
  s += `/// The type scale, as named styles. \`Typeface\` turns them into fonts.\npublic enum TypeScale {\n`
  for (const [name, t] of types) {
    const design = t.design === 'mono' ? '.monospaced' : `.${t.design}`
    s += `${doc(t.doc)}    public static let ${name} = TypeToken(size: ${t.size}, weight: .${WEIGHTS[t.weight]}, design: ${design}, style: .${t.appleStyle})\n`
  }
  s += `}\n\n`
  s += `/// Icon sizes. On the iPhone an icon follows Dynamic Type with its text style, on the Mac it is a fixed size.\npublic enum IconSize: Sendable {\n`
  for (const [name, t] of icons) s += `${doc(t.doc)}    case ${name}\n`
  s += `\n    /// The size in points on the Mac, and at the default text size on the iPhone.\n    public var points: CGFloat {\n        switch self {\n`
  for (const [name, t] of icons) s += `        case .${name}: ${t.size}\n`
  s += `        }\n    }\n\n    /// The text style the icon grows with on the iPhone.\n    public var textStyle: Font.TextStyle {\n        switch self {\n`
  for (const [name, t] of icons) s += `        case .${name}: .${t.appleStyle}\n`
  s += `        }\n    }\n}\n\n`
  s += `/// How long things animate.\npublic enum Timing {\n`
  for (const [name, d] of Object.entries(tokens.duration)) s += `${doc(d.doc)}    public static let ${name} = ${d.value}\n`
  s += `    /// With Reduce Motion, a preset that fades changes opacity over this long.\n    public static let reducedFade = ${reducedFade}\n}\n\n`
  s += `/// The named animations, with what each does when Reduce Motion is on.\npublic enum Motion {\n`
  for (const p of presets) {
    const anim = p.swiftCurve === 'spring' ? `.spring(duration: ${p.seconds}, bounce: ${p.bounce})` : `.${p.swiftCurve}(duration: ${p.seconds})`
    const reduced = p.reduced === 'fade' ? '.easeOut(duration: Timing.reducedFade)' : 'nil'
    s += `${doc(p.doc)}    public static let ${p.name} = MotionPreset(${anim}, reduced: ${reduced})\n`
  }
  s += `}\n\n`
  s += `/// Numbers that behaviour rules share on every platform.\npublic enum Behavior {\n`
  for (const [name, b] of behavior) s += `${doc(b.doc)}    public static let ${name} = ${b.value}\n`
  s += `}\n`
  return s
}

function webCss() {
  const block = (mode) => {
    let s = ''
    for (const name of colorNames) s += `  --${kebab(name)}: ${cssColor(tokens.colors[name][mode])};\n`
    for (const [name, e] of Object.entries(tokens.shadows)) s += `  --shadow-${kebab(name)}: 0 ${e.y}px ${e.blur}px ${cssColor(e.color[mode])};\n`
    return s
  }
  let s = `/* ${SOURCE_NOTE} */\n:root {\n  color-scheme: dark;\n${block('dark')}`
  for (const [name, t] of Object.entries(tokens.spacing)) s += `  --space-${kebab(name)}: ${t.value}px;\n`
  for (const [name, t] of Object.entries(tokens.radius)) s += `  --radius-${kebab(name)}: ${t.value}px;\n`
  for (const [name, t] of strokes) s += `  --stroke-${kebab(name)}: ${t.value}px;\n`
  for (const [name, t] of opacities) s += `  --opacity-${kebab(name)}: ${t.value};\n`
  for (const [name, t] of sizes) s += `  --size-${kebab(name)}: ${t.macos}px;\n`
  for (const [name, t] of icons) s += `  --icon-${kebab(name)}: ${t.size}px;\n`
  for (const [name, t] of types) s += `  --type-${kebab(name)}-size: ${t.size}px;\n  --type-${kebab(name)}-weight: ${t.weight};\n`
  for (const [name, d] of Object.entries(tokens.duration)) s += `  --duration-${kebab(name)}: ${d.value}s;\n`
  for (const p of presets) s += `  --motion-${kebab(p.name)}: ${p.seconds}s cubic-bezier(${CURVES[p.curve].join(', ')});\n`
  for (const [name, b] of behavior) s += `  --behavior-${kebab(name)}: ${b.value};\n`
  s += `}\n@media (prefers-color-scheme: light) {\n  :root {\n    color-scheme: light;\n`
  s += block('light').replace(/^/gm, '  ').replace(/ +$/gm, '')
  s += `  }\n}\n@media (prefers-reduced-motion: reduce) {\n  :root {\n`
  for (const p of presets) s += `    --motion-${kebab(p.name)}: ${p.reduced === 'fade' ? `${reducedFade}s ease-out` : '0s linear'};\n`
  s += `  }\n}\n`
  return s
}

function kotlinTokens() {
  const color = (hex) => `Color(0x${argb(hex)})`
  const f = (n) => `${num(n)}f`
  let s = `// ${SOURCE_NOTE}\npackage app.imp.design\n\n`
  s += `import androidx.compose.animation.core.CubicBezierEasing\nimport androidx.compose.animation.core.TweenSpec\nimport androidx.compose.animation.core.tween\n`
  s += `import android.provider.Settings\nimport androidx.compose.foundation.isSystemInDarkTheme\nimport androidx.compose.runtime.Composable\nimport androidx.compose.runtime.CompositionLocalProvider\nimport androidx.compose.runtime.remember\nimport androidx.compose.runtime.staticCompositionLocalOf\n`
  s += `import androidx.compose.ui.graphics.Color\nimport androidx.compose.ui.platform.LocalContext\nimport androidx.compose.ui.text.font.FontWeight\nimport androidx.compose.ui.unit.Dp\nimport androidx.compose.ui.unit.dp\nimport androidx.compose.ui.unit.sp\n\n`
  s += `/** The colours of one appearance. */\nclass ImpPalette(\n`
  s += colorNames.map((n) => `    val ${n}: Color,`).join('\n') + `\n)\n\n`
  for (const mode of ['dark', 'light']) {
    s += `val Imp${pascal(mode)}Palette = ImpPalette(\n`
    s += colorNames.map((n) => `    ${n} = ${color(tokens.colors[n][mode])},`).join('\n') + `\n)\n\n`
  }
  s += `/** The palette of the current appearance. Read colours from here, never as a literal. */\nval LocalImpPalette = staticCompositionLocalOf { ImpDarkPalette }\n\n`
  s += `/** Gives everything inside the right palette: dark or light, following the system unless told. */\n@Composable\nfun ImpTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {\n    CompositionLocalProvider(LocalImpPalette provides if (dark) ImpDarkPalette else ImpLightPalette, content = content)\n}\n\n`
  s += `/** True when the person turned animations off in the system settings (Reduce Motion). */\n@Composable\nfun rememberReduceMotion(): Boolean {\n    val resolver = LocalContext.current.contentResolver\n    return remember { Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }\n}\n\n`
  s += `/** How a floating thing lifts off the surface. */\nclass ImpShadow(val y: Dp, val blur: Dp, val dark: Color, val light: Color) {\n    fun color(isDark: Boolean) = if (isDark) dark else light\n}\n\n`
  s += `object ImpShadows {\n` + Object.entries(tokens.shadows).map(([n, e]) => `    val ${n} = ImpShadow(${e.y}.dp, ${e.blur}.dp, ${color(e.color.dark)}, ${color(e.color.light)})`).join('\n') + `\n}\n\n`
  s += `object ImpSpacing {\n` + Object.entries(tokens.spacing).map(([n, t]) => `    val ${n} = ${t.value}.dp`).join('\n') + `\n}\n\n`
  s += `object ImpRadius {\n` + Object.entries(tokens.radius).map(([n, t]) => `    val ${n} = ${t.value}.dp`).join('\n') + `\n}\n\n`
  s += `object ImpStroke {\n` + strokes.map(([n, t]) => `    val ${n} = ${t.value}.dp`).join('\n') + `\n}\n\n`
  s += `object ImpOpacity {\n` + opacities.map(([n, t]) => `    const val ${n} = ${t.value}f`).join('\n') + `\n}\n\n`
  s += `object ImpSizing {\n` + sizes.map(([n, t]) => `    /** ${t.doc} */\n    val ${n} = ${t.android}.dp`).join('\n') + `\n}\n\n`
  s += `/** Icon sizes (dp at the default font scale). */\nobject ImpIcon {\n` + icons.map(([n, t]) => `    val ${n} = ${t.size}.dp`).join('\n') + `\n}\n\n`
  s += `/** One text style: size in sp (the phone size follows the system font scale), weight and design. */\n`
  s += `class ImpTextStyle(val size: androidx.compose.ui.unit.TextUnit, val weight: FontWeight, val design: String)\n\n`
  s += `object ImpType {\n` + types.map(([n, t]) => `    val ${n} = ImpTextStyle(${t.phoneSize}.sp, FontWeight(${t.weight}), "${t.design}")`).join('\n') + `\n}\n\n`
  s += `/** One animation. With Reduce Motion it takes \`reducedDurationMillis\` (0 means it just happens). */\n`
  s += `class ImpMotion(val durationMillis: Int, val easing: CubicBezierEasing, val reducedDurationMillis: Int) {\n`
  s += `    fun <T> spec(reduceMotion: Boolean): TweenSpec<T> =\n        tween(if (reduceMotion) reducedDurationMillis else durationMillis, easing = easing)\n}\n\n`
  s += `object ImpMotions {\n`
  for (const p of presets) {
    const [a, b, c, d] = CURVES[p.curve]
    s += `    val ${p.name} = ImpMotion(${Math.round(p.seconds * 1000)}, CubicBezierEasing(${f(a)}, ${f(b)}, ${f(c)}, ${f(d)}), ${p.reduced === 'fade' ? Math.round(reducedFade * 1000) : 0})\n`
  }
  s += `}\n\nobject ImpBehavior {\n` + behavior.map(([n, b]) => `    val ${n} = ${b.value}${Number.isInteger(b.value) ? '' : 'f'}`).join('\n') + `\n}\n`
  return s
}

function xamlTokens() {
  const weight = { 400: 'Normal', 500: 'Medium', 600: 'SemiBold', 700: 'Bold', 800: 'ExtraBold' }
  const theme = (key, mode) => {
    let s = `    <ResourceDictionary x:Key="${key}">\n`
    for (const n of colorNames) {
      const c = `#${argb(tokens.colors[n][mode])}`
      s += `      <Color x:Key="Imp${pascal(n)}Color">${c}</Color>\n      <SolidColorBrush x:Key="Imp${pascal(n)}Brush" Color="${c}"/>\n`
    }
    return s + `    </ResourceDictionary>\n`
  }
  const dur = (sec) => `0:0:${sec}`
  let s = `<?xml version="1.0" encoding="utf-8"?>\n<!-- ${SOURCE_NOTE} -->\n`
  s += `<ResourceDictionary\n    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"\n    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">\n\n`
  s += `  <ResourceDictionary.ThemeDictionaries>\n${theme('Default', 'dark')}${theme('Light', 'light')}  </ResourceDictionary.ThemeDictionaries>\n\n`
  for (const [n, t] of Object.entries(tokens.spacing)) s += `  <x:Double x:Key="ImpSpace${pascal(n)}">${t.value}</x:Double>\n`
  for (const [n, t] of Object.entries(tokens.radius)) s += `  <CornerRadius x:Key="ImpRadius${pascal(n)}">${t.value}</CornerRadius>\n`
  for (const [n, t] of strokes) s += `  <x:Double x:Key="ImpStroke${pascal(n)}">${t.value}</x:Double>\n`
  for (const [n, t] of opacities) s += `  <x:Double x:Key="ImpOpacity${pascal(n)}">${t.value}</x:Double>\n`
  for (const [n, t] of sizes) s += `  <x:Double x:Key="ImpSize${pascal(n)}">${t.windows}</x:Double>\n`
  for (const [n, t] of icons) s += `  <x:Double x:Key="ImpIcon${pascal(n)}">${t.size}</x:Double>\n`
  for (const [n, t] of types) s += `  <x:Double x:Key="ImpType${pascal(n)}Size">${t.size}</x:Double>\n  <FontWeight x:Key="ImpType${pascal(n)}Weight">${weight[t.weight]}</FontWeight>\n`
  for (const p of presets) {
    s += `  <Duration x:Key="ImpMotion${pascal(p.name)}Duration">${dur(p.seconds)}</Duration>\n`
    s += `  <Duration x:Key="ImpMotion${pascal(p.name)}ReducedDuration">${dur(p.reduced === 'fade' ? reducedFade : 0)}</Duration>\n`
    s += `  <x:String x:Key="ImpMotion${pascal(p.name)}Easing">${CURVES[p.curve].join(',')}</x:String>\n`
  }
  for (const [n, b] of behavior) s += `  <x:Double x:Key="ImpBehavior${pascal(n)}">${b.value}</x:Double>\n`
  return s + `</ResourceDictionary>\n`
}

/** GTK has no light/dark media rule before 4.20, so each appearance is its own file: load the one that matches AdwStyleManager. */
function gtkColors(mode) {
  const c = (hex) => cssColor(hex)
  const k = (n) => tokens.colors[n][mode]
  // The libadwaita named colours that carry the look, then every token under its own name.
  const adw = {
    window_bg_color: k('surface'), window_fg_color: k('text'),
    view_bg_color: k('surface'), view_fg_color: k('text'),
    headerbar_bg_color: k('surface'), headerbar_fg_color: k('text'), headerbar_border_color: 'transparent',
    card_bg_color: k('card'), card_fg_color: k('text'),
    popover_bg_color: k('raised'), popover_fg_color: k('text'),
    dialog_bg_color: k('surface'), dialog_fg_color: k('text'),
    sidebar_bg_color: k('surface'), sidebar_fg_color: k('text'),
    accent_bg_color: k('accent'), accent_fg_color: k('onAccent'), accent_color: k('accent'),
    destructive_bg_color: k('danger'), destructive_fg_color: k('ink'), destructive_color: k('danger'),
    success_color: k('good'), warning_color: k('warnText'), error_color: k('danger'),
  }
  let s = `/* ${SOURCE_NOTE} */\n/* ${mode}: libadwaita named colours first, then every token as @imp_<name>. */\n`
  for (const [n, v] of Object.entries(adw)) s += `@define-color ${n} ${v === 'transparent' ? v : c(v)};\n`
  for (const n of colorNames) s += `@define-color imp_${n.replace(/[A-Z]/g, (m) => '_' + m.toLowerCase())} ${c(k(n))};\n`
  for (const [n, e] of Object.entries(tokens.shadows)) s += `@define-color imp_shadow_${n} ${c(e.color[mode])};\n`
  return s
}

function gtkCss() {
  let s = `/* ${SOURCE_NOTE} */\n/* The numbers, as CSS custom properties (GTK 4.16 or newer). Colours are in imp-colors-dark.css and imp-colors-light.css. */\n:root {\n`
  for (const [n, t] of Object.entries(tokens.spacing)) s += `  --imp-space-${kebab(n)}: ${t.value}px;\n`
  for (const [n, t] of Object.entries(tokens.radius)) s += `  --imp-radius-${kebab(n)}: ${t.value}px;\n`
  for (const [n, t] of strokes) s += `  --imp-stroke-${kebab(n)}: ${t.value}px;\n`
  for (const [n, t] of opacities) s += `  --imp-opacity-${kebab(n)}: ${t.value};\n`
  for (const [n, t] of sizes) s += `  --imp-size-${kebab(n)}: ${t.linux}px;\n`
  for (const [n, t] of icons) s += `  --imp-icon-${kebab(n)}: ${t.size}px;\n`
  for (const [n, t] of types) s += `  --imp-type-${kebab(n)}-size: ${t.size}px;\n  --imp-type-${kebab(n)}-weight: ${t.weight};\n`
  s += `}\n\n/* One class per animation: duration and curve. With Reduce Motion (gtk-enable-animations off) GTK skips transitions. */\n`
  for (const p of presets) s += `.imp-motion-${kebab(p.name)} { transition-duration: ${Math.round(p.seconds * 1000)}ms; transition-timing-function: cubic-bezier(${CURVES[p.curve].join(', ')}); }\n`
  return s
}

// ---------------------------------------------------------------- strings

function loadStrings() {
  const dir = join(root, 'design/strings')
  const files = readdirSync(dir).filter((f) => f.endsWith('.json')).sort()
  const all = new Map()
  for (const file of files) {
    const entries = JSON.parse(readFileSync(join(dir, file), 'utf8'))
    for (const [key, e] of Object.entries(entries)) {
      if (!/^[a-z0-9_]+(\.[a-z0-9_]+)+$/.test(key)) fail(`${file}: bad key ${key}`)
      if (all.has(key)) fail(`${file}: duplicate key ${key}`)
      all.set(key, { ...e, file })
    }
  }
  const sorted = [...all.entries()].sort(([a], [b]) => (a < b ? -1 : 1))
  const placeholders = (text) => [...text.matchAll(/\{([a-z_]+)\}/g)].map((m) => m[1])
  for (const [key, e] of sorted) {
    const args = e.args ?? {}
    for (const [a, type] of Object.entries(args)) if (!['string', 'int'].includes(type)) fail(`${key}: argument ${a} has type ${type}`)
    const plural = typeof e.en === 'object'
    if (plural && !Object.values(args).includes('int')) fail(`${key}: a plural needs an int argument`)
    for (const lang of LANGS) {
      const v = e[lang]
      if (v === undefined || v === '') fail(`${key}: missing ${lang}`)
      if ((typeof v === 'object') !== plural) fail(`${key}: ${lang} must ${plural ? 'be' : 'not be'} plural`)
      for (const text of plural ? Object.values(v) : [v]) {
        for (const p of placeholders(text)) if (!(p in args)) fail(`${key}: ${lang} uses {${p}} which is not in args`)
        if (/\s\u2014|\u2014/.test(text) || /;/.test(text)) fail(`${key}: ${lang} has a long dash or semicolon`)
      }
      if (!plural) {
        const used = new Set(placeholders(v))
        for (const a of Object.keys(args)) if (!used.has(a)) fail(`${key}: ${lang} does not use {${a}}`)
      } else if (!('other' in v)) fail(`${key}: ${lang} needs an "other" form`)
    }
    if (typeof e.note !== 'string' || !e.note) fail(`${key}: add a note for translators`)
  }
  return new Map(sorted)
}

const terminalStrings = loadStrings()
// The terminal app's words (cli.*) go to its own table only, and no other platform lists them.
const strings = new Map([...terminalStrings].filter(([key]) => !key.startsWith('cli.')))
const argList = (e) => Object.keys(e.args ?? {})

/** Apple format: positional specifiers, % escaped. */
function appleText(e, text) {
  const args = argList(e)
  return text.replace(/%/g, '%%').replace(/\{([a-z_]+)\}/g, (_, name) => {
    const i = args.indexOf(name) + 1
    return e.args[name] === 'int' ? `%${i}$lld` : `%${i}$@`
  })
}

function androidText(e, text) {
  const args = argList(e)
  const esc = text.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/"/g, '\\"').replace(/%/g, '%%').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/^([@?])/, '\\$1').replace(/\n/g, '\\n')
  return esc.replace(/\{([a-z_]+)\}/g, (_, name) => `%${args.indexOf(name) + 1}$${e.args[name] === 'int' ? 'd' : 's'}`)
}

/** Xcode's own JSON style, so a regenerated catalog differs only where text changed. */
function xcJson(v, indent = '') {
  if (Array.isArray(v)) {
    if (!v.length) return '[\n\n' + indent + ']'
    return '[\n' + v.map((x) => `${indent}  ${xcJson(x, indent + '  ')}`).join(',\n') + '\n' + indent + ']'
  }
  if (v && typeof v === 'object') {
    const keys = Object.keys(v)
    if (!keys.length) return '{\n\n' + indent + '}'
    return '{\n' + keys.map((k) => `${indent}  ${JSON.stringify(k)} : ${xcJson(v[k], indent + '  ')}`).join(',\n') + '\n' + indent + '}'
  }
  return JSON.stringify(v)
}

/** The keyed words go into both Apple String Catalogs: the Mac app's and the iPhone app's. */
function catalog(path) {
  const current = JSON.parse(read(path))
  const unit = (value) => ({ stringUnit: { state: 'translated', value } })
  const next = {}
  // Keys made here look like `area.thing`. Everything else in the catalog belongs to the app and stays.
  const ours = (key) => /^[a-z0-9_]+(\.[a-z0-9_]+)+$/.test(key)
  for (const [key, entry] of Object.entries(current.strings)) if (!ours(key)) next[key] = entry
  for (const [key, e] of strings) {
    const localizations = {}
    for (const lang of LANGS) {
      const v = e[lang]
      localizations[lang] = typeof v === 'object'
        ? { variations: { plural: Object.fromEntries(Object.entries(v).map(([form, t]) => [form, unit(appleText(e, t))])) } }
        : unit(appleText(e, v))
    }
    next[key] = { comment: e.note, extractionState: 'manual', localizations }
  }
  current.strings = next
  return [path, xcJson(current)] // Xcode writes no final newline
}

function androidFiles() {
  const file = (lang) => {
    let s = `<?xml version="1.0" encoding="utf-8"?>\n<!-- ${STRINGS_NOTE} -->\n<resources>\n`
    for (const [key, e] of strings) {
      const name = key.replace(/\./g, '_')
      const v = e[lang]
      if (typeof v === 'object') {
        const forms = { ...v }
        if (lang === 'es' && !forms.many) forms.many = forms.other
        s += `  <plurals name="${name}">\n` + Object.entries(forms).map(([q, t]) => `    <item quantity="${q}">${androidText(e, t)}</item>`).join('\n') + `\n  </plurals>\n`
      } else s += `  <string name="${name}">${androidText(e, v)}</string>\n`
    }
    return s + `</resources>\n`
  }
  return [
    ['design/generated/android/values/strings.xml', file('en')],
    ['design/generated/android/values-es/strings.xml', file('es')],
    ['design/generated/android/values-b+zh+Hans/strings.xml', file('zh-Hans')],
  ]
}

function reswFiles() {
  const escXml = (t) => t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  const head = `<?xml version="1.0" encoding="utf-8"?>\n<!-- ${STRINGS_NOTE} -->\n<root>\n`
    + `  <resheader name="resmimetype"><value>text/microsoft-resx</value></resheader>\n  <resheader name="version"><value>2.0</value></resheader>\n`
    + `  <resheader name="reader"><value>System.Resources.ResXResourceReader, System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089</value></resheader>\n`
    + `  <resheader name="writer"><value>System.Resources.ResXResourceWriter, System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089</value></resheader>\n`
  const file = (lang) => {
    let s = head
    for (const [key, e] of strings) {
      const v = e[lang]
      // One string per plural form: the key with .one or .other. The app picks the form.
      if (typeof v === 'object') for (const [form, t] of Object.entries(v)) s += `  <data name="${key}.${form}" xml:space="preserve"><value>${escXml(t)}</value><comment>${escXml(e.note)}</comment></data>\n`
      else s += `  <data name="${key}" xml:space="preserve"><value>${escXml(v)}</value><comment>${escXml(e.note)}</comment></data>\n`
    }
    return s + `</root>\n`
  }
  return [
    ['design/generated/windows/en-US/Resources.resw', file('en')],
    ['design/generated/windows/es/Resources.resw', file('es')],
    ['design/generated/windows/zh-Hans/Resources.resw', file('zh-Hans')],
  ]
}

function poFiles() {
  const q = (t) => JSON.stringify(t)
  const entry = (key, e, lang) => {
    let s = `#. ${e.note}\n`
    const v = e[lang]
    const en = e.en
    s += `msgctxt ${q(key)}\n`
    if (typeof en === 'object') {
      s += `msgid ${q(en.one ?? en.other)}\nmsgid_plural ${q(en.other)}\n`
      const forms = lang === 'en' ? ['', ''] : lang === 'zh-Hans' ? [v.other] : [v.one ?? v.other, v.other]
      forms.forEach((t, i) => { s += `msgstr[${i}] ${q(t)}\n` })
    } else s += `msgid ${q(en)}\nmsgstr ${q(lang === 'en' ? '' : v)}\n`
    return s + '\n'
  }
  const header = (lang) => `# ${STRINGS_NOTE}\nmsgid ""\nmsgstr ""\n"Content-Type: text/plain; charset=UTF-8\\n"\n"Language: ${lang}\\n"\n"Plural-Forms: nplurals=${lang === 'zh_Hans' ? 1 : 2}; plural=${lang === 'zh_Hans' ? '0' : '(n != 1)'};\\n"\n\n`
  const file = (lang, code) => header(code) + [...strings].map(([k, e]) => entry(k, e, lang)).join('')
  return [
    ['design/generated/gettext/imp.pot', header('').replace('"Language: \\n"\n', '') + [...strings].map(([k, e]) => entry(k, e, 'en')).join('')],
    ['design/generated/gettext/es.po', file('es', 'es')],
    ['design/generated/gettext/zh_Hans.po', file('zh-Hans', 'zh_Hans')],
  ]
}

// ---------------------------------------------------------------- docs tables

const cell = (t) => t.replace(/\|/g, '\\|').replace(/\n/g, ' ')
const show = (v) => (typeof v === 'object' ? Object.entries(v).map(([f, t]) => `${f}: ${t}`).join(' / ') : v)

function tableFor(prefixes, languages) {
  const rows = [...strings].filter(([k]) => prefixes.some((p) => k === p || k.startsWith(p.endsWith('.') ? p : `${p}.`)))
  if (!rows.length) fail(`no strings match ${prefixes.join(' ')}`)
  let s = `| Key | ${languages.map((l) => ({ en: 'English', es: 'Spanish', 'zh-Hans': 'Chinese (Simplified)' })[l]).join(' | ')} |\n| --- | ${languages.map(() => '---').join(' | ')} |\n`
  for (const [k, e] of rows) s += `| \`${k}\` | ${languages.map((l) => cell(show(e[l]))).join(' | ')} |\n`
  return s
}

function tokenTable(name) {
  const secs = (v) => `${v} s`
  if (name === 'motion') {
    let t = '| Preset | Curve | Length | With Reduce Motion | Used for |\n| --- | --- | --- | --- | --- |\n'
    for (const p of presets) {
      const curve = p.swiftCurve === 'spring' ? `spring${p.bounce ? `, bounce ${p.bounce}` : ''}` : p.swiftCurve
      t += `| \`${p.name}\` | ${curve} | ${secs(p.seconds)} | ${p.reduced === 'fade' ? `fade, ${secs(reducedFade)}` : 'no animation'} | ${p.doc} |\n`
    }
    return t
  }
  if (name === 'behavior') {
    let t = '| Name | Value | What it is |\n| --- | --- | --- |\n'
    for (const [n, b] of behavior) t += `| \`${n}\` | ${b.value} | ${b.doc} |\n`
    return t
  }
  if (name === 'sizes') {
    let t = '| Size | iPhone | Android | macOS | Windows | Linux | What it is |\n| --- | --- | --- | --- | --- | --- | --- |\n'
    for (const [n, z] of sizes) t += `| \`${n}\` | ${z.ios} | ${z.android} | ${z.macos} | ${z.windows} | ${z.linux} | ${z.doc} |\n`
    return t
  }
  fail(`unknown token table ${name}`)
}

function docPages() {
  const dir = join(root, 'docs/ux')
  const out = []
  if (!existsSync(dir)) return out
  for (const f of readdirSync(dir).filter((x) => x.endsWith('.md')).sort()) {
    const path = `docs/ux/${f}`
    if (f === 'strings.md') continue
    let text = read(path)
    text = text.replace(/<!-- strings: ([^>]*?) -->[\s\S]*?<!-- \/strings -->/g, (_, list) =>
      `<!-- strings: ${list} -->\n${tableFor(list.trim().split(/\s+/), ['en'])}<!-- /strings -->`)
    text = text.replace(/<!-- tokens: (\w+) -->[\s\S]*?<!-- \/tokens -->/g, (_, name) => `<!-- tokens: ${name} -->\n${tokenTable(name)}<!-- /tokens -->`)
    out.push([path, text])
  }
  let all = `<!-- ${STRINGS_NOTE} -->\n# All words\n\nEvery user-facing word of the new screens, by key, in the three languages. The source is \`design/strings\`. The same keys are used on every platform. A word in curly brackets, like {name}, is filled in by the app.\n\n`
  all += tableFor([...new Set([...strings.keys()].map((k) => k.split('.')[0]))], LANGS)
  out.push(['docs/ux/strings.md', all])
  return out
}

// ---------------------------------------------------------------- animations

/** The five animations the apps carry, cut from the catalog the Den seeds from (spec/animations/catalog.json). */
function bundledAnimations() {
  const catalog = JSON.parse(read('spec/animations/catalog.json'))
  const bundled = catalog.animations.filter((a) => a.bundled === true)
  if (bundled.length !== 5) fail(`spec/animations/catalog.json: ${bundled.length} animations are bundled, expected exactly 5`)
  const ids = catalog.animations.map((a) => a.id)
  if (new Set(ids).size !== ids.length) fail('spec/animations/catalog.json: an id is used twice')
  const defaults = catalog.defaults ?? {}
  for (const [trigger, id] of Object.entries(defaults)) {
    if (!bundled.some((a) => a.id === id)) fail(`spec/animations/catalog.json: the default for ${trigger} is ${id}, which is not bundled`)
  }
  const json = JSON.stringify({ name: catalog.name, defaults, animations: bundled }, null, 2)
  if (json.includes('"#')) fail('spec/animations/catalog.json: the bundled animations cannot hold "# (it ends the Swift raw string)')
  return `// Generated from spec/animations/catalog.json, do not edit. Run: node design/generate.mjs\n\n` +
    `extension AnimationCatalog {\n` +
    `    /// The bundled animations as catalog JSON. Compiled in, so no resource bundle has to be found at run time.\n` +
    `    static let bundledJSON = #"""\n${json}\n"""#\n}\n`
}

/** The presets the apps offer, as data: the starter kit (read through the same parser as any kit) and the services. */
function bundledPresets() {
  const kitText = read('spec/presets/starter-kit.json')
  const kit = JSON.parse(kitText)
  if (!Array.isArray(kit.triggers) || kit.triggers.length === 0) fail('spec/presets/starter-kit.json: needs a list of triggers')
  for (const t of kit.triggers) if (!t.name || !t.when?.kind) fail(`spec/presets/starter-kit.json: every trigger needs a name and a when.kind`)
  const servicesText = read('spec/presets/services.json')
  const services = JSON.parse(servicesText)
  const ids = services.services.map((s) => s.id)
  if (new Set(ids).size !== ids.length) fail('spec/presets/services.json: an id is used twice')
  if (!ids.includes(services.default)) fail(`spec/presets/services.json: the default ${services.default} is not a service`)
  for (const s of services.services) {
    if (!/^https?:\/\//.test(s.baseURL)) fail(`spec/presets/services.json: ${s.id} needs an http(s) baseURL`)
    if (!/^https:\/\//.test(s.link)) fail(`spec/presets/services.json: ${s.id} needs an https link`)
    if (typeof s.local !== 'boolean' || !s.symbol) fail(`spec/presets/services.json: ${s.id} needs local and symbol`)
  }
  for (const [file, text] of [['starter-kit.json', kitText], ['services.json', servicesText]]) {
    if (text.includes('"#')) fail(`spec/presets/${file} cannot hold "# (it ends the Swift raw string)`)
  }
  return `// Generated from spec/presets, do not edit. Run: node design/generate.mjs\n\n` +
    `/// The presets as their JSON files. Compiled in, so no resource bundle has to be found at run time.\n` +
    `enum Presets {\n` +
    `    /// spec/presets/starter-kit.json: a kit, read by \`Kit.parse\` like any other.\n` +
    `    static let starterKitJSON = #"""\n${kitText.trimEnd()}\n"""#\n\n` +
    `    /// spec/presets/services.json: the services offered when adding one.\n` +
    `    static let servicesJSON = #"""\n${servicesText.trimEnd()}\n"""#\n}\n`
}

// ---------------------------------------------------------------- components

const components = JSON.parse(read('design/components.json'))
delete components._note
const REF = /^(color|spacing|radius|size|icon|stroke|opacity|type|motion|shadow)\.([A-Za-z]+)$/
const GROUPS = { color: tokens.colors, spacing: tokens.spacing, radius: tokens.radius, size: tokens.size, icon: tokens.icon, stroke: tokens.stroke, opacity: tokens.opacity, type: tokens.type, motion: tokens.motion.presets, shadow: tokens.shadows }

/** Splits a spec value into { kind, name } for a token reference, or { kind: 'word' | 'number', value }. */
function refOf(component, prop, value) {
  if (typeof value === 'number') return { kind: 'number', value }
  const m = REF.exec(value)
  if (!m) return { kind: 'word', value }
  if (!(m[2] in GROUPS[m[1]])) fail(`components.json: ${component}.${prop} refers to ${value}, which does not exist`)
  return { kind: m[1], name: m[2] }
}
const componentList = Object.entries(components).map(([key, c]) => {
  if (!c.doc || !c.props || !Array.isArray(c.rules)) fail(`components.json: ${key} needs doc, props and rules`)
  return { key, ...c, refs: Object.entries(c.props).map(([prop, value]) => ({ prop, ...refOf(key, prop, value) })) }
})

/** The concrete value of a reference on one platform, for documents. */
function describeRef(r, platform) {
  const px = (v) => `${v} px`
  switch (r.kind) {
    case 'color': { const c = tokens.colors[r.name]; return `\`color.${r.name}\` (dark ${cssColor(c.dark)}, light ${cssColor(c.light)})` }
    case 'spacing': case 'radius': case 'stroke': return `\`${r.kind}.${r.name}\` (${px(GROUPS[r.kind][r.name].value)})`
    case 'size': return `\`size.${r.name}\` (${px(tokens.size[r.name][platform])})`
    case 'icon': return `\`icon.${r.name}\` (${px(tokens.icon[r.name].size)})`
    case 'opacity': return `\`opacity.${r.name}\` (${tokens.opacity[r.name].value})`
    case 'type': return `\`type.${r.name}\` (${px(tokens.type[r.name].size)}, weight ${tokens.type[r.name].weight}, ${tokens.type[r.name].design})`
    case 'motion': return `\`motion.${r.name}\` (${duration(GROUPS.motion[r.name].duration)} s)`
    case 'shadow': return `\`shadow.${r.name}\` (y ${tokens.shadows[r.name].y}, blur ${tokens.shadows[r.name].blur})`
    default: return `\`${r.value}\``
  }
}

function componentsDoc() {
  let s = `<!-- ${SOURCE_NOTE.replace('tokens.json', 'components.json')} -->\n# Components\n\n`
  s += `Every Pebble component as a spec. A platform implements the same anatomy with the same tokens, so the Mac, the iPhone, Android, Windows, Linux and the browser popup look and behave alike. The source is \`design/components.json\`. Sizes are given for the desktop (macOS) and, where they differ, the other platforms are in the generated files of each platform (see \`design/generated/<platform>/README.md\`).\n\n`
  s += `The rules of the language (one surface, pebbles, no dividers, monochrome chrome, flat, icon-first, help for every setting, nothing clips) are in [the design language](./index.md).\n\n`
  for (const c of componentList) {
    s += `## ${c.key}\n\n${c.doc}\n\n| Property | Value |\n| --- | --- |\n`
    for (const r of c.refs) s += `| \`${r.prop}\` | ${describeRef(r, 'macos')} |\n`
    s += `\n`
    for (const rule of c.rules) s += `- ${rule}\n`
    s += `\n`
  }
  return s
}

// ---------------------------------------------------------------- Android, Windows and Linux

function kotlinComponents() {
  const pascalKey = (key) => key.split('.').map(pascal).join('')
  const f = (n) => `${num(n)}f`
  let s = `// ${SOURCE_NOTE.replace('tokens.json', 'components.json')}\npackage app.imp.design\n\nimport androidx.compose.ui.graphics.Color\nimport androidx.compose.ui.unit.Dp\n\n`
  s += `/** The Pebble components as specs: tokens in, no behaviour. Colours are functions of the palette, so one spec serves light and dark. */\nobject ImpComponents {\n`
  for (const c of componentList) {
    s += `    /** ${c.doc} */\n    object ${pascalKey(c.key)} {\n`
    for (const r of c.refs) {
      const n = camel(r.prop)
      switch (r.kind) {
        case 'color': s += `        val ${n}: (ImpPalette) -> Color = { it.${r.name} }\n`; break
        case 'spacing': s += `        val ${n}: Dp = ImpSpacing.${r.name}\n`; break
        case 'radius': s += `        val ${n}: Dp = ImpRadius.${r.name}\n`; break
        case 'stroke': s += `        val ${n}: Dp = ImpStroke.${r.name}\n`; break
        case 'size': s += `        val ${n}: Dp = ImpSizing.${r.name}\n`; break
        case 'icon': s += `        val ${n}: Dp = ImpIcon.${r.name}\n`; break
        case 'opacity': s += `        const val ${n}: Float = ImpOpacity.${r.name}\n`; break
        case 'type': s += `        val ${n}: ImpTextStyle = ImpType.${r.name}\n`; break
        case 'motion': s += `        val ${n}: ImpMotion = ImpMotions.${r.name}\n`; break
        case 'shadow': s += `        val ${n}: ImpShadow = ImpShadows.${r.name}\n`; break
        case 'number': s += `        const val ${n}: Float = ${f(r.value)}\n`; break
        default: s += `        const val ${n}: String = "${r.value}"\n`
      }
    }
    s += `    }\n\n`
  }
  return s.replace(/\n\n$/, '\n') + `}\n`
}

function xamlComponents() {
  const P = (key) => key.split('.').map(pascal).join('')
  const brush = (name) => `Imp${pascal(name)}Brush`
  const valueOf = (c, prop) => c.refs.find((r) => r.prop === prop)
  const length = (r) => (r.kind === 'size' ? tokens.size[r.name].windows : r.kind === 'icon' ? tokens.icon[r.name].size : GROUPS[r.kind][r.name].value)
  let s = `<?xml version="1.0" encoding="utf-8"?>\n<!-- ${SOURCE_NOTE.replace('tokens.json', 'components.json')} -->\n`
  s += `<ResourceDictionary\n    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"\n    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">\n\n`
  s += `  <!-- Merge ImpTokens.xaml first. Every property of a component is a resource: ImpPebbleRadius, ImpRowMinHeight, ... A colour is the key of its brush. -->\n`
  for (const c of componentList) {
    for (const r of c.refs) {
      const key = `Imp${P(c.key)}${pascal(r.prop)}`
      if (r.kind === 'color') s += `  <x:String x:Key="${key}Brush">${brush(r.name)}</x:String>\n`
      else if (r.kind === 'radius') s += `  <CornerRadius x:Key="${key}">${length(r)}</CornerRadius>\n`
      else if (['spacing', 'size', 'icon', 'stroke', 'opacity'].includes(r.kind)) s += `  <x:Double x:Key="${key}">${r.kind === 'opacity' ? tokens.opacity[r.name].value : length(r)}</x:Double>\n`
      else if (r.kind === 'number') s += `  <x:Double x:Key="${key}">${r.value}</x:Double>\n`
      else if (r.kind === 'word') s += `  <x:String x:Key="${key}">${r.value}</x:String>\n`
      else if (r.kind === 'type') s += `  <x:Double x:Key="${key}Size">${tokens.type[r.name].size}</x:Double>\n`
    }
  }
  s += `\n  <!-- Styles for the components that are one element. The rest are built from the resources above. -->\n`
  const box = (key, fill, extra = '') => {
    const c = componentList.find((x) => x.key === key)
    const get = (p) => valueOf(c, p)
    let t = `  <Style x:Key="Imp${P(key)}Style" TargetType="Border">\n`
    if (get(fill)) t += `    <Setter Property="Background" Value="{ThemeResource ${brush(get(fill).name)}}"/>\n`
    if (get('radius')) t += `    <Setter Property="CornerRadius" Value="${length(get('radius'))}"/>\n`
    if (get('padding')) t += `    <Setter Property="Padding" Value="${length(get('padding'))}"/>\n`
    if (get('paddingX')) t += `    <Setter Property="Padding" Value="${length(get('paddingX'))},${length(get('paddingY'))}"/>\n`
    t += `    <Setter Property="BorderThickness" Value="0"/>\n${extra}  </Style>\n`
    return t
  }
  s += box('pebble', 'fill') + box('surface', 'fill') + box('popover', 'fill') + box('bubble', 'fill') + box('barMenu', 'fill') + box('undoBar', 'fill') + box('badge', 'fill')
  s += box('infoTip', 'fill', `    <Setter Property="MaxWidth" Value="${length(valueOf(componentList.find((x) => x.key === 'infoTip'), 'maxWidth'))}"/>\n`)
  for (const key of ['button.primary', 'button.secondary', 'button.quiet', 'button.destructive']) {
    const c = componentList.find((x) => x.key === key)
    const get = (p) => valueOf(c, p)
    const fill = get('fill'), hover = get('fillHover')
    const base = fill.kind === 'color' ? `{ThemeResource ${brush(fill.name)}}` : 'Transparent'
    const over = hover ? `{ThemeResource ${brush(hover.name)}}` : key === 'button.primary' ? `{ThemeResource ${brush('accentBright')}}` : base
    const text = `{ThemeResource ${brush(get('text').name)}}`
    const textOver = get('textHover') ? `{ThemeResource ${brush(get('textHover').name)}}` : text
    s += `  <Style x:Key="Imp${P(key)}Style" TargetType="Button">\n`
    s += `    <Setter Property="Background" Value="${base}"/>\n    <Setter Property="Foreground" Value="${text}"/>\n`
    s += `    <Setter Property="CornerRadius" Value="${length(get('radius'))}"/>\n    <Setter Property="Padding" Value="${length(get('paddingX'))},${length(get('paddingY'))}"/>\n`
    s += `    <Setter Property="MinHeight" Value="${length(get('minHeight'))}"/>\n    <Setter Property="FontSize" Value="${tokens.type[get('type').name].size}"/>\n    <Setter Property="BorderThickness" Value="0"/>\n`
    s += `    <Setter Property="Template">\n      <Setter.Value>\n        <ControlTemplate TargetType="Button">\n`
    s += `          <Border x:Name="Root" Background="{TemplateBinding Background}" CornerRadius="{TemplateBinding CornerRadius}" Padding="{TemplateBinding Padding}">\n`
    s += `            <ContentPresenter x:Name="Content" Foreground="{TemplateBinding Foreground}" HorizontalAlignment="Center" VerticalAlignment="Center"/>\n`
    s += `            <VisualStateManager.VisualStateGroups>\n              <VisualStateGroup x:Name="CommonStates">\n                <VisualState x:Name="Normal"/>\n`
    s += `                <VisualState x:Name="PointerOver">\n                  <VisualState.Setters>\n                    <Setter Target="Root.Background" Value="${over}"/>\n                    <Setter Target="Content.Foreground" Value="${textOver}"/>\n                  </VisualState.Setters>\n                </VisualState>\n`
    s += `                <VisualState x:Name="Pressed">\n                  <VisualState.Setters>\n                    <Setter Target="Root.Background" Value="${over}"/>\n                    <Setter Target="Root.Opacity" Value="${tokens.opacity.dimmed.value}"/>\n                  </VisualState.Setters>\n                </VisualState>\n`
    s += `                <VisualState x:Name="Disabled">\n                  <VisualState.Setters>\n                    <Setter Target="Root.Opacity" Value="${tokens.opacity.disabled.value}"/>\n                  </VisualState.Setters>\n                </VisualState>\n`
    s += `              </VisualStateGroup>\n            </VisualStateManager.VisualStateGroups>\n          </Border>\n`
    s += `        </ControlTemplate>\n      </Setter.Value>\n    </Setter>\n  </Style>\n`
  }
  return s + `\n</ResourceDictionary>\n`
}

function csharpTokens() {
  const P = pascal
  let s = `// ${SOURCE_NOTE}\nnamespace Imp.Design;\n\n`
  const consts = (name, doc, entries) => `/// <summary>${doc}</summary>\npublic static class ${name}\n{\n${entries.map(([n, v, d]) => `    /// <summary>${d}</summary>\n    public const double ${P(n)} = ${v};`).join('\n')}\n}\n\n`
  s += consts('ImpSpace', 'Spacing in device independent pixels.', Object.entries(tokens.spacing).map(([n, t]) => [n, t.value, t.doc]))
  s += consts('ImpRadii', 'Corner radii.', Object.entries(tokens.radius).map(([n, t]) => [n, t.value, t.doc]))
  s += consts('ImpSizes', 'Sizes of things you point at, for Windows.', sizes.map(([n, t]) => [n, t.windows, t.doc]))
  s += consts('ImpIcons', 'Icon sizes.', icons.map(([n, t]) => [n, t.size, t.doc]))
  s += consts('ImpOpacities', 'Opacities.', opacities.map(([n, t]) => [n, t.value, t.doc]))
  s += consts('ImpType', 'Font sizes of the type scale (the weight and the rounded design are in ImpTokens.xaml).', types.map(([n, t]) => [n, t.size, t.doc]))
  s += `/// <summary>The named animations. A preset with no reduced duration just happens under Reduce Motion.</summary>\npublic static class ImpMotion\n{\n`
  s += `    /// <summary>With Reduce Motion, a preset that fades changes opacity over this long.</summary>\n    public static readonly System.TimeSpan ReducedFade = System.TimeSpan.FromSeconds(${reducedFade});\n\n`
  for (const p of presets) {
    s += `    /// <summary>${p.doc}</summary>\n    public static readonly System.TimeSpan ${P(p.name)} = System.TimeSpan.FromMilliseconds(${Math.round(p.seconds * 1000)});\n`
    s += `    public static readonly System.TimeSpan ${P(p.name)}Reduced = System.TimeSpan.FromMilliseconds(${p.reduced === 'fade' ? Math.round(reducedFade * 1000) : 0});\n`
    s += `    public static readonly (double X1, double Y1, double X2, double Y2) ${P(p.name)}Curve = (${CURVES[p.curve].join(', ')});\n`
  }
  return s + `}\n`
}

// ---------------------------------------------------------------- the terminal

/** The palette, spacing and motion for the command line app: one Rust module, no dependencies. */
function rustTheme() {
  const snake = (n) => words(n).join('_')
  const rgba = (hex) => { const c = parseColor(hex); return `Rgba::new(${c.r}, ${c.g}, ${c.b}, ${c.a})` }
  let s = `// ${SOURCE_NOTE}\n// The terminal draws on its own background, so only the colours that sit on a fill are used as they are.\n#![allow(dead_code)]\n\n`
  s += `/// A colour with an alpha channel (0 to 255).\n#[derive(Clone, Copy, Debug, PartialEq, Eq)]\npub struct Rgba {\n    pub r: u8,\n    pub g: u8,\n    pub b: u8,\n    pub a: u8,\n}\n\nimpl Rgba {\n    pub const fn new(r: u8, g: u8, b: u8, a: u8) -> Self {\n        Self { r, g, b, a }\n    }\n}\n\n`
  s += `/// The colours of one appearance.\n#[derive(Clone, Copy, Debug)]\npub struct Palette {\n` + colorNames.map((n) => `    pub ${snake(n)}: Rgba,`).join('\n') + `\n}\n\n`
  for (const mode of ['dark', 'light']) {
    s += `pub const ${mode.toUpperCase()}: Palette = Palette {\n` + colorNames.map((n) => `    ${snake(n)}: ${rgba(tokens.colors[n][mode])},`).join('\n') + `\n};\n\n`
  }
  s += `/// Spacing in pixels. A terminal rounds it to cells in cli/src/theme.rs.\npub mod spacing {\n` + Object.entries(tokens.spacing).map(([n, t]) => `    pub const ${snake(n).toUpperCase()}: u16 = ${t.value};`).join('\n') + `\n}\n\n`
  s += `/// Animation lengths in milliseconds, and what each does under reduced motion (0 means it just happens).\npub mod motion {\n`
  s += `    pub const REDUCED_FADE_MS: u64 = ${Math.round(reducedFade * 1000)};\n`
  for (const p of presets) s += `    pub const ${snake(p.name).toUpperCase()}_MS: u64 = ${Math.round(p.seconds * 1000)};\n`
  return s + `}\n`
}

// ---------------------------------------------------------------- the browser extension's words

/** chrome.i18n messages: the key with underscores, {name} as $1, $2 in the order of the arguments, $ doubled. */
function extensionLocales() {
  const dirs = { en: 'en', es: 'es', 'zh-Hans': 'zh_CN' }
  return LANGS.map((lang) => {
    const out = {}
    for (const [key, e] of strings) {
      if (!key.startsWith('extension.')) continue
      if (typeof e[lang] === 'object') fail(`${key}: the extension has no plurals`)
      const args = argList(e)
      const message = e[lang].replace(/\$/g, '$$$$').replace(/\{([a-z_]+)\}/g, (_, name) => `$${args.indexOf(name) + 1}`)
      out[key.replace(/\./g, '_')] = { message, description: e.note }
    }
    return [`extension/_locales/${dirs[lang]}/messages.json`, JSON.stringify(out, null, 2) + '\n']
  })
}

// ---------------------------------------------------------------- platform READMEs

function platformReadmes() {
  const note = `<!-- ${SOURCE_NOTE} -->\n`
  const common = `\nEverything here is generated. Do not edit it: change \`design/tokens.json\`, \`design/components.json\` or \`design/strings/*.json\` and run \`node design/generate.mjs\` (or \`make tokens\`). \`node design/generate.mjs --check\` fails when a file is out of date.\n\nThe language is Pebble: [docs/design](../../../docs/design/index.md). The components every platform builds the same way are in [docs/design/components.md](../../../docs/design/components.md).\n`
  return [
    ['design/generated/android/README.md', note + `# Android\n${common}
## Files

| File | What it is |
| --- | --- |
| \`ImpTheme.kt\` | Palettes (\`ImpDarkPalette\`, \`ImpLightPalette\`), \`ImpSpacing\`, \`ImpRadius\`, \`ImpStroke\`, \`ImpOpacity\`, \`ImpSizing\`, \`ImpIcon\`, \`ImpType\`, \`ImpShadows\`, \`ImpMotions\`, \`ImpBehavior\` and the \`ImpTheme\` composable |
| \`ImpComponents.kt\` | \`ImpComponents.Pebble\`, \`.Row\`, \`.ButtonPrimary\`, ...: each spec as typed values |
| \`values/strings.xml\`, \`values-es\`, \`values-b+zh+Hans\` | Every word, by key with dots turned into underscores (\`home.title\` is \`R.string.home_title\`). Plurals are \`<plurals>\` |

## Use

1. Copy the Kotlin files into the module's \`app/imp/design\` package and the \`values*\` folders into \`src/main/res\`.
2. Wrap the app in \`ImpTheme { ... }\`. It picks the dark or light palette from the system and offers it as \`LocalImpPalette.current\`.
3. Read colours as \`LocalImpPalette.current.card\`, never as a literal. Sizes, spacing and radii are \`Dp\` values: \`ImpSpacing.large\`.
4. Build components from \`ImpComponents\`: \`Modifier.background(ImpComponents.Pebble.fill(palette), RoundedCornerShape(ImpComponents.Pebble.radius))\`. A colour in a spec is a function of the palette.
5. Animate with \`ImpMotions.hover.spec(reduceMotion)\`. Read Reduce Motion from the system's animator duration scale being 0.
6. The type scale is rounded on Apple platforms. Android has no system rounded face: \`ImpTextStyle.design\` says "rounded", so bundle a rounded family (for example Google Sans Rounded or Nunito) and use it for every style.
7. Text sizes are \`sp\` and follow the system font scale. Hit areas are at least \`ImpSizing.hit\` (48 dp).
`],
    ['design/generated/windows/README.md', note + `# Windows (WinUI 3)\n${common}
## Files

| File | What it is |
| --- | --- |
| \`ImpTokens.xaml\` | Colours and brushes for Default (dark) and Light, spacing, radii, strokes, opacities, sizes, icon sizes, type, motion and behaviour numbers as resources |
| \`ImpComponents.xaml\` | The component specs as resources (\`ImpPebbleRadius\`, \`ImpRowMinHeight\`, ...) and styles (\`ImpPebbleStyle\`, \`ImpButtonPrimaryStyle\`, ...) |
| \`ImpTokens.cs\` | The same numbers as typed constants for code (\`ImpSpace.Large\`, \`ImpMotion.Hover\`) |
| \`en-US\`, \`es\`, \`zh-Hans\` \`/Resources.resw\` | Every word. A plural is two strings: \`key.one\` and \`key.other\`. Pick with the count |

## Use

1. Merge both dictionaries in \`App.xaml\`: \`ImpTokens.xaml\` first, then \`ImpComponents.xaml\`.
2. Set the window background with \`{ThemeResource ImpSurfaceBrush}\`. Text is \`ImpTextBrush\`. Never write a hex colour in a view.
3. A group is \`<Border Style="{StaticResource ImpPebbleStyle}">\`. A button is \`Style="{StaticResource ImpButtonPrimaryStyle}"\`. They have no outline and no divider.
4. Animations: use the \`ImpMotion<Name>Duration\` and \`...Easing\` (a KeySpline string) resources, and the \`...ReducedDuration\` one when \`UISettings.AnimationsEnabled\` is false.
5. Read strings with \`ResourceLoader.GetString("home.title")\`. The .resw files are neutral: add \`en-US\`, \`es\` and \`zh-Hans\` as the app's languages in the project.
6. The type is rounded on Apple platforms. On Windows use Segoe UI Variable with its rounded optical size where available, or a bundled rounded face, for every style.
7. Hit areas are at least \`ImpSizes.Hit\` (32 px, 40 px for touch).
`],
    ['design/generated/gtk/README.md', note + `# Linux (GTK 4 and libadwaita)\n${common}
## Files

| File | What it is |
| --- | --- |
| \`imp-colors-dark.css\`, \`imp-colors-light.css\` | \`@define-color\` for libadwaita's named colours (window, card, popover, accent, ...) and for every token as \`@imp_<name>\` |
| \`imp-tokens.css\` | Spacing, radii, sizes, icons and type as \`--imp-*\` custom properties (GTK 4.16 or newer) and one \`.imp-motion-<name>\` class per animation |
| \`imp-components.css\` | One class per component: \`.imp-pebble\`, \`.imp-row\`, \`.imp-button-primary\`, ... with the values filled in |
| \`../gettext/imp.pot\`, \`es.po\`, \`zh_Hans.po\` | Every word. The message context is the key (\`msgctxt\`), the message id is the English text |

## Use

1. Load \`imp-colors-dark.css\` or \`imp-colors-light.css\` with \`Gtk.CssProvider\` at \`STYLE_PROVIDER_PRIORITY_APPLICATION\`, following \`Adw.StyleManager.get_dark()\`, and swap the provider when it changes. Then load \`imp-tokens.css\` and \`imp-components.css\`.
2. Add the class to a widget: \`box.add_css_class("imp-pebble")\`. Never write a colour in the app's own CSS: use \`@imp_card\`, \`@imp_text\`, \`@imp_muted\`.
3. Compile the catalogs with \`msgfmt\` into \`locale/<lang>/LC_MESSAGES/imp.mo\` and read words with \`pgettext(key, english)\` (\`GLib.dpgettext2\`).
4. Reduce Motion is \`gtk-enable-animations = false\`: GTK then skips the transitions by itself.
5. The type is rounded on Apple platforms. On Linux use "Cantarell" or a bundled rounded face for every style.
`],
  ]
}

function gtkComponents() {
  const px = (r) => (r.kind === 'size' ? tokens.size[r.name].linux : r.kind === 'icon' ? tokens.icon[r.name].size : GROUPS[r.kind][r.name].value)
  const named = (n) => `@imp_${n.replace(/[A-Z]/g, (m) => '_' + m.toLowerCase())}`
  let s = `/* ${SOURCE_NOTE.replace('tokens.json', 'components.json')} */\n/* One class per component. Load imp-colors-dark.css or imp-colors-light.css first. */\n\n`
  for (const c of componentList) {
    const get = (p) => c.refs.find((r) => r.prop === p)
    const cls = `.imp-${c.key.replace(/\./g, '-').replace(/[A-Z]/g, (m) => '-' + m.toLowerCase())}`
    const decls = []
    const fill = get('fill'), text = get('text'), radius = get('radius')
    if (fill) decls.push(fill.kind === 'color' ? `background-color: ${named(fill.name)}` : 'background: none')
    if (text) decls.push(`color: ${named(text.name)}`)
    if (radius) decls.push(`border-radius: ${px(radius)}px`)
    if (get('padding')) decls.push(`padding: ${px(get('padding'))}px`)
    if (get('paddingX')) decls.push(`padding: ${get('paddingY') ? px(get('paddingY')) : 0}px ${px(get('paddingX'))}px`)
    if (get('minHeight')) decls.push(`min-height: ${px(get('minHeight'))}px`)
    if (get('height')) decls.push(`min-height: ${px(get('height'))}px`)
    if (get('maxWidth')) decls.push(`max-width: ${px(get('maxWidth'))}px`)
    if (get('width')) decls.push(`min-width: ${px(get('width'))}px`)
    if (get('type')) decls.push(`font-size: ${tokens.type[get('type').name].size}px`, `font-weight: ${tokens.type[get('type').name].weight}`)
    if (get('shadow')) decls.push(get('shadow').kind === 'shadow' ? `box-shadow: 0 ${tokens.shadows[get('shadow').name].y}px ${tokens.shadows[get('shadow').name].blur}px @imp_shadow_${get('shadow').name}` : 'box-shadow: none')
    decls.push('border: none')
    s += `/* ${c.doc} */\n${cls} {\n${decls.map((d) => `  ${d};`).join('\n')}\n}\n`
    if (get('fillHover')) s += `${cls}:hover { background-color: ${named(get('fillHover').name)}; }\n`
    if (get('textHover')) s += `${cls}:hover { color: ${named(get('textHover').name)}; }\n`
    if (c.key === 'button.primary') s += `${cls}:hover { background-color: ${named('accentBright')}; }\n`
    s += c.key.startsWith('button.') ? `${cls}:disabled { opacity: ${tokens.opacity.disabled.value}; }\n\n` : '\n'
  }
  s += `/* The focus ring of every control: keyboard focus only. */\n*:focus-visible { outline: ${tokens.stroke.focus.value}px solid ${named('focus')}; outline-offset: ${tokens.spacing.hairline.value}px; }\n`
  return s
}

// ---------------------------------------------------------------- the terminal app's words

/** cli/src/strings.generated.rs: a table of key and [en, es, zh-Hans] for the keys that start with cli. */
function rustStrings() {
  const q = (t) => JSON.stringify(t)
  let s = `// ${STRINGS_NOTE}\n#![cfg_attr(rustfmt, rustfmt::skip)]\n\n/// Every word of the terminal app: the key and its text in ${LANGS.join(', ')}, sorted by key.\npub static STRINGS: &[(&str, [&str; ${LANGS.length}])] = &[\n`
  for (const [key, e] of terminalStrings) {
    if (!key.startsWith('cli.')) continue
    if (typeof e.en === 'object') fail(`${key}: the terminal app has no plurals`)
    s += `    (${q(key)}, [${LANGS.map((l) => q(e[l])).join(', ')}]),\n`
  }
  return s + `];\n`
}

// ---------------------------------------------------------------- write

const outputs = [
  ['apple/Sources/ImpDesign/Tokens.generated.swift', swiftTokens()],
  ['extension/tokens.css', webCss()],
  ['design/generated/android/ImpTheme.kt', kotlinTokens()],
  ['design/generated/windows/ImpTokens.xaml', xamlTokens()],
  ['design/generated/gtk/imp-colors-dark.css', gtkColors('dark')],
  ['design/generated/gtk/imp-colors-light.css', gtkColors('light')],
  ['design/generated/gtk/imp-tokens.css', gtkCss()],
  ['design/generated/gtk/imp-components.css', gtkComponents()],
  ['design/generated/android/ImpComponents.kt', kotlinComponents()],
  ['design/generated/windows/ImpComponents.xaml', xamlComponents()],
  ['design/generated/windows/ImpTokens.cs', csharpTokens()],
  ['cli/src/theme.generated.rs', rustTheme()],
  ['cli/src/strings.generated.rs', rustStrings()],
  ['docs/design/components.md', componentsDoc()],
  ...extensionLocales(),
  ...platformReadmes(),
  ['apple/Sources/ImpKit/Reactions/AnimationCatalog.generated.swift', bundledAnimations()],
  ['apple/Sources/ImpKit/Settings/Presets.generated.swift', bundledPresets()],
  catalog('apple/Resources/Localization/Localizable.xcstrings'),
  catalog('apple/iOS/Imp/Localizable.xcstrings'),
  ...androidFiles(),
  ...reswFiles(),
  ...poFiles(),
  ...docPages(),
]

const stale = []
for (const [path, content] of outputs) {
  const full = join(root, path)
  const have = existsSync(full) ? readFileSync(full, 'utf8') : null
  if (have === content) continue
  stale.push(path)
  if (!check) {
    mkdirSync(dirname(full), { recursive: true })
    writeFileSync(full, content)
  }
}
if (check) {
  if (stale.length) {
    console.error(`Out of date, run: node design/generate.mjs\n  ${stale.join('\n  ')}`)
    process.exit(1)
  }
  console.log(`All ${outputs.length} generated files are current.`)
} else {
  console.log(stale.length ? `Wrote ${stale.length} of ${outputs.length} files:\n  ${stale.map((p) => relative('.', join(root, p))).join('\n  ')}` : `All ${outputs.length} files already current.`)
}
