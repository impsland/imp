# Imp Kits: the community registry

A gallery of setups for [Imp](../README.md): whole Imps with their own personalities, packs of
triggers and borrowed tools (MCP servers). Each kit is one JSON file in `registry/kits/`, the same
format Imp exports (see [Share setups as kits](../README.md#share-setups-as-kits)). The gallery is
a static site built from those files, with an **Add to Imp** button on every kit
(`imp://add?url=<the kit's address>`). Imp always shows a review before anything is added.

## Contributing a kit

1. In Imp, share your setup (**Me › Share**, **Share as kit**, or **Export…**) and save the `.json`.
2. Add a `registry` block next to `name` and `about` (Imp ignores it, the gallery reads it):

   ```json
   "registry": { "author": "your name", "tags": ["planning", "memory"], "summary": "One line, at most 120 characters." }
   ```

3. Save it as `registry/kits/<slug>.json` (lowercase letters, digits and dashes) and open a pull request.

### Rules and review checklist

- **No secrets.** Environment variable and header values stay `""`. No keys in command arguments,
  no `?key=...` in a URL. `build.py` rejects non-empty values.
- **No chats, no local paths** that only work on your Mac (a `~/...` folder the kit explains is fine).
- **Real tools only.** Every MCP server is a published package (npm or PyPI) that you checked exists
  (`npm view <pkg> name`, or the PyPI page). Say in `about` what it does and what it needs.
- **Say what it can do.** Computer control, terminal commands and tools that run programs are
  shown on the kit's page. Make `about` and the personality honest about them.
- **Prompts are well written:** specific, short, no instructions to hide things from the user.
- **`about`, `registry.author`, `registry.tags` (at least one) and `registry.summary`** are required.
- **Under 512 KB**, at most 20 Imps, 50 triggers and 20 tools.
- A reviewer reads the personalities and triggers, since they steer what an Imp does with its tools.

### Versioning

`"imp"` is the kit format version, meaning the oldest Imp that can read it: `1` for triggers and
tools only (Imp 1.6+), `2` when the kit has Imps (Imp 1.7+). Use the lowest that fits, as Imp does
when it exports. The gallery shows "Needs Imp 1.x+" from it; the mapping is `MIN_IMP_FOR_FORMAT` in
`build.py`, the only place to change when a format is added. Unknown keys are ignored by Imp, so
adding fields is safe.

## Checking a kit

CI (`.github/workflows/registry.yml`) builds Imp and runs every kit through the app's real parser:

```sh
xcrun swift build
.build/debug/Imp --check-kit registry/kits/*.json     # ok / problems / warnings / format; exit 1 on any problem
```

## Building the site locally

Python 3 standard library only, no network:

```sh
python3 registry/build.py --out registry/site --base-url http://localhost:8000
python3 -m http.server -d registry/site 8000
```

`--base-url` is where the site will live (default `https://impsland.github.io/imp`); Add to Imp
links and the Open Graph tags use it. Imp loads `http` only from `localhost`, so build with a
localhost base URL to try Add to Imp locally. Output (`registry/site/`, git-ignored): `index.html`,
`k/<slug>/index.html`, `kits/<slug>.json` (the raw file Imp downloads), `index.json` (manifest),
`add/index.html`. Append `?theme=light` or `?theme=dark` to any page to force a theme.

The site loads nothing from other servers (no CDNs, fonts or trackers) and its Content Security
Policy forbids it.

## Publishing

On a push to `main` that touches `registry/**`, the workflow deploys `registry/site` to GitHub Pages.
That job only succeeds once Pages is enabled for the repository (Settings › Pages › Source: GitHub
Actions); nothing here changes repository settings.

## An "Add to Imp" button for your own site

If you host a kit yourself (https, under 512 KB), link to it like this. Imp downloads it and shows
the usual review.

```html
<a class="add-to-imp" href="imp://add?url=https://example.com/my-kit.json">Add to Imp</a>
```

```css
.add-to-imp {
  display: inline-block; padding: .65em 1.2em; border-radius: 999px;
  background: #c92f35; color: #fff; font: 600 1rem/1 system-ui, sans-serif;
  text-decoration: none; box-shadow: 0 2px 0 #8f1f27;
}
.add-to-imp:hover { background: #d93a40; }
.add-to-imp:focus-visible { outline: 3px solid #ffb86b; outline-offset: 3px; }
```

For a short kit you can inline it instead: `imp://add?kit=<base64url of the JSON>`. People without Imp
see nothing happen, so it helps to link to [Get Imp](https://github.com/impsland/imp/releases/latest/download/Imp.dmg) nearby.
