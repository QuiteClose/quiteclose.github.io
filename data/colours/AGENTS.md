# Colour Schemes

This directory is a library of colour scheme definitions. Each scheme provides light and dark variants with palettes, document styles, and syntax highlighting mappings. Schemes are layout-agnostic -- each layout's `layout.yaml` manifest selects which schemes it uses.

## Directory Structure

```
data/colours/
  AGENTS.md         <-- this file
  borland.yaml
  crt.yaml
  dune.yaml
  github.yaml
  gruvbox.yaml
  rosepine.yaml
  solarized.yaml
  srcery.yaml
  tomorrow.yaml
```

## Scheme File Format

Each scheme file has two top-level keys: `light` and `dark`. Each variant contains four maps:

### meta

Display metadata for the variant.

| Field  | Description                          | Example             |
|--------|--------------------------------------|---------------------|
| `name` | Plain text name                      | `Solarized Light`   |
| `html` | HTML-safe name (may include entities)| `Ros&eacute; Pine`  |

### palette

Maps colour names to hex values. **Palette names are unique to each scheme** -- they use the scheme's native/canonical naming (e.g. Solarized uses `base03`..`base3`, Gruvbox uses `bg0`..`fg3`, CRT uses luminance names like `bright`/`dim`/`faint`).

Light and dark variants of the same scheme may share hex values (accents often do) or invert them (neutrals typically do).

### styles

Maps document-level roles to palette names. Two sub-maps:

**text:**

| Field       | Purpose                              |
|-------------|--------------------------------------|
| `primary`   | Default body text                    |
| `secondary` | De-emphasised text, captions         |
| `emphasis`  | Strong/bold text                     |
| `heading`   | Heading colour                       |
| `link`      | Unvisited link                       |
| `visited`   | Visited link                         |
| `hover`     | Link hover state                     |

**background:**

| Field       | Purpose                              |
|-------------|--------------------------------------|
| `primary`   | Main page background                 |
| `secondary` | Offset background (cards, sidebars)  |
| `embed`     | Embedded content (code blocks, etc.) |

### syntax

Maps canonical code highlighting roles to palette names. These roles are shared across all highlighting sources (build-time Tree Sitter and run-time LDT).

| Field         | Purpose                                          |
|---------------|--------------------------------------------------|
| `keyword`     | Language keywords (`if`, `for`, `def`, `return`)  |
| `string`      | String literals                                   |
| `comment`     | Comments                                          |
| `function`    | Function/method names                             |
| `type`        | Types, classes, structs, interfaces                |
| `number`      | Numeric literals                                  |
| `operator`    | Operators (`+`, `=`, `=>`)                        |
| `constant`    | Constants, booleans, `null`/`None`/`undefined`    |
| `variable`    | Identifiers, variable names                       |
| `punctuation` | Brackets, delimiters, semicolons                  |

## Conventions

- All style and syntax values are **palette names**, not hex values. The indirection is intentional: the build pipeline resolves palette → hex.
- Palette sizes vary by scheme (Solarized has 16, CRT has 8). There is no fixed palette size.
- Scheme files are parsed by `src/yaml.zig` (a minimal custom YAML parser). Supported YAML features: maps, lists, quoted/unquoted strings, comments. No anchors, aliases, or flow syntax.
- When adding a new scheme: add the YAML file here and reference it in each layout's `layout.yaml` manifest (under `highlights.schemes`).
- Which schemes a layout uses, and its default scheme/mode, are configured in `styles/{layout}/layout.yaml`, not here.

## Design Rationale

The three-layer indirection (palette → styles/syntax → CSS custom properties) exists so that:

1. **Palettes stay native.** Each scheme uses the names its designer intended. No forced normalisation across schemes.
2. **Roles are stable.** The `styles` and `syntax` field names are the same in every scheme, providing a consistent interface for CSS and JavaScript.
3. **Mapping is explicit.** Each scheme explicitly maps its palette to roles rather than relying on positional conventions (like ANSI slot numbers).
