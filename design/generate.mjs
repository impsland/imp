#!/usr/bin/env node
/**
 * Generates the design files of every platform from the sources of truth:
 *
 *   design/tokens.json             colours, spacing, radii, type, sizes, motion and behaviour numbers
 *   design/components.json         the Pebble components, as token references
 *   design/strings/*.json          every word a user reads, one stable key each, in en, es and zh-Hans
 *   spec/presets/*.json            the service presets, compiled into the Apple apps and the terminal app
 *
 * It writes Swift for the Apple apps, CSS for the browser extension, Kotlin and XML for Android,
 * XAML, C# and .resw for Windows, CSS and gettext for Linux, Rust for the terminal app, and the tables in the docs.
 * The list of outputs is near the end of this file.
 *
 * Usage:
 *
 *   node design/generate.mjs           write every generated file that changed
 *   node design/generate.mjs --check   write nothing, and fail when a generated file is out of date
 *   node design/generate.mjs --list    print the path of every generated file
 *   node design/generate.mjs --help    show this usage
 *
 * Exit status: 0 when done, 1 when --check finds a stale file, 2 when a source is invalid or an
 * argument is unknown.
 *
 * No dependencies. Needs Node 20 or newer.
 */

import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// =============================================================================================
// Command line
// =============================================================================================

const USAGE = `Usage: node design/generate.mjs [--check | --list | --help]

Generates the design tokens, components and words of every platform from design/ and spec/.

  (no option)   write every generated file that changed
  --check       write nothing, and exit with status 1 when a generated file is out of date
  --list        print the path of every generated file
  --help        show this help`

const MODES = { '--check': 'check', '--list': 'list', '--help': 'help', '-h': 'help' }

/** Reads the one optional argument. Anything else is a mistake, reported with the usage. */
function parseArguments(args) {
  if (args.length > 1) usageError('give at most one option')
  if (args.length === 0) return 'write'
  const mode = MODES[args[0]]
  if (!mode) usageError(`unknown option ${args[0]}`)
  return mode
}

function usageError(message) {
  console.error(`generate.mjs: ${message}\n\n${USAGE}`)
  process.exit(2)
}

/** Stops with a message about an invalid source. */
function fail(message) {
  console.error(`generate.mjs: ${message}`)
  process.exit(2)
}

const mode = parseArguments(process.argv.slice(2))
if (mode === 'help') {
  console.log(USAGE)
  process.exit(0)
}

// =============================================================================================
// Shared helpers
// =============================================================================================

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const LANGS = ['en', 'es', 'zh-Hans']
const LANGUAGE_NAMES = { en: 'English', es: 'Spanish', 'zh-Hans': 'Chinese (Simplified)' }

/** Reads a file, given relative to the repository root. */
const read = (path) => readFileSync(join(ROOT, path), 'utf8')
const readJson = (path) => JSON.parse(read(path))

/** The first line of every generated file: where it comes from, and how to make it again. */
const generatedFrom = (source) => `generated from ${source}, do not edit. Run: node design/generate.mjs`
const TOKENS_NOTE = generatedFrom('design/tokens.json')
const COMPONENTS_NOTE = generatedFrom('design/components.json')
const STRINGS_NOTE = generatedFrom('design/strings')

// Names. Tokens are named in camelCase ("accentBright") and each platform spells them its own way.
const words = (name) => name.replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase().split(' ')
const kebab = (name) => words(name).join('-')
const snake = (name) => words(name).join('_')
const pascal = (name) => words(name).map((word) => word[0].toUpperCase() + word.slice(1)).join('')
const camel = (name) => {
  const p = pascal(name)
  return p[0].toLowerCase() + p.slice(1)
}
/** A dotted component key in PascalCase: "button.primary" is "ButtonPrimary". */
const pascalKey = (key) => key.split('.').map(pascal).join('')

// Colours. A token colour is "#rrggbb" or "#rrggbbaa".
function parseColor(hex) {
  const match = /^#([0-9a-f]{6})([0-9a-f]{2})?$/i.exec(hex)
  if (!match) fail(`bad colour ${hex}`)
  const rgb = parseInt(match[1], 16)
  return { r: (rgb >> 16) & 255, g: (rgb >> 8) & 255, b: rgb & 255, a: match[2] ? parseInt(match[2], 16) : 255 }
}
/** The alpha channel as a fraction from 0 to 1, rounded to three digits. */
const alpha = (color) => Math.round((color.a / 255) * 1000) / 1000
const hex2 = (n) => n.toString(16).padStart(2, '0')
const cssColor = (hex) => {
  const c = parseColor(hex)
  return c.a === 255 ? `#${hex2(c.r)}${hex2(c.g)}${hex2(c.b)}` : `rgba(${c.r}, ${c.g}, ${c.b}, ${alpha(c)})`
}
/** "AARRGGBB", the order Android and Windows use. */
const argb = (hex) => {
  const c = parseColor(hex)
  return `${hex2(c.a)}${hex2(c.r)}${hex2(c.g)}${hex2(c.b)}`.toUpperCase()
}

/** The cubic Bézier of each animation curve, for platforms that have no named curves. */
const CURVES = {
  easeOut: [0, 0, 0.58, 1],
  easeInOut: [0.42, 0, 0.58, 1],
  snappy: [0.2, 0.9, 0.3, 1],
  spring: [0.2, 0.8, 0.2, 1],
  springBouncy: [0.34, 1.56, 0.64, 1],
}

const milliseconds = (seconds) => Math.round(seconds * 1000)

// =============================================================================================
// Sources: tokens
// =============================================================================================

const tokens = readJson('design/tokens.json')
const colorNames = Object.keys(tokens.colors)
const shadows = Object.entries(tokens.shadows)
const spacings = Object.entries(tokens.spacing)
const radii = Object.entries(tokens.radius)
const strokes = Object.entries(tokens.stroke)
const opacities = Object.entries(tokens.opacity)
const sizes = Object.entries(tokens.size)
const icons = Object.entries(tokens.icon)
const types = Object.entries(tokens.type)
const durations = Object.entries(tokens.duration)
const behavior = Object.entries(tokens.behavior)
const reducedFade = tokens.motion.reducedFade.value

/** A duration in seconds, given as a number or as the name of a duration token. */
function duration(value) {
  if (typeof value === 'number') return value
  const token = tokens.duration[value]
  if (!token) fail(`unknown duration ${value}`)
  return token.value
}

/**
 * The motion presets. `curve` is the key into CURVES (a spring that bounces uses the bouncy
 * curve), and `swiftCurve` is the curve SwiftUI has a name for.
 */
const presets = Object.entries(tokens.motion.presets).map(([name, preset]) => ({
  name,
  curve: preset.curve === 'spring' && (preset.bounce ?? 0) > 0 ? 'springBouncy' : preset.curve,
  swiftCurve: preset.curve,
  seconds: duration(preset.duration),
  bounce: preset.bounce ?? 0,
  reduced: preset.reduced,
  doc: preset.doc,
}))
/** How long a preset takes under Reduce Motion: a short fade, or 0 when it just happens. */
const reducedSeconds = (preset) => (preset.reduced === 'fade' ? reducedFade : 0)

// =============================================================================================
// Sources: strings
// =============================================================================================

const KEY_PATTERN = /^[a-z0-9_]+(\.[a-z0-9_]+)+$/
const placeholders = (text) => [...text.matchAll(/\{([a-z_]+)\}/g)].map((match) => match[1])
const isPlural = (value) => typeof value === 'object'
/** The argument names of a string, in order. A placeholder's position is its index here plus one. */
const argList = (entry) => Object.keys(entry.args ?? {})

/** Reads every design/strings/*.json, checks each entry, and returns them sorted by key. */
function loadStrings() {
  const files = readdirSync(join(ROOT, 'design/strings')).filter((file) => file.endsWith('.json')).sort()
  const all = new Map()
  for (const file of files) {
    for (const [key, entry] of Object.entries(readJson(`design/strings/${file}`))) {
      if (!KEY_PATTERN.test(key)) fail(`${file}: bad key ${key}`)
      if (all.has(key)) fail(`${file}: duplicate key ${key}`)
      all.set(key, { ...entry, file })
    }
  }
  const sorted = [...all.entries()].sort(([a], [b]) => (a < b ? -1 : 1))
  for (const [key, entry] of sorted) checkString(key, entry)
  return new Map(sorted)
}

/** Fails unless a string has every language, uses its arguments well and has a translator note. */
function checkString(key, entry) {
  const args = entry.args ?? {}
  for (const [name, type] of Object.entries(args)) {
    if (!['string', 'int'].includes(type)) fail(`${key}: argument ${name} has type ${type}`)
  }
  const plural = isPlural(entry.en)
  if (plural && !Object.values(args).includes('int')) fail(`${key}: a plural needs an int argument`)
  for (const lang of LANGS) {
    const value = entry[lang]
    if (value === undefined || value === '') fail(`${key}: missing ${lang}`)
    if (isPlural(value) !== plural) fail(`${key}: ${lang} must ${plural ? 'be' : 'not be'} plural`)
    for (const text of plural ? Object.values(value) : [value]) {
      for (const name of placeholders(text)) {
        if (!(name in args)) fail(`${key}: ${lang} uses {${name}} which is not in args`)
      }
      if (/\u2014|;/.test(text)) fail(`${key}: ${lang} has a long dash or semicolon`)
    }
    if (plural) {
      if (!('other' in value)) fail(`${key}: ${lang} needs an "other" form`)
    } else {
      const used = new Set(placeholders(value))
      for (const name of Object.keys(args)) {
        if (!used.has(name)) fail(`${key}: ${lang} does not use {${name}}`)
      }
    }
  }
  if (typeof entry.note !== 'string' || !entry.note) fail(`${key}: add a note for translators`)
}

const allStrings = loadStrings()
/** The terminal app's words (keys that start with cli.). They go to its own table only. */
const terminalStrings = new Map([...allStrings].filter(([key]) => key.startsWith('cli.')))
/** The words of every other platform. */
const strings = new Map([...allStrings].filter(([key]) => !key.startsWith('cli.')))

// =============================================================================================
// Sources: components
// =============================================================================================

const TOKEN_REFERENCE = /^(color|spacing|radius|size|icon|stroke|opacity|type|motion|shadow)\.([A-Za-z]+)$/
/** The token group each kind of reference points into. */
const GROUPS = {
  color: tokens.colors,
  spacing: tokens.spacing,
  radius: tokens.radius,
  size: tokens.size,
  icon: tokens.icon,
  stroke: tokens.stroke,
  opacity: tokens.opacity,
  type: tokens.type,
  motion: tokens.motion.presets,
  shadow: tokens.shadows,
}

/**
 * Reads one property of a component: { kind, name } for a token reference like "radius.pebble",
 * or { kind: 'number' | 'word', value } for a plain value.
 */
function parseProperty(component, prop, value) {
  if (typeof value === 'number') return { kind: 'number', value }
  const match = TOKEN_REFERENCE.exec(value)
  if (!match) return { kind: 'word', value }
  const [, kind, name] = match
  if (!(name in GROUPS[kind])) fail(`components.json: ${component}.${prop} refers to ${value}, which does not exist`)
  return { kind, name }
}

/** The components in the order of design/components.json, each with its properties parsed into `refs`. */
const components = Object.entries(readJson('design/components.json'))
  .filter(([key]) => key !== '_note')
  .map(([key, component]) => {
    if (!component.doc || !component.props || !Array.isArray(component.rules)) {
      fail(`components.json: ${key} needs doc, props and rules`)
    }
    const refs = Object.entries(component.props).map(([prop, value]) => ({ prop, ...parseProperty(key, prop, value) }))
    return { key, ...component, refs }
  })

const componentNamed = (key) => components.find((component) => component.key === key)
/** One property of a component, or undefined when it has none. */
const propertyOf = (component, prop) => component.refs.find((ref) => ref.prop === prop)

/** The length in pixels of a spacing, radius, stroke, size or icon reference on one platform. */
function lengthOf(ref, platform) {
  if (ref.kind === 'size') return tokens.size[ref.name][platform]
  if (ref.kind === 'icon') return tokens.icon[ref.name].size
  return GROUPS[ref.kind][ref.name].value
}

// =============================================================================================
// Apple: Swift tokens, String Catalogs and presets
// =============================================================================================

const SWIFT_WEIGHTS = { 400: 'regular', 500: 'medium', 600: 'semibold', 700: 'bold', 800: 'heavy' }

function swiftTokens() {
  const color = (hex) => {
    const c = parseColor(hex)
    const base = `Color(red: ${c.r} / 255, green: ${c.g} / 255, blue: ${c.b} / 255)`
    return c.a === 255 ? base : `${base}.opacity(${alpha(c)})`
  }
  const rgba = (hex) => {
    const c = parseColor(hex)
    return `(${c.r}, ${c.g}, ${c.b}, ${alpha(c)})`
  }
  const doc = (text, indent = '    ') => (text ? `${indent}/// ${text}\n` : '')

  let out = `// ${TOKENS_NOTE}\n\nimport SwiftUI\n#if canImport(UIKit)\nimport UIKit\n#elseif canImport(AppKit)\nimport AppKit\n#endif\n\n`

  out += `/// The palette. A colour that differs between Light and Dark follows the appearance of the view it is drawn in.\npublic enum Tone {\n`
  for (const [name, c] of Object.entries(tokens.colors)) {
    const value = c.dark === c.light ? color(c.dark) : `Color(light: ${rgba(c.light)}, dark: ${rgba(c.dark)})`
    out += `${doc(c.doc)}    public static let ${name} = ${value}\n`
  }
  out += `}\n\n`

  out += `extension Color {
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

  out += `/// How a floating thing lifts off the surface.\npublic enum Elevation {\n`
  for (const [name, shadow] of shadows) {
    out += doc(shadow.doc)
    out += `    public static let ${name}Y: CGFloat = ${shadow.y}\n`
    out += `    public static let ${name}Blur: CGFloat = ${shadow.blur}\n`
    out += `    public static let ${name}Color = Color(light: ${rgba(shadow.color.light)}, dark: ${rgba(shadow.color.dark)})\n`
  }
  out += `}\n\n`

  const scales = [
    ['Radius', radii, 'Corner radii, one scale for everything.'],
    ['Spacing', spacings, 'Spacing, one scale for gaps and padding.'],
    ['Stroke', strokes, 'Line widths.'],
  ]
  for (const [title, scale, text] of scales) {
    out += `/// ${text}\npublic enum ${title} {\n`
    for (const [name, t] of scale) out += `${doc(t.doc)}    public static let ${name}: CGFloat = ${t.value}\n`
    out += `}\n\n`
  }

  out += `/// Opacities, one scale for dimming and soft fills.\npublic enum Opacity {\n`
  for (const [name, t] of opacities) out += `${doc(t.doc)}    public static let ${name}: Double = ${t.value}\n`
  out += `}\n\n`

  out += `/// Sizes of things you point at.\npublic enum Sizing {\n`
  out += sizes
    .map(([name, t]) => `${doc(t.doc)}    public static var ${name}: CGFloat {\n        #if os(iOS)\n        ${t.ios}\n        #else\n        ${t.macos}\n        #endif\n    }\n`)
    .join('\n')
  out += `}\n\n`

  out += `/// The type scale, as named styles. \`Typeface\` turns them into fonts.\npublic enum TypeScale {\n`
  for (const [name, t] of types) {
    const design = t.design === 'mono' ? '.monospaced' : `.${t.design}`
    out += `${doc(t.doc)}    public static let ${name} = TypeToken(size: ${t.size}, weight: .${SWIFT_WEIGHTS[t.weight]}, design: ${design}, style: .${t.appleStyle})\n`
  }
  out += `}\n\n`

  out += `/// Icon sizes. On the iPhone an icon follows Dynamic Type with its text style, on the Mac it is a fixed size.\npublic enum IconSize: Sendable {\n`
  for (const [name, t] of icons) out += `${doc(t.doc)}    case ${name}\n`
  out += `\n    /// The size in points on the Mac, and at the default text size on the iPhone.\n    public var points: CGFloat {\n        switch self {\n`
  for (const [name, t] of icons) out += `        case .${name}: ${t.size}\n`
  out += `        }\n    }\n\n    /// The text style the icon grows with on the iPhone.\n    public var textStyle: Font.TextStyle {\n        switch self {\n`
  for (const [name, t] of icons) out += `        case .${name}: .${t.appleStyle}\n`
  out += `        }\n    }\n}\n\n`

  out += `/// How long things animate.\npublic enum Timing {\n`
  for (const [name, d] of durations) out += `${doc(d.doc)}    public static let ${name} = ${d.value}\n`
  out += `    /// With Reduce Motion, a preset that fades changes opacity over this long.\n    public static let reducedFade = ${reducedFade}\n}\n\n`

  out += `/// The named animations, with what each does when Reduce Motion is on.\npublic enum Motion {\n`
  for (const p of presets) {
    const animation = p.swiftCurve === 'spring' ? `.spring(duration: ${p.seconds}, bounce: ${p.bounce})` : `.${p.swiftCurve}(duration: ${p.seconds})`
    const reduced = p.reduced === 'fade' ? '.easeOut(duration: Timing.reducedFade)' : 'nil'
    out += `${doc(p.doc)}    public static let ${p.name} = MotionPreset(${animation}, reduced: ${reduced})\n`
  }
  out += `}\n\n`

  out += `/// Numbers that behaviour rules share on every platform.\npublic enum Behavior {\n`
  for (const [name, b] of behavior) out += `${doc(b.doc)}    public static let ${name} = ${b.value}\n`
  out += `}\n`
  return out
}

/** Apple's format: positional specifiers (%1$@ for a string, %1$lld for an int) and % escaped. */
function appleText(entry, text) {
  const args = argList(entry)
  return text.replace(/%/g, '%%').replace(/\{([a-z_]+)\}/g, (_, name) => {
    const position = args.indexOf(name) + 1
    return entry.args[name] === 'int' ? `%${position}$lld` : `%${position}$@`
  })
}

/** JSON in Xcode's own style ("key" : value), so a regenerated catalog differs only where text changed. */
function xcodeJson(value, indent = '') {
  const inner = indent + '  '
  if (Array.isArray(value)) {
    if (!value.length) return `[\n\n${indent}]`
    return `[\n${value.map((item) => `${inner}${xcodeJson(item, inner)}`).join(',\n')}\n${indent}]`
  }
  if (value && typeof value === 'object') {
    const keys = Object.keys(value)
    if (!keys.length) return `{\n\n${indent}}`
    return `{\n${keys.map((key) => `${inner}${JSON.stringify(key)} : ${xcodeJson(value[key], inner)}`).join(',\n')}\n${indent}}`
  }
  return JSON.stringify(value)
}

/**
 * A String Catalog with the keyed words written in. Keys made here look like "area.thing".
 * Every other key in the catalog belongs to the app's own code and stays as it is.
 */
function stringCatalog(path) {
  const current = readJson(path)
  const unit = (value) => ({ stringUnit: { state: 'translated', value } })
  const next = {}
  for (const [key, entry] of Object.entries(current.strings)) {
    if (!KEY_PATTERN.test(key)) next[key] = entry
  }
  for (const [key, entry] of strings) {
    const localizations = {}
    for (const lang of LANGS) {
      const value = entry[lang]
      localizations[lang] = isPlural(value)
        ? { variations: { plural: Object.fromEntries(Object.entries(value).map(([form, text]) => [form, unit(appleText(entry, text))])) } }
        : unit(appleText(entry, value))
    }
    next[key] = { comment: entry.note, extractionState: 'manual', localizations }
  }
  current.strings = next
  return xcodeJson(current) // Xcode writes no final newline, and neither does this.
}

/**
 * Text in a Swift raw string (#"""...."""#) ends at the first "#, so the source must not hold one.
 */
function swiftRawString(text, source) {
  if (text.includes('"#')) fail(`${source} cannot hold "# (it ends the Swift raw string)`)
  return `#"""\n${text}\n"""#`
}

const servicesSource = 'spec/presets/services.json'

/** The services preset, checked: its text and what it holds. */
function readServices() {
  const servicesText = read(servicesSource)
  const services = JSON.parse(servicesText)
  const ids = services.services.map((service) => service.id)
  if (new Set(ids).size !== ids.length) fail(`${servicesSource}: an id is used twice`)
  if (!ids.includes(services.default)) fail(`${servicesSource}: the default ${services.default} is not a service`)
  for (const service of services.services) {
    if (!/^https?:\/\//.test(service.baseURL)) fail(`${servicesSource}: ${service.id} needs an http(s) baseURL`)
    if (!/^https:\/\//.test(service.link)) fail(`${servicesSource}: ${service.id} needs an https link`)
    if (typeof service.local !== 'boolean' || !service.symbol) fail(`${servicesSource}: ${service.id} needs local and symbol`)
  }
  return { servicesText, services }
}

/** The presets the apps offer, as data: the services. */
function bundledPresets() {
  const { servicesText } = readServices()
  return `// ${generatedFrom('spec/presets')}\n\n` +
    `/// The presets as their JSON files. Compiled in, so no resource bundle has to be found at run time.\n` +
    `enum Presets {\n` +
    `    /// ${servicesSource}: the services offered when adding one.\n` +
    `    static let servicesJSON = ${swiftRawString(servicesText.trimEnd(), servicesSource)}\n}\n`
}

// =============================================================================================
// Web: the browser extension's tokens and words
// =============================================================================================

function webCss() {
  const colors = (appearance) => {
    let out = ''
    for (const name of colorNames) out += `  --${kebab(name)}: ${cssColor(tokens.colors[name][appearance])};\n`
    for (const [name, shadow] of shadows) out += `  --shadow-${kebab(name)}: 0 ${shadow.y}px ${shadow.blur}px ${cssColor(shadow.color[appearance])};\n`
    return out
  }
  let out = `/* ${TOKENS_NOTE} */\n:root {\n  color-scheme: dark;\n${colors('dark')}`
  for (const [name, t] of spacings) out += `  --space-${kebab(name)}: ${t.value}px;\n`
  for (const [name, t] of radii) out += `  --radius-${kebab(name)}: ${t.value}px;\n`
  for (const [name, t] of strokes) out += `  --stroke-${kebab(name)}: ${t.value}px;\n`
  for (const [name, t] of opacities) out += `  --opacity-${kebab(name)}: ${t.value};\n`
  for (const [name, t] of sizes) out += `  --size-${kebab(name)}: ${t.macos}px;\n`
  for (const [name, t] of icons) out += `  --icon-${kebab(name)}: ${t.size}px;\n`
  for (const [name, t] of types) out += `  --type-${kebab(name)}-size: ${t.size}px;\n  --type-${kebab(name)}-weight: ${t.weight};\n`
  for (const [name, d] of durations) out += `  --duration-${kebab(name)}: ${d.value}s;\n`
  for (const p of presets) out += `  --motion-${kebab(p.name)}: ${p.seconds}s cubic-bezier(${CURVES[p.curve].join(', ')});\n`
  for (const [name, b] of behavior) out += `  --behavior-${kebab(name)}: ${b.value};\n`
  out += `}\n@media (prefers-color-scheme: light) {\n  :root {\n    color-scheme: light;\n`
  out += colors('light').replace(/^/gm, '  ').replace(/ +$/gm, '')
  out += `  }\n}\n@media (prefers-reduced-motion: reduce) {\n  :root {\n`
  for (const p of presets) out += `    --motion-${kebab(p.name)}: ${p.reduced === 'fade' ? `${reducedFade}s ease-out` : '0s linear'};\n`
  out += `  }\n}\n`
  return out
}

/** chrome.i18n messages: the key with underscores, {name} as $1, $2 in the order of the arguments, and $ doubled. */
function extensionLocales() {
  const folders = { en: 'en', es: 'es', 'zh-Hans': 'zh_CN' }
  return LANGS.map((lang) => {
    const messages = {}
    for (const [key, entry] of strings) {
      if (!key.startsWith('extension.')) continue
      if (isPlural(entry[lang])) fail(`${key}: the extension has no plurals`)
      const args = argList(entry)
      const message = entry[lang].replace(/\$/g, '$$$$').replace(/\{([a-z_]+)\}/g, (_, name) => `$${args.indexOf(name) + 1}`)
      messages[key.replace(/\./g, '_')] = { message, description: entry.note }
    }
    return [`extension/_locales/${folders[lang]}/messages.json`, JSON.stringify(messages, null, 2) + '\n']
  })
}

// =============================================================================================
// Android: Compose tokens and components, string resources
// =============================================================================================

/** A Kotlin Float literal. */
const kotlinFloat = (n) => `${n}f`

function kotlinTokens() {
  const color = (hex) => `Color(0x${argb(hex)})`
  const object = (name, lines) => `object ${name} {\n${lines.join('\n')}\n}\n\n`

  let out = `// ${TOKENS_NOTE}\npackage app.imp.design\n\n`
  out += `import androidx.compose.animation.core.CubicBezierEasing\nimport androidx.compose.animation.core.TweenSpec\nimport androidx.compose.animation.core.tween\n`
  out += `import android.provider.Settings\nimport androidx.compose.foundation.isSystemInDarkTheme\nimport androidx.compose.runtime.Composable\nimport androidx.compose.runtime.CompositionLocalProvider\nimport androidx.compose.runtime.remember\nimport androidx.compose.runtime.staticCompositionLocalOf\n`
  out += `import androidx.compose.ui.graphics.Color\nimport androidx.compose.ui.platform.LocalContext\nimport androidx.compose.ui.text.font.FontWeight\nimport androidx.compose.ui.unit.Dp\nimport androidx.compose.ui.unit.dp\nimport androidx.compose.ui.unit.sp\n\n`

  out += `/** The colours of one appearance. */\nclass ImpPalette(\n`
  out += colorNames.map((name) => `    val ${name}: Color,`).join('\n') + `\n)\n\n`
  for (const appearance of ['dark', 'light']) {
    out += `val Imp${pascal(appearance)}Palette = ImpPalette(\n`
    out += colorNames.map((name) => `    ${name} = ${color(tokens.colors[name][appearance])},`).join('\n') + `\n)\n\n`
  }
  out += `/** The palette of the current appearance. Read colours from here, never as a literal. */\nval LocalImpPalette = staticCompositionLocalOf { ImpDarkPalette }\n\n`
  out += `/** Gives everything inside the right palette: dark or light, following the system unless told. */\n@Composable\nfun ImpTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {\n    CompositionLocalProvider(LocalImpPalette provides if (dark) ImpDarkPalette else ImpLightPalette, content = content)\n}\n\n`
  out += `/** True when the person turned animations off in the system settings (Reduce Motion). */\n@Composable\nfun rememberReduceMotion(): Boolean {\n    val resolver = LocalContext.current.contentResolver\n    return remember { Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }\n}\n\n`

  out += `/** How a floating thing lifts off the surface. */\nclass ImpShadow(val y: Dp, val blur: Dp, val dark: Color, val light: Color) {\n    fun color(isDark: Boolean) = if (isDark) dark else light\n}\n\n`
  out += object('ImpShadows', shadows.map(([name, s]) => `    val ${name} = ImpShadow(${s.y}.dp, ${s.blur}.dp, ${color(s.color.dark)}, ${color(s.color.light)})`))
  out += object('ImpSpacing', spacings.map(([name, t]) => `    val ${name} = ${t.value}.dp`))
  out += object('ImpRadius', radii.map(([name, t]) => `    val ${name} = ${t.value}.dp`))
  out += object('ImpStroke', strokes.map(([name, t]) => `    val ${name} = ${t.value}.dp`))
  out += object('ImpOpacity', opacities.map(([name, t]) => `    const val ${name} = ${t.value}f`))
  out += object('ImpSizing', sizes.map(([name, t]) => `    /** ${t.doc} */\n    val ${name} = ${t.android}.dp`))
  out += `/** Icon sizes (dp at the default font scale). */\n`
  out += object('ImpIcon', icons.map(([name, t]) => `    val ${name} = ${t.size}.dp`))

  out += `/** One text style: size in sp (the phone size follows the system font scale), weight and design. */\n`
  out += `class ImpTextStyle(val size: androidx.compose.ui.unit.TextUnit, val weight: FontWeight, val design: String)\n\n`
  out += object('ImpType', types.map(([name, t]) => `    val ${name} = ImpTextStyle(${t.phoneSize}.sp, FontWeight(${t.weight}), "${t.design}")`))

  out += `/** One animation. With Reduce Motion it takes \`reducedDurationMillis\` (0 means it just happens). */\n`
  out += `class ImpMotion(val durationMillis: Int, val easing: CubicBezierEasing, val reducedDurationMillis: Int) {\n`
  out += `    fun <T> spec(reduceMotion: Boolean): TweenSpec<T> =\n        tween(if (reduceMotion) reducedDurationMillis else durationMillis, easing = easing)\n}\n\n`
  out += object('ImpMotions', presets.map((p) => {
    const easing = `CubicBezierEasing(${CURVES[p.curve].map(kotlinFloat).join(', ')})`
    return `    val ${p.name} = ImpMotion(${milliseconds(p.seconds)}, ${easing}, ${milliseconds(reducedSeconds(p))})`
  }))
  out += object('ImpBehavior', behavior.map(([name, b]) => `    val ${name} = ${b.value}${Number.isInteger(b.value) ? '' : 'f'}`))
  return out.replace(/\n\n$/, '\n')
}

function kotlinComponents() {
  let out = `// ${COMPONENTS_NOTE}\npackage app.imp.design\n\nimport androidx.compose.ui.graphics.Color\nimport androidx.compose.ui.unit.Dp\n\n`
  out += `/** The Pebble components as specs: tokens in, no behaviour. Colours are functions of the palette, so one spec serves light and dark. */\nobject ImpComponents {\n`
  // How each kind of property is declared, given its Kotlin name and the reference.
  const declarations = {
    color: (n, r) => `val ${n}: (ImpPalette) -> Color = { it.${r.name} }`,
    spacing: (n, r) => `val ${n}: Dp = ImpSpacing.${r.name}`,
    radius: (n, r) => `val ${n}: Dp = ImpRadius.${r.name}`,
    stroke: (n, r) => `val ${n}: Dp = ImpStroke.${r.name}`,
    size: (n, r) => `val ${n}: Dp = ImpSizing.${r.name}`,
    icon: (n, r) => `val ${n}: Dp = ImpIcon.${r.name}`,
    opacity: (n, r) => `const val ${n}: Float = ImpOpacity.${r.name}`,
    type: (n, r) => `val ${n}: ImpTextStyle = ImpType.${r.name}`,
    motion: (n, r) => `val ${n}: ImpMotion = ImpMotions.${r.name}`,
    shadow: (n, r) => `val ${n}: ImpShadow = ImpShadows.${r.name}`,
    number: (n, r) => `const val ${n}: Float = ${kotlinFloat(r.value)}`,
    word: (n, r) => `const val ${n}: String = "${r.value}"`,
  }
  const blocks = components.map((component) => {
    let block = `    /** ${component.doc} */\n    object ${pascalKey(component.key)} {\n`
    for (const ref of component.refs) block += `        ${declarations[ref.kind](camel(ref.prop), ref)}\n`
    return block + `    }\n`
  })
  return out + blocks.join('\n') + `}\n`
}

/** Android's string format: XML and apostrophes escaped, {name} as %1$s or %1$d. */
function androidText(entry, text) {
  const args = argList(entry)
  const escaped = text
    .replace(/\\/g, '\\\\')
    .replace(/'/g, "\\'")
    .replace(/"/g, '\\"')
    .replace(/%/g, '%%')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/^([@?])/, '\\$1')
    .replace(/\n/g, '\\n')
  return escaped.replace(/\{([a-z_]+)\}/g, (_, name) => `%${args.indexOf(name) + 1}$${entry.args[name] === 'int' ? 'd' : 's'}`)
}

function androidStrings() {
  const file = (lang) => {
    let out = `<?xml version="1.0" encoding="utf-8"?>\n<!-- ${STRINGS_NOTE} -->\n<resources>\n`
    for (const [key, entry] of strings) {
      const name = key.replace(/\./g, '_')
      const value = entry[lang]
      if (isPlural(value)) {
        const forms = { ...value }
        // Android asks for a "many" form in Spanish. It reads like "other".
        if (lang === 'es' && !forms.many) forms.many = forms.other
        const items = Object.entries(forms).map(([quantity, text]) => `    <item quantity="${quantity}">${androidText(entry, text)}</item>`)
        out += `  <plurals name="${name}">\n${items.join('\n')}\n  </plurals>\n`
      } else {
        out += `  <string name="${name}">${androidText(entry, value)}</string>\n`
      }
    }
    return out + `</resources>\n`
  }
  return [
    ['design/generated/android/values/strings.xml', file('en')],
    ['design/generated/android/values-es/strings.xml', file('es')],
    ['design/generated/android/values-b+zh+Hans/strings.xml', file('zh-Hans')],
  ]
}

// =============================================================================================
// Windows: XAML resources and styles, C# constants, .resw strings
// =============================================================================================

const XAML_HEADER = `<ResourceDictionary\n    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"\n    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">\n\n`
const XAML_WEIGHTS = { 400: 'Normal', 500: 'Medium', 600: 'SemiBold', 700: 'Bold', 800: 'ExtraBold' }
const xamlBrush = (colorName) => `Imp${pascal(colorName)}Brush`
const escapeXml = (text) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

function xamlTokens() {
  const theme = (key, appearance) => {
    let out = `    <ResourceDictionary x:Key="${key}">\n`
    for (const name of colorNames) {
      const color = `#${argb(tokens.colors[name][appearance])}`
      out += `      <Color x:Key="Imp${pascal(name)}Color">${color}</Color>\n      <SolidColorBrush x:Key="${xamlBrush(name)}" Color="${color}"/>\n`
    }
    return out + `    </ResourceDictionary>\n`
  }
  const timeSpan = (seconds) => `0:0:${seconds}`

  let out = `<?xml version="1.0" encoding="utf-8"?>\n<!-- ${TOKENS_NOTE} -->\n${XAML_HEADER}`
  out += `  <ResourceDictionary.ThemeDictionaries>\n${theme('Default', 'dark')}${theme('Light', 'light')}  </ResourceDictionary.ThemeDictionaries>\n\n`
  for (const [name, t] of spacings) out += `  <x:Double x:Key="ImpSpace${pascal(name)}">${t.value}</x:Double>\n`
  for (const [name, t] of radii) out += `  <CornerRadius x:Key="ImpRadius${pascal(name)}">${t.value}</CornerRadius>\n`
  for (const [name, t] of strokes) out += `  <x:Double x:Key="ImpStroke${pascal(name)}">${t.value}</x:Double>\n`
  for (const [name, t] of opacities) out += `  <x:Double x:Key="ImpOpacity${pascal(name)}">${t.value}</x:Double>\n`
  for (const [name, t] of sizes) out += `  <x:Double x:Key="ImpSize${pascal(name)}">${t.windows}</x:Double>\n`
  for (const [name, t] of icons) out += `  <x:Double x:Key="ImpIcon${pascal(name)}">${t.size}</x:Double>\n`
  for (const [name, t] of types) {
    out += `  <x:Double x:Key="ImpType${pascal(name)}Size">${t.size}</x:Double>\n`
    out += `  <FontWeight x:Key="ImpType${pascal(name)}Weight">${XAML_WEIGHTS[t.weight]}</FontWeight>\n`
  }
  for (const p of presets) {
    const key = `ImpMotion${pascal(p.name)}`
    out += `  <Duration x:Key="${key}Duration">${timeSpan(p.seconds)}</Duration>\n`
    out += `  <Duration x:Key="${key}ReducedDuration">${timeSpan(reducedSeconds(p))}</Duration>\n`
    out += `  <x:String x:Key="${key}Easing">${CURVES[p.curve].join(',')}</x:String>\n`
  }
  for (const [name, b] of behavior) out += `  <x:Double x:Key="ImpBehavior${pascal(name)}">${b.value}</x:Double>\n`
  return out + `</ResourceDictionary>\n`
}

function xamlComponents() {
  const length = (ref) => lengthOf(ref, 'windows')
  let out = `<?xml version="1.0" encoding="utf-8"?>\n<!-- ${COMPONENTS_NOTE} -->\n${XAML_HEADER}`

  out += `  <!-- Merge ImpTokens.xaml first. Every property of a component is a resource: ImpPebbleRadius, ImpRowMinHeight, ... A colour is the key of its brush. -->\n`
  for (const component of components) {
    for (const ref of component.refs) {
      const key = `Imp${pascalKey(component.key)}${pascal(ref.prop)}`
      switch (ref.kind) {
        case 'color': out += `  <x:String x:Key="${key}Brush">${xamlBrush(ref.name)}</x:String>\n`; break
        case 'radius': out += `  <CornerRadius x:Key="${key}">${length(ref)}</CornerRadius>\n`; break
        case 'spacing': case 'size': case 'icon': case 'stroke': out += `  <x:Double x:Key="${key}">${length(ref)}</x:Double>\n`; break
        case 'opacity': out += `  <x:Double x:Key="${key}">${tokens.opacity[ref.name].value}</x:Double>\n`; break
        case 'number': out += `  <x:Double x:Key="${key}">${ref.value}</x:Double>\n`; break
        case 'word': out += `  <x:String x:Key="${key}">${ref.value}</x:String>\n`; break
        case 'type': out += `  <x:Double x:Key="${key}Size">${tokens.type[ref.name].size}</x:Double>\n`; break
        default: break // Motion and shadow references get no resource here.
      }
    }
  }

  out += `\n  <!-- Styles for the components that are one element. The rest are built from the resources above. -->\n`
  /** A Border style for a component that is one filled box. */
  const boxStyle = (key, extra = '') => {
    const get = (prop) => propertyOf(componentNamed(key), prop)
    let style = `  <Style x:Key="Imp${pascalKey(key)}Style" TargetType="Border">\n`
    if (get('fill')) style += `    <Setter Property="Background" Value="{ThemeResource ${xamlBrush(get('fill').name)}}"/>\n`
    if (get('radius')) style += `    <Setter Property="CornerRadius" Value="${length(get('radius'))}"/>\n`
    if (get('padding')) style += `    <Setter Property="Padding" Value="${length(get('padding'))}"/>\n`
    if (get('paddingX')) style += `    <Setter Property="Padding" Value="${length(get('paddingX'))},${length(get('paddingY'))}"/>\n`
    return style + `    <Setter Property="BorderThickness" Value="0"/>\n${extra}  </Style>\n`
  }
  for (const key of ['pebble', 'surface', 'popover', 'bubble', 'barMenu', 'undoBar', 'badge']) out += boxStyle(key)
  out += boxStyle('infoTip', `    <Setter Property="MaxWidth" Value="${length(propertyOf(componentNamed('infoTip'), 'maxWidth'))}"/>\n`)
  for (const key of ['button.primary', 'button.secondary', 'button.quiet', 'button.destructive']) out += xamlButtonStyle(key)
  return out + `\n</ResourceDictionary>\n`
}

/** A Button style with its own template, so hover and press follow the spec, not WinUI's defaults. */
function xamlButtonStyle(key) {
  const length = (ref) => lengthOf(ref, 'windows')
  const get = (prop) => propertyOf(componentNamed(key), prop)
  const brush = (ref) => `{ThemeResource ${xamlBrush(ref.name)}}`
  const fill = get('fill')
  const base = fill.kind === 'color' ? brush(fill) : 'Transparent'
  // The primary button brightens on hover. The others take their fillHover, or stay as they are.
  const hover = get('fillHover') ? brush(get('fillHover')) : key === 'button.primary' ? brush({ name: 'accentBright' }) : base
  const text = brush(get('text'))
  const textHover = get('textHover') ? brush(get('textHover')) : text

  let out = `  <Style x:Key="Imp${pascalKey(key)}Style" TargetType="Button">\n`
  out += `    <Setter Property="Background" Value="${base}"/>\n    <Setter Property="Foreground" Value="${text}"/>\n`
  out += `    <Setter Property="CornerRadius" Value="${length(get('radius'))}"/>\n    <Setter Property="Padding" Value="${length(get('paddingX'))},${length(get('paddingY'))}"/>\n`
  out += `    <Setter Property="MinHeight" Value="${length(get('minHeight'))}"/>\n    <Setter Property="FontSize" Value="${tokens.type[get('type').name].size}"/>\n    <Setter Property="BorderThickness" Value="0"/>\n`
  out += `    <Setter Property="Template">\n      <Setter.Value>\n        <ControlTemplate TargetType="Button">\n`
  out += `          <Border x:Name="Root" Background="{TemplateBinding Background}" CornerRadius="{TemplateBinding CornerRadius}" Padding="{TemplateBinding Padding}">\n`
  out += `            <ContentPresenter x:Name="Content" Foreground="{TemplateBinding Foreground}" HorizontalAlignment="Center" VerticalAlignment="Center"/>\n`
  out += `            <VisualStateManager.VisualStateGroups>\n              <VisualStateGroup x:Name="CommonStates">\n                <VisualState x:Name="Normal"/>\n`
  out += `                <VisualState x:Name="PointerOver">\n                  <VisualState.Setters>\n                    <Setter Target="Root.Background" Value="${hover}"/>\n                    <Setter Target="Content.Foreground" Value="${textHover}"/>\n                  </VisualState.Setters>\n                </VisualState>\n`
  out += `                <VisualState x:Name="Pressed">\n                  <VisualState.Setters>\n                    <Setter Target="Root.Background" Value="${hover}"/>\n                    <Setter Target="Root.Opacity" Value="${tokens.opacity.dimmed.value}"/>\n                  </VisualState.Setters>\n                </VisualState>\n`
  out += `                <VisualState x:Name="Disabled">\n                  <VisualState.Setters>\n                    <Setter Target="Root.Opacity" Value="${tokens.opacity.disabled.value}"/>\n                  </VisualState.Setters>\n                </VisualState>\n`
  out += `              </VisualStateGroup>\n            </VisualStateManager.VisualStateGroups>\n          </Border>\n`
  out += `        </ControlTemplate>\n      </Setter.Value>\n    </Setter>\n  </Style>\n`
  return out
}

function csharpTokens() {
  /** A static class of double constants, each with its doc comment. */
  const constants = (name, doc, entries) => {
    const members = entries.map(([member, value, memberDoc]) => `    /// <summary>${memberDoc}</summary>\n    public const double ${pascal(member)} = ${value};`)
    return `/// <summary>${doc}</summary>\npublic static class ${name}\n{\n${members.join('\n')}\n}\n\n`
  }
  let out = `// ${TOKENS_NOTE}\nnamespace Imp.Design;\n\n`
  out += constants('ImpSpace', 'Spacing in device independent pixels.', spacings.map(([name, t]) => [name, t.value, t.doc]))
  out += constants('ImpRadii', 'Corner radii.', radii.map(([name, t]) => [name, t.value, t.doc]))
  out += constants('ImpSizes', 'Sizes of things you point at, for Windows.', sizes.map(([name, t]) => [name, t.windows, t.doc]))
  out += constants('ImpIcons', 'Icon sizes.', icons.map(([name, t]) => [name, t.size, t.doc]))
  out += constants('ImpOpacities', 'Opacities.', opacities.map(([name, t]) => [name, t.value, t.doc]))
  out += constants('ImpType', 'Font sizes of the type scale (the weight and the rounded design are in ImpTokens.xaml).', types.map(([name, t]) => [name, t.size, t.doc]))
  out += `/// <summary>The named animations. A preset with no reduced duration just happens under Reduce Motion.</summary>\npublic static class ImpMotion\n{\n`
  out += `    /// <summary>With Reduce Motion, a preset that fades changes opacity over this long.</summary>\n    public static readonly System.TimeSpan ReducedFade = System.TimeSpan.FromSeconds(${reducedFade});\n\n`
  for (const p of presets) {
    const name = pascal(p.name)
    out += `    /// <summary>${p.doc}</summary>\n    public static readonly System.TimeSpan ${name} = System.TimeSpan.FromMilliseconds(${milliseconds(p.seconds)});\n`
    out += `    public static readonly System.TimeSpan ${name}Reduced = System.TimeSpan.FromMilliseconds(${milliseconds(reducedSeconds(p))});\n`
    out += `    public static readonly (double X1, double Y1, double X2, double Y2) ${name}Curve = (${CURVES[p.curve].join(', ')});\n`
  }
  return out + `}\n`
}

function reswStrings() {
  const header = `<?xml version="1.0" encoding="utf-8"?>\n<!-- ${STRINGS_NOTE} -->\n<root>\n`
    + `  <resheader name="resmimetype"><value>text/microsoft-resx</value></resheader>\n  <resheader name="version"><value>2.0</value></resheader>\n`
    + `  <resheader name="reader"><value>System.Resources.ResXResourceReader, System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089</value></resheader>\n`
    + `  <resheader name="writer"><value>System.Resources.ResXResourceWriter, System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089</value></resheader>\n`
  const data = (name, text, note) => `  <data name="${name}" xml:space="preserve"><value>${escapeXml(text)}</value><comment>${escapeXml(note)}</comment></data>\n`
  const file = (lang) => {
    let out = header
    for (const [key, entry] of strings) {
      const value = entry[lang]
      // A plural is one string per form, named key.one and key.other. The app picks the form.
      if (isPlural(value)) {
        for (const [form, text] of Object.entries(value)) out += data(`${key}.${form}`, text, entry.note)
      } else {
        out += data(key, value, entry.note)
      }
    }
    return out + `</root>\n`
  }
  return [
    ['design/generated/windows/en-US/Resources.resw', file('en')],
    ['design/generated/windows/es/Resources.resw', file('es')],
    ['design/generated/windows/zh-Hans/Resources.resw', file('zh-Hans')],
  ]
}

// =============================================================================================
// Linux: GTK colours, tokens and components, gettext catalogs
// =============================================================================================

/** The name of a colour token in GTK CSS: accentBright is @imp_accent_bright. */
const gtkColorName = (name) => `@imp_${name.replace(/[A-Z]/g, (letter) => '_' + letter.toLowerCase())}`

/**
 * One appearance's colours. GTK has no light and dark media rule before 4.20, so each appearance
 * is its own file. The app loads the one that matches Adw.StyleManager.
 */
function gtkColors(appearance) {
  const token = (name) => tokens.colors[name][appearance]
  // The libadwaita named colours that carry the look come first, then every token under its own name.
  const libadwaita = {
    window_bg_color: token('surface'), window_fg_color: token('text'),
    view_bg_color: token('surface'), view_fg_color: token('text'),
    headerbar_bg_color: token('surface'), headerbar_fg_color: token('text'), headerbar_border_color: 'transparent',
    card_bg_color: token('card'), card_fg_color: token('text'),
    popover_bg_color: token('raised'), popover_fg_color: token('text'),
    dialog_bg_color: token('surface'), dialog_fg_color: token('text'),
    sidebar_bg_color: token('surface'), sidebar_fg_color: token('text'),
    accent_bg_color: token('accent'), accent_fg_color: token('onAccent'), accent_color: token('accent'),
    destructive_bg_color: token('danger'), destructive_fg_color: token('ink'), destructive_color: token('danger'),
    success_color: token('good'), warning_color: token('warnText'), error_color: token('danger'),
  }
  let out = `/* ${TOKENS_NOTE} */\n/* ${appearance}: libadwaita named colours first, then every token as @imp_<name>. */\n`
  for (const [name, value] of Object.entries(libadwaita)) out += `@define-color ${name} ${value === 'transparent' ? value : cssColor(value)};\n`
  for (const name of colorNames) out += `@define-color ${gtkColorName(name).slice(1)} ${cssColor(token(name))};\n`
  for (const [name, shadow] of shadows) out += `@define-color imp_shadow_${name} ${cssColor(shadow.color[appearance])};\n`
  return out
}

function gtkTokens() {
  let out = `/* ${TOKENS_NOTE} */\n/* The numbers, as CSS custom properties (GTK 4.16 or newer). Colours are in imp-colors-dark.css and imp-colors-light.css. */\n:root {\n`
  for (const [name, t] of spacings) out += `  --imp-space-${kebab(name)}: ${t.value}px;\n`
  for (const [name, t] of radii) out += `  --imp-radius-${kebab(name)}: ${t.value}px;\n`
  for (const [name, t] of strokes) out += `  --imp-stroke-${kebab(name)}: ${t.value}px;\n`
  for (const [name, t] of opacities) out += `  --imp-opacity-${kebab(name)}: ${t.value};\n`
  for (const [name, t] of sizes) out += `  --imp-size-${kebab(name)}: ${t.linux}px;\n`
  for (const [name, t] of icons) out += `  --imp-icon-${kebab(name)}: ${t.size}px;\n`
  for (const [name, t] of types) out += `  --imp-type-${kebab(name)}-size: ${t.size}px;\n  --imp-type-${kebab(name)}-weight: ${t.weight};\n`
  out += `}\n\n/* One class per animation: duration and curve. With Reduce Motion (gtk-enable-animations off) GTK skips transitions. */\n`
  for (const p of presets) {
    out += `.imp-motion-${kebab(p.name)} { transition-duration: ${milliseconds(p.seconds)}ms; transition-timing-function: cubic-bezier(${CURVES[p.curve].join(', ')}); }\n`
  }
  return out
}

function gtkComponents() {
  const px = (ref) => lengthOf(ref, 'linux')
  let out = `/* ${COMPONENTS_NOTE} */\n/* One class per component. Load imp-colors-dark.css or imp-colors-light.css first. */\n\n`
  for (const component of components) {
    const get = (prop) => propertyOf(component, prop)
    const selector = `.imp-${component.key.replace(/\./g, '-').replace(/[A-Z]/g, (letter) => '-' + letter.toLowerCase())}`
    const declarations = []
    const fill = get('fill')
    const type = get('type')
    const shadow = get('shadow')
    if (fill) declarations.push(fill.kind === 'color' ? `background-color: ${gtkColorName(fill.name)}` : 'background: none')
    if (get('text')) declarations.push(`color: ${gtkColorName(get('text').name)}`)
    if (get('radius')) declarations.push(`border-radius: ${px(get('radius'))}px`)
    if (get('padding')) declarations.push(`padding: ${px(get('padding'))}px`)
    if (get('paddingX')) declarations.push(`padding: ${get('paddingY') ? px(get('paddingY')) : 0}px ${px(get('paddingX'))}px`)
    if (get('minHeight')) declarations.push(`min-height: ${px(get('minHeight'))}px`)
    if (get('height')) declarations.push(`min-height: ${px(get('height'))}px`)
    if (get('maxWidth')) declarations.push(`max-width: ${px(get('maxWidth'))}px`)
    if (get('width')) declarations.push(`min-width: ${px(get('width'))}px`)
    if (type) declarations.push(`font-size: ${tokens.type[type.name].size}px`, `font-weight: ${tokens.type[type.name].weight}`)
    if (shadow) {
      const s = tokens.shadows[shadow.name]
      declarations.push(shadow.kind === 'shadow' ? `box-shadow: 0 ${s.y}px ${s.blur}px @imp_shadow_${shadow.name}` : 'box-shadow: none')
    }
    declarations.push('border: none')

    out += `/* ${component.doc} */\n${selector} {\n${declarations.map((declaration) => `  ${declaration};`).join('\n')}\n}\n`
    if (get('fillHover')) out += `${selector}:hover { background-color: ${gtkColorName(get('fillHover').name)}; }\n`
    if (get('textHover')) out += `${selector}:hover { color: ${gtkColorName(get('textHover').name)}; }\n`
    if (component.key === 'button.primary') out += `${selector}:hover { background-color: ${gtkColorName('accentBright')}; }\n`
    out += component.key.startsWith('button.') ? `${selector}:disabled { opacity: ${tokens.opacity.disabled.value}; }\n\n` : '\n'
  }
  out += `/* The focus ring of every control: keyboard focus only. */\n`
  out += `*:focus-visible { outline: ${tokens.stroke.focus.value}px solid ${gtkColorName('focus')}; outline-offset: ${tokens.spacing.hairline.value}px; }\n`
  return out
}

/** gettext catalogs: the key is the message context (msgctxt) and the English text the message id. */
function gettextCatalogs() {
  const quote = (text) => JSON.stringify(text)
  const entry = (key, string, lang) => {
    const english = string.en
    let out = `#. ${string.note}\nmsgctxt ${quote(key)}\n`
    if (isPlural(english)) {
      out += `msgid ${quote(english.one ?? english.other)}\nmsgid_plural ${quote(english.other)}\n`
      // The template leaves the translations empty. Chinese has one plural form, Spanish two.
      const value = string[lang]
      const forms = lang === 'en' ? ['', ''] : lang === 'zh-Hans' ? [value.other] : [value.one ?? value.other, value.other]
      forms.forEach((text, index) => { out += `msgstr[${index}] ${quote(text)}\n` })
    } else {
      out += `msgid ${quote(english)}\nmsgstr ${quote(lang === 'en' ? '' : string[lang])}\n`
    }
    return out + '\n'
  }
  const header = (code) => {
    const single = code === 'zh_Hans'
    const language = code ? `"Language: ${code}\\n"\n` : ''
    return `# ${STRINGS_NOTE}\nmsgid ""\nmsgstr ""\n"Content-Type: text/plain; charset=UTF-8\\n"\n${language}` +
      `"Plural-Forms: nplurals=${single ? 1 : 2}; plural=${single ? '0' : '(n != 1)'};\\n"\n\n`
  }
  const file = (lang, code) => header(code) + [...strings].map(([key, string]) => entry(key, string, lang)).join('')
  return [
    ['design/generated/gettext/imp.pot', file('en', '')],
    ['design/generated/gettext/es.po', file('es', 'es')],
    ['design/generated/gettext/zh_Hans.po', file('zh-Hans', 'zh_Hans')],
  ]
}

// =============================================================================================
// Terminal: the command line app's theme and words
// =============================================================================================

/** The palette, spacing and motion for the command line app: one Rust module, no dependencies. */
function rustTheme() {
  const rgba = (hex) => {
    const c = parseColor(hex)
    return `Rgba::new(${c.r}, ${c.g}, ${c.b}, ${c.a})`
  }
  let out = `// ${TOKENS_NOTE}\n// The terminal draws on its own background, so only the colours that sit on a fill are used as they are.\n#![allow(dead_code)]\n\n`
  out += `/// A colour with an alpha channel (0 to 255).\n#[derive(Clone, Copy, Debug, PartialEq, Eq)]\npub struct Rgba {\n    pub r: u8,\n    pub g: u8,\n    pub b: u8,\n    pub a: u8,\n}\n\n`
  out += `impl Rgba {\n    pub const fn new(r: u8, g: u8, b: u8, a: u8) -> Self {\n        Self { r, g, b, a }\n    }\n}\n\n`
  out += `/// The colours of one appearance.\n#[derive(Clone, Copy, Debug)]\npub struct Palette {\n${colorNames.map((name) => `    pub ${snake(name)}: Rgba,`).join('\n')}\n}\n\n`
  for (const appearance of ['dark', 'light']) {
    const fields = colorNames.map((name) => `    ${snake(name)}: ${rgba(tokens.colors[name][appearance])},`)
    out += `pub const ${appearance.toUpperCase()}: Palette = Palette {\n${fields.join('\n')}\n};\n\n`
  }
  const spacingConstants = spacings.map(([name, t]) => `    pub const ${snake(name).toUpperCase()}: u16 = ${t.value};`)
  out += `/// Spacing in pixels. A terminal rounds it to cells in chat/src/theme.rs.\npub mod spacing {\n${spacingConstants.join('\n')}\n}\n\n`
  out += `/// Animation lengths in milliseconds, and what each does under reduced motion (0 means it just happens).\npub mod motion {\n`
  out += `    pub const REDUCED_FADE_MS: u64 = ${milliseconds(reducedFade)};\n`
  for (const p of presets) out += `    pub const ${snake(p.name).toUpperCase()}_MS: u64 = ${milliseconds(p.seconds)};\n`
  return out + `}\n`
}

/** chat/src/strings.generated.rs: a table of each key that starts with cli. and its text in every language. */
function rustStrings() {
  const quote = (text) => JSON.stringify(text)
  let out = `// ${STRINGS_NOTE}\n#![cfg_attr(rustfmt, rustfmt::skip)]\n\n`
  out += `/// Every word of the terminal app: the key and its text in ${LANGS.join(', ')}, sorted by key.\n`
  out += `pub static STRINGS: &[(&str, [&str; ${LANGS.length}])] = &[\n`
  for (const [key, entry] of terminalStrings) {
    if (isPlural(entry.en)) fail(`${key}: the terminal app has no plurals`)
    out += `    (${quote(key)}, [${LANGS.map((lang) => quote(entry[lang])).join(', ')}]),\n`
  }
  return out + `];\n`
}

/** chat/src/presets.generated.rs: the services the terminal app offers on the first run, in the order of the file. */
function rustPresets() {
  const { services } = readServices()
  const quote = (text) => JSON.stringify(text)
  let out = `// ${generatedFrom('spec/presets')}\n#![cfg_attr(rustfmt, rustfmt::skip)]\n\n`
  out += `/// A service offered on the first run: its address is filled in, and the person can change it.\npub struct Service {\n`
  out += `    pub id: &'static str,\n    /// It runs on this computer: no key is needed.\n    pub local: bool,\n    pub base_url: &'static str,\n    /// Where to go to get a key, or a model to download.\n    pub link: &'static str,\n}\n\n`
  out += `/// Remote, then local, as ${servicesSource} lists them.\npub static SERVICES: &[Service] = &[\n`
  for (const s of services.services) out += `    Service { id: ${quote(s.id)}, local: ${s.local}, base_url: ${quote(s.baseURL)}, link: ${quote(s.link)} },\n`
  return out + `];\n`
}

// =============================================================================================
// Docs: tables in docs/ux, the component reference and the platform READMEs
// =============================================================================================

/** A Markdown table cell: pipes escaped, one line. */
const tableCell = (text) => text.replace(/\|/g, '\\|').replace(/\n/g, ' ')
/** A word for a table: its text, or its plural forms side by side. */
const showWord = (value) => (isPlural(value) ? Object.entries(value).map(([form, text]) => `${form}: ${text}`).join(' / ') : value)

/** A table of the words whose keys start with one of the prefixes, in the given languages. */
function stringsTable(prefixes, languages) {
  const matches = (key) => prefixes.some((prefix) => key === prefix || key.startsWith(prefix.endsWith('.') ? prefix : `${prefix}.`))
  const rows = [...strings].filter(([key]) => matches(key))
  if (!rows.length) fail(`no strings match ${prefixes.join(' ')}`)
  let out = `| Key | ${languages.map((lang) => LANGUAGE_NAMES[lang]).join(' | ')} |\n`
  out += `| --- | ${languages.map(() => '---').join(' | ')} |\n`
  for (const [key, entry] of rows) out += `| \`${key}\` | ${languages.map((lang) => tableCell(showWord(entry[lang]))).join(' | ')} |\n`
  return out
}

/** A table of one token group, for a <!-- tokens: name --> block in the docs. */
function tokenTable(name) {
  const seconds = (value) => `${value} s`
  if (name === 'motion') {
    let out = '| Preset | Curve | Length | With Reduce Motion | Used for |\n| --- | --- | --- | --- | --- |\n'
    for (const p of presets) {
      const curve = p.swiftCurve === 'spring' ? `spring${p.bounce ? `, bounce ${p.bounce}` : ''}` : p.swiftCurve
      const reduced = p.reduced === 'fade' ? `fade, ${seconds(reducedFade)}` : 'no animation'
      out += `| \`${p.name}\` | ${curve} | ${seconds(p.seconds)} | ${reduced} | ${p.doc} |\n`
    }
    return out
  }
  if (name === 'behavior') {
    let out = '| Name | Value | What it is |\n| --- | --- | --- |\n'
    for (const [key, b] of behavior) out += `| \`${key}\` | ${b.value} | ${b.doc} |\n`
    return out
  }
  if (name === 'sizes') {
    let out = '| Size | iPhone | Android | macOS | Windows | Linux | What it is |\n| --- | --- | --- | --- | --- | --- | --- |\n'
    for (const [key, z] of sizes) out += `| \`${key}\` | ${z.ios} | ${z.android} | ${z.macos} | ${z.windows} | ${z.linux} | ${z.doc} |\n`
    return out
  }
  fail(`unknown token table ${name}`)
}

/**
 * The pages in docs/ux with their generated blocks filled in, and docs/ux/strings.md with every word.
 * A page asks for a block with <!-- strings: prefix ... --> or <!-- tokens: name --> and a closing tag.
 */
function uxPages() {
  const folder = 'docs/ux'
  const pages = []
  if (!existsSync(join(ROOT, folder))) return pages
  const files = readdirSync(join(ROOT, folder)).filter((file) => file.endsWith('.md') && file !== 'strings.md').sort()
  for (const file of files) {
    const path = `${folder}/${file}`
    const text = read(path)
      .replace(/<!-- strings: ([^>]*?) -->[\s\S]*?<!-- \/strings -->/g, (_, list) =>
        `<!-- strings: ${list} -->\n${stringsTable(list.trim().split(/\s+/), ['en'])}<!-- /strings -->`)
      .replace(/<!-- tokens: (\w+) -->[\s\S]*?<!-- \/tokens -->/g, (_, name) =>
        `<!-- tokens: ${name} -->\n${tokenTable(name)}<!-- /tokens -->`)
    pages.push([path, text])
  }
  const areas = [...new Set([...strings.keys()].map((key) => key.split('.')[0]))]
  const allWords = `<!-- ${STRINGS_NOTE} -->\n# All words\n\n` +
    `Every user-facing word of the new screens, by key, in the three languages. The source is \`design/strings\`. The same keys are used on every platform. A word in curly brackets, like {name}, is filled in by the app.\n\n` +
    stringsTable(areas, LANGS)
  pages.push([`${folder}/strings.md`, allWords])
  return pages
}

/** How a component property reads in the docs: the token and its value on one platform. */
function describeProperty(ref, platform) {
  const px = (value) => `${value} px`
  switch (ref.kind) {
    case 'color': {
      const color = tokens.colors[ref.name]
      return `\`color.${ref.name}\` (dark ${cssColor(color.dark)}, light ${cssColor(color.light)})`
    }
    case 'spacing': case 'radius': case 'stroke': return `\`${ref.kind}.${ref.name}\` (${px(GROUPS[ref.kind][ref.name].value)})`
    case 'size': return `\`size.${ref.name}\` (${px(tokens.size[ref.name][platform])})`
    case 'icon': return `\`icon.${ref.name}\` (${px(tokens.icon[ref.name].size)})`
    case 'opacity': return `\`opacity.${ref.name}\` (${tokens.opacity[ref.name].value})`
    case 'type': {
      const type = tokens.type[ref.name]
      return `\`type.${ref.name}\` (${px(type.size)}, weight ${type.weight}, ${type.design})`
    }
    case 'motion': return `\`motion.${ref.name}\` (${duration(GROUPS.motion[ref.name].duration)} s)`
    case 'shadow': return `\`shadow.${ref.name}\` (y ${tokens.shadows[ref.name].y}, blur ${tokens.shadows[ref.name].blur})`
    default: return `\`${ref.value}\``
  }
}

function componentsDoc() {
  let out = `<!-- ${COMPONENTS_NOTE} -->\n# Components\n\n`
  out += `Every Pebble component as a spec. A platform implements the same anatomy with the same tokens, so the Mac, the iPhone, Android, Windows, Linux and the browser popup look and behave alike. The source is \`design/components.json\`. Sizes are given for the desktop (macOS) and, where they differ, the other platforms are in the generated files of each platform (see \`design/generated/<platform>/README.md\`).\n\n`
  out += `The rules of the language (one surface, pebbles, no dividers, monochrome chrome, flat, icon-first, help for every setting, nothing clips) are in [the design language](./index.md).\n\n`
  for (const component of components) {
    out += `## ${component.key}\n\n${component.doc}\n\n| Property | Value |\n| --- | --- |\n`
    for (const ref of component.refs) out += `| \`${ref.prop}\` | ${describeProperty(ref, 'macos')} |\n`
    out += `\n`
    for (const rule of component.rules) out += `- ${rule}\n`
    out += `\n`
  }
  return out
}

function platformReadmes() {
  const note = `<!-- ${TOKENS_NOTE} -->\n`
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

// =============================================================================================
// Outputs: every generated file and what writes it, grouped by platform
// =============================================================================================

const outputs = [
  // Apple
  ['apple/Sources/ImpDesign/Tokens.generated.swift', swiftTokens()],
  ['apple/Sources/ImpKit/Settings/Presets.generated.swift', bundledPresets()],
  ['apple/Resources/Localization/Localizable.xcstrings', stringCatalog('apple/Resources/Localization/Localizable.xcstrings')],
  ['apple/iOS/Imp/Localizable.xcstrings', stringCatalog('apple/iOS/Imp/Localizable.xcstrings')],
  // Web
  ['extension/tokens.css', webCss()],
  ...extensionLocales(),
  // Android
  ['design/generated/android/ImpTheme.kt', kotlinTokens()],
  ['design/generated/android/ImpComponents.kt', kotlinComponents()],
  ...androidStrings(),
  // Windows
  ['design/generated/windows/ImpTokens.xaml', xamlTokens()],
  ['design/generated/windows/ImpComponents.xaml', xamlComponents()],
  ['design/generated/windows/ImpTokens.cs', csharpTokens()],
  ...reswStrings(),
  // Linux
  ['design/generated/gtk/imp-colors-dark.css', gtkColors('dark')],
  ['design/generated/gtk/imp-colors-light.css', gtkColors('light')],
  ['design/generated/gtk/imp-tokens.css', gtkTokens()],
  ['design/generated/gtk/imp-components.css', gtkComponents()],
  ...gettextCatalogs(),
  // Terminal
  ['chat/src/theme.generated.rs', rustTheme()],
  ['chat/src/strings.generated.rs', rustStrings()],
  ['chat/src/presets.generated.rs', rustPresets()],
  // Docs
  ['docs/design/components.md', componentsDoc()],
  ...platformReadmes(),
  ...uxPages(),
]

// =============================================================================================
// Main
// =============================================================================================

if (mode === 'list') {
  for (const [path] of outputs) console.log(path)
  process.exit(0)
}

/** The generated files whose content on disk differs from what this run makes. */
const stale = outputs.filter(([path, content]) => {
  const full = join(ROOT, path)
  return !existsSync(full) || readFileSync(full, 'utf8') !== content
})

if (mode === 'check') {
  if (stale.length) {
    console.error(`Out of date, run: node design/generate.mjs (or make tokens)\n  ${stale.map(([path]) => path).join('\n  ')}`)
    process.exit(1)
  }
  console.log(`All ${outputs.length} generated files are current.`)
} else {
  for (const [path, content] of stale) {
    const full = join(ROOT, path)
    mkdirSync(dirname(full), { recursive: true })
    writeFileSync(full, content)
  }
  console.log(stale.length
    ? `Wrote ${stale.length} of ${outputs.length} files:\n  ${stale.map(([path]) => path).join('\n  ')}`
    : `All ${outputs.length} files already current.`)
}
