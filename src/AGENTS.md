# Site Generator (`src/`)

This directory contains the custom static site generator for quiteclose.github.io. It replaces the previous Zine-based pipeline with a lightweight, purpose-built system written in Zig.

## Files

| File | Purpose |
| --- | --- |
| `generate.zig` | Build-time executable: CSS bundling, template rendering, asset copying, pattern library generation |
| `template.zig` | Template engine: custom HTML element syntax for inheritance, slots, includes, variables, loops, conditionals |
| `yaml.zig` | Minimal YAML parser (maps, lists, inline lists, quoted/unquoted strings, comments) |

## Build targets

```
zig build          # Release build → zig-out/site/
zig build draft    # Dev build (pattern library + drafts) → zig-out/site/
zig build serve    # Dev build then python3 HTTP server on :8080
zig build test     # Run template engine tests (38 tests)
```

## How a page is rendered

1. `build.zig` compiles `generate.zig` and runs it with: `<layouts_dir> <data_dir> <pages_dir> <assets_dir> <output_dir> <layout_names> [--dev]`
2. `generate.zig` processes each layout manifest (`layouts/{name}/layout.yaml`), producing CSS bundles (`output/css/{name}.css`) and JS modules (`output/js/{name}.js`)
3. Templates are loaded into a `Resolver`: `layouts/_core/html/*.html` and `layouts/{name}/html/*.html`
4. Content pages from `pages/` are read. Each `.html` file has YAML frontmatter (between `---` delimiters) and an HTML body
5. For each page, a `Context` is created with:
   - `site.*` variables from `data/site.yaml`
   - `page.*` variables from the page's YAML frontmatter
   - The page's HTML body as the anonymous (default) slot
6. The page's `layout` frontmatter value determines which template to render (e.g. `layout: page.html`)
7. `template.render()` processes the layout template, resolving the extend chain, slots, variables, includes, conditionals, and loops
8. The rendered HTML is written to `output_dir/{page_path}`
9. Assets from `assets/` are copied to `output_dir/`
10. In dev mode (`--dev`), pattern library pages are generated and rendered per layout

## Template language reference

Templates use **custom HTML elements** prefixed with `x-`. These are processed at build time and do not appear in the output. All other HTML passes through unchanged.

### `<x-extend>` -- template inheritance

A template that starts with `<x-extend>` inherits from a parent template. The child provides content for the parent's slots via `<x-define>` blocks.

```html
<x-extend template="base.html">
<x-define slot="head">
<link rel="stylesheet" href="/css/default.css" />
</x-define>
<x-define slot="body">
<h1><x-var name="page.title" /></h1>
<x-slot />
</x-define>
```

- Chains can be arbitrarily deep (page.html extends base.html, content extends page.html)
- Circular references are detected and produce `CircularReference` error
- The `<x-extend>` tag must appear at the start of the template (leading whitespace is allowed)

### `<x-slot>` -- insertion point

Declares where child content is inserted in a parent template.

```html
<!-- Named slot with default content -->
<x-slot name="title">Untitled</x-slot>

<!-- Named slot, no default (renders empty if unfilled) -->
<x-slot name="head" />

<!-- Anonymous (default) slot -->
<x-slot />
```

- Named slots are filled by `<x-define slot="name">` in the child
- The anonymous slot (no `name` attribute) receives the page body content (set by the build tool) or the body of an `<x-include>`
- If a named slot is not filled by the child, its default content (between `<x-slot>` and `</x-slot>`) is rendered. If there is no default content (self-closing), nothing is rendered
- Slot content is itself rendered through the template engine, so it can contain variables, conditionals, etc.

### `<x-define>` -- fill a slot

Used inside an `<x-extend>` block to provide content for a named slot in the parent.

```html
<x-define slot="head">
<link rel="stylesheet" href="/css/page.css" />
</x-define>
```

### `<x-var>` -- variable substitution

Inserts a variable value. Values are HTML-escaped.

```html
<!-- As element content -->
<x-var name="page.title" />

<!-- As an attribute value (x-var:attrname="varname") -->
<a x-var:href="post.url"><x-var name="post.title" /></a>
```

- If the variable doesn't exist, element form renders nothing; attribute form omits the attribute entirely
- Variable namespace: `site.*` (from `data/site.yaml`), `page.*` (from frontmatter), `item.*` (from `x-for` loops)
- Values are always HTML-escaped (`&`, `<`, `>`, `"` become entities)

### `<x-include>` -- component inclusion

Includes another template as a reusable component.

```html
<!-- Self-closing (no body) -->
<x-include template="nav.html" class="site-nav" />

<!-- With body (fills the anonymous slot in the included template) -->
<x-include template="card.html" variant="featured">
<h3>Card title</h3>
<p>Card content</p>
</x-include>
```

- Attributes on the tag (other than `template`) are passed to the included template as `attrs`
- The body content (if any) fills the anonymous slot in the included template
- The included template has its own attribute scope but inherits `vars` and `collections` from the parent context
- Circular includes are detected via depth tracking (`max_depth = 50`)

### `<x-attr>` -- attribute access (inside includes)

Accesses attributes passed to the current include.

```html
<!-- As element content -->
<x-attr name="variant" />

<!-- As an attribute value -->
<button x-attr:data-variant="variant">Click</button>
```

- Only meaningful inside an included template
- If the attribute doesn't exist, element form renders nothing; attribute form omits the attribute

### `<x-if>` / `<x-elif>` / `<x-else>` -- conditional rendering

Conditionally renders content based on variable, attribute, or slot existence/values.

```html
<!-- Variable exists -->
<x-if var="page.subtitle">
<p class="subtitle"><x-var name="page.subtitle" /></p>
</x-if>

<!-- Variable equals a value -->
<x-if var="site.mode" equals="development">
<p>Development mode</p>
<x-elif var="site.mode" equals="staging">
<p>Staging mode</p>
<x-else>
<p>Production</p>
</x-if>

<!-- Attribute exists (inside an include) -->
<x-if attr="variant" exists>
<span x-attr:data-variant="variant">styled</span>
</x-if>

<!-- Slot exists -->
<x-if slot="sidebar">
<aside><x-slot name="sidebar" /></aside>
</x-if>

<!-- Negation -->
<x-if var="page.draft" not-exists>
<p>Published</p>
</x-if>
```

**Scopes:** `var`, `attr`, `slot` -- exactly one required per condition.

**Comparisons:**
- `exists` -- true if the value is present (this is the default if no comparison attribute is given)
- `not-exists` -- true if the value is absent
- `equals="value"` -- true if the value equals the given string
- `not-equals="value"` -- true if the value does not equal the given string

### `<x-for>` -- iteration

Iterates over a named collection, rendering its body once per entry.

```html
<x-for post in pages.posts sort="date" order="desc">
<article>
<h2><a x-var:href="post.x-path"><x-var name="post.title" /></a></h2>
</article>
</x-for>
```

- `item` is the loop variable prefix; entry fields are accessed as `item.fieldname`
- Collections are populated by `generate.zig` with `data.*` (from YAML data files) or `pages.*` (from page collections)
- Optional `sort="field"` sorts entries by the named field (lexicographic, ascending by default)
- Optional `order="desc"` reverses the sort
- Entries with `draft: true` are excluded unless `dev_mode` is on
- Nested loops are supported; inner loop variables shadow outer ones with the same prefix
- Nested `</x-for>` tags are matched correctly (nesting-aware close tag search)

## Context data model

The template engine operates on a `Context` struct with four namespaces:

| Namespace | Type | Set by | Accessed via |
| --- | --- | --- | --- |
| `vars` | `string → string` | Build tool (site/page vars), `x-for` (loop vars) | `<x-var>`, `x-var:`, `<x-if var="...">` |
| `attrs` | `string → string` | `<x-include>` tag attributes | `<x-attr>`, `x-attr:`, `<x-if attr="...">` |
| `slots` | `string → string` | `<x-define>`, page body (anonymous slot) | `<x-slot>`, `<x-if slot="...">` |
| `collections` | `string → Entry[]` | Build tool (data lists, page collections) | `<x-for>` |

**Context propagation rules:**
- `<x-extend>`: child slots are merged into the parent context; `vars`, `attrs`, and `collections` are inherited
- `<x-include>`: `vars` and `collections` are inherited; `attrs` are replaced with the include's tag attributes; `slots` are replaced (anonymous slot = include body)
- `<x-for>`: loop variables are added to `vars` with the item prefix (e.g. `post.title`); all other context is inherited
- `<x-slot>` content rendering: slot content is rendered through the template engine recursively, so it can contain any template elements

## Content page format

Content pages are HTML files with YAML frontmatter:

```html
---
title: Home
date: 2026-02-24
author: QuiteClose
layout: page.html
draft: false
---
<p>This is the page content.</p>
```

- Frontmatter is delimited by `---` on its own line
- All frontmatter fields become `page.*` variables (e.g. `page.title`, `page.layout`)
- `layout` determines which template renders the page
- `draft: true` pages are excluded from release builds (included in `--dev` builds)
- The HTML body (everything after the closing `---`) becomes the anonymous slot content

## Error handling

The template engine returns typed errors:

| Error | Cause |
| --- | --- |
| `MalformedElement` | Unclosed tag, missing required attribute, malformed syntax |
| `TemplateNotFound` | `<x-extend>` or `<x-include>` references a template not in the Resolver |
| `CircularReference` | Template extend chain forms a cycle, or include depth exceeds 50 |
| `DuplicateSlotDefinition` | Same slot name defined twice in one extend level |
| `OutOfMemory` | Allocator exhausted |

## Testing

All template elements are tested via inline `test` blocks in `template.zig`. Run with `zig build test` or `zig test src/template.zig`. Tests use `std.testing.allocator` (which detects memory leaks) and cover:

- `x-var`: basic, missing, HTML escaping, dotted path, attribute binding, missing attribute omission (6 tests)
- `x-slot`/`x-define`: named, anonymous, default content filled/unfilled, empty unfilled (5 tests)
- `x-extend`: two-level, three-level chain, circular detection (3 tests)
- `x-include`/`x-attr`: simple, with body, with attrs, combined, attribute context, nested, circular detection, scope isolation (8 tests)
- `x-if`/`x-elif`/`x-else`: var exists true/false, equals, not-equals, not-exists, else, elif chain, attr scope, slot scope (9 tests)
- `x-for`: data list, pages, sorted asc/desc, draft exclusion, nested with shadowing (6 tests)
- Integration: full page render through 3-level extend chain with includes, variables, loops, and conditionals (1 test)
