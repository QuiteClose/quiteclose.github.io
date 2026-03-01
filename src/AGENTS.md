# Site Generator (`src/`)

This directory contains the custom static site generator for quiteclose.github.io. It replaces the previous Zine-based pipeline with a lightweight, purpose-built system written in Zig.

## Files

| File | Purpose |
| --- | --- |
| `generate.zig` | Build-time executable: CSS bundling, template rendering, asset copying, pattern library generation |
| `template.zig` | Template engine: 11 custom HTML element types for inheritance, slots, includes, variables, loops, conditionals, comments, variable capture, and transforms |
| `yaml.zig` | Minimal YAML parser (maps, lists, inline lists, quoted/unquoted strings, comments) |

## Build targets

```
zig build          # Release build → zig-out/site/
zig build draft    # Dev build (pattern library + drafts) → zig-out/site/
zig build serve    # Dev build then python3 HTTP server on :8080
zig build test     # Run template engine tests (142 tests)
```

## How a page is rendered

1. `build.zig` compiles `generate.zig` and runs it with: `<styles_dir> <data_dir> <pages_dir> <assets_dir> <output_dir> <layout_names> [--dev]`
2. `generate.zig` processes each layout manifest (`styles/{name}/layout.yaml`), producing CSS bundles (`output/css/{name}.css`) and JS modules (`output/js/{name}.js`)
3. Templates are loaded into a `Resolver`: `styles/_core/html/*.html` and `styles/{name}/html/*.html`
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

Used inside `<x-extend>` or `<x-include>` to provide content for a named slot.

```html
<!-- In x-extend (slot attribute, legacy) -->
<x-define slot="head">
<link rel="stylesheet" href="/css/page.css" />
</x-define>

<!-- In x-include (name attribute, preferred) -->
<x-include template="card.html">
  <x-define name="title">My Card</x-define>
  <p>Card body goes here</p>
</x-include>
```

- Both `name` and `slot` attributes are accepted (prefer `name` for consistency with `<x-slot name="...">`)
- In `<x-extend>`: defines fill slots in the parent template
- In `<x-include>`: defines fill named slots in the included template; any remaining body content (outside `<x-define>` blocks) fills the anonymous slot
- Duplicate `<x-define>` with the same name in a single `<x-include>` returns `DuplicateSlotDefinition` error

### `<x-var>` -- variable substitution

Inserts a variable value. Values are HTML-escaped. **Strict mode:** if the variable is not defined and no default is provided, returns `UndefinedVariable` error.

```html
<!-- Self-closing (strict: errors if variable is missing) -->
<x-var name="page.title" />

<!-- Block form with default body (rendered if variable is missing) -->
<x-var name="page.author">Anonymous</x-var>

<!-- With transform (pipe-chained, see Transform reference) -->
<x-var name="page.title" transform="lower|slugify" />

<!-- Block form with transform -->
<x-var name="page.subtitle" transform="upper">No subtitle</x-var>

<!-- As an attribute value (x-var:attrname="varname") -->
<a x-var:href="post.url"><x-var name="post.title" /></a>
```

- **Strict by default:** Self-closing `<x-var name="x" />` returns `UndefinedVariable` error if the variable is missing (unless a `default` transform is present)
- **Block form for defaults:** `<x-var name="x">fallback</x-var>` renders the body content as the default when the variable is missing. The default body is rendered through the template engine (can contain other template elements)
- **Transform attribute:** `transform="lower|slugify"` applies pipe-chained transforms to the value before output (see Transform reference below)
- Variable namespace: `site.*` (from `data/site.yaml`), `page.*` (from frontmatter), `item.*` (from `x-for` loops), `x-let` captured values
- Values are always HTML-escaped (`&`, `<`, `>`, `"` become entities) after transforms are applied
- Attribute binding (`x-var:href="var"`) omits the attribute entirely if the variable is missing (no error)

### `<x-raw>` -- unescaped variable output

Inserts a variable value **without** HTML escaping. Use for pre-rendered HTML fragments (e.g. swatch tables, clamp values in `style` attributes). **Strict mode:** same as `<x-var>` -- errors on missing variables without defaults.

```html
<!-- Self-closing (strict: errors if missing) -->
<x-raw name="scheme.swatches" />

<!-- Block form with default -->
<x-raw name="scheme.swatches"><p>No swatches available</p></x-raw>

<!-- With transform -->
<x-raw name="content" transform="replace:foo:bar" />
```

- Same lookup, default body, and transform semantics as `<x-var>` (works with `page.*`, `site.*`, loop variables, `x-let`, etc.)
- Output is **not** HTML-escaped (transforms are applied, then raw output)
- **Only use for values you control.** Never use for user-supplied content.

### `<x-include>` -- component inclusion

Includes another template as a reusable component. Supports both anonymous and named slots.

```html
<!-- Self-closing (no body) -->
<x-include template="nav.html" class="site-nav" />

<!-- With body (fills the anonymous slot in the included template) -->
<x-include template="card.html" variant="featured">
<h3>Card title</h3>
<p>Card content</p>
</x-include>

<!-- With named slots via <x-define> children -->
<x-include template="card.html">
  <x-define name="title">My Card Title</x-define>
  <x-define name="icon">★</x-define>
  <p>Body content (anonymous slot)</p>
</x-include>
```

- Attributes on the tag (other than `template`) are passed to the included template as `attrs`
- **Anonymous slot:** Body content (outside any `<x-define>` blocks) fills the anonymous slot in the included template
- **Named slots:** `<x-define name="...">` children fill named slots (`<x-slot name="...">`) in the included template
- Named and anonymous slots can coexist in the same include
- If a named slot is not provided, the `<x-slot>` default content is used (same as with `<x-extend>`)
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

### `<x-if>` / `<x-elif />` / `<x-else />` -- conditional rendering

Conditionally renders content based on variable, attribute, or slot existence/values. `<x-elif />` and `<x-else />` are **self-closing separators** inside a single `<x-if>...</x-if>` block.

```html
<!-- Variable exists -->
<x-if var="page.subtitle">
<p class="subtitle"><x-var name="page.subtitle" /></p>
</x-if>

<!-- Variable equals a value, with elif and else branches -->
<x-if var="site.mode" equals="development">
<p>Development mode</p>
<x-elif var="site.mode" equals="staging" />
<p>Staging mode</p>
<x-else />
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

**Separator syntax:** Only `<x-if>` has a closing tag (`</x-if>`). `<x-elif />` and `<x-else />` are self-closing separators that divide the body of the enclosing `<x-if>` into branches. There are no `</x-elif>` or `</x-else>` close tags. Nesting is handled by matching `<x-if>`/`</x-if>` pairs.

**Scopes:** `var`, `attr`, `slot` -- exactly one required per condition.

**Comparisons:**
- `exists` -- true if the value is present (this is the default if no comparison attribute is given)
- `not-exists` -- true if the value is absent
- `equals="value"` -- true if the value equals the given string
- `not-equals="value"` -- true if the value does not equal the given string

### `<x-for>` -- iteration

Iterates over a named collection, rendering its body once per entry.

```html
<!-- Basic loop -->
<x-for post in pages.posts sort="date" order="desc">
<article>
<h2><a x-var:href="post.x-path"><x-var name="post.title" /></a></h2>
</article>
</x-for>

<!-- Named loop alias with index/number metadata -->
<x-for post in pages.posts as loop>
<div>#<x-var name="loop.number" /> (index <x-var name="loop.index" />): <x-var name="post.title" /></div>
</x-for>

<!-- Pagination with limit and offset -->
<x-for post in pages.posts limit="5" offset="0">
<p><x-var name="post.title" /></p>
</x-for>
```

- `item` is the loop variable prefix; entry fields are accessed as `item.fieldname`
- Collections are populated by `generate.zig` with `data.*` (from YAML data files) or `pages.*` (from page collections)
- Optional `sort="field"` sorts entries by the named field (lexicographic, ascending by default)
- Optional `order="desc"` reverses the sort
- **Named loop alias:** `as name` after the collection name creates metadata variables `name.index` (0-based) and `name.number` (1-based). These coexist with the item prefix variables
- **Pagination:** `limit="N"` caps the number of rendered entries; `offset="N"` skips the first N entries. Applied after sort/filter, before rendering. Non-numeric values return `MalformedElement` error
- Entries with `draft: true` are excluded unless `dev_mode` is on
- Nested loops are supported; inner loop variables shadow outer ones with the same prefix
- Nested `</x-for>` tags are matched correctly (nesting-aware close tag search)

### `<x-comment>` -- template-only comments

Comments that are stripped from the output. Unlike HTML comments (`<!-- -->`), `<x-comment>` content is never rendered, not even in development builds.

```html
<!-- Block form (content is stripped) -->
<x-comment>
  TODO: Add navigation links when we build the nav component
  This entire block will not appear in the output
</x-comment>

<!-- Self-closing form -->
<x-comment />
```

- Content inside `<x-comment>` is not rendered or processed (nested template elements are ignored)
- Useful for template-only notes, TODOs, and development annotations
- HTML comments are still available for comments that should appear in the output

### `<x-let>` -- variable capture

Renders its body content and captures the result into a named variable for use later in the template. Optionally applies transforms to the captured value.

```html
<!-- Basic capture -->
<x-let name="greeting">Hello, <x-var name="page.author" />!</x-let>
<p><x-var name="greeting" /></p>

<!-- Capture with transform -->
<x-let name="slug" transform="lower|slugify"><x-var name="page.title" /></x-let>
<a x-var:href="slug">Link</a>
```

- The body is rendered through the template engine (can contain variables, conditionals, etc.)
- The rendered result is stored in `ctx.vars` under the given `name`
- Optional `transform` attribute applies pipe-chained transforms to the captured value (see Transform reference)
- Captured variables are visible to subsequent content and to `<x-include>` templates rendered after the `<x-let>`
- Inside `<x-for>` loops, captured variables are scoped to each iteration (do not persist across iterations)
- `<x-let>` itself produces no output (the body is captured, not emitted)
- Missing `name` attribute returns `MalformedElement` error

### Transforms

Transforms are string manipulation functions applied via the `transform` attribute on `<x-var>`, `<x-raw>`, and `<x-let>`. Multiple transforms can be chained with the pipe character (`|`), applied left to right.

```html
<x-var name="title" transform="lower|slugify" />
<x-var name="desc" transform="truncate:100" />
<x-var name="text" transform="replace:foo:bar|upper" />
<x-var name="maybe" transform="default:N/A" />
```

**Built-in transforms:**

| Transform | Arguments | Description | Example |
| --- | --- | --- | --- |
| `upper` | none | Convert to uppercase | `hello` → `HELLO` |
| `lower` | none | Convert to lowercase | `HELLO` → `hello` |
| `capitalize` | none | Capitalize first character | `hello world` → `Hello world` |
| `trim` | none | Strip leading/trailing whitespace | `  hi  ` → `hi` |
| `slugify` | none | Lowercase, replace non-alphanumeric with hyphens, collapse hyphens | `Hello World!` → `hello-world` |
| `truncate` | `N` (max length) | Truncate to N characters (no ellipsis) | `truncate:5` on `Hello World` → `Hello` |
| `replace` | `from:to` | Replace all occurrences of `from` with `to` | `replace:a:b` on `cat` → `cbt` |
| `default` | `value` | Use `value` if the variable is empty or missing | `default:N/A` on missing → `N/A` |

**Chaining:** Transforms are applied left to right. Each transform receives the output of the previous one.

**`default` transform:** When used on a self-closing `<x-var>` with a missing variable, `default:value` prevents the `UndefinedVariable` error and uses the provided value instead.

**Non-numeric arguments:** `truncate` requires a numeric argument; non-numeric values return `MalformedElement` error.

**Unknown transforms:** Any transform name not in the list above returns `MalformedElement` error.

## Context data model

The template engine operates on a `Context` struct with four data namespaces plus optional error tracking:

| Namespace | Type | Set by | Accessed via |
| --- | --- | --- | --- |
| `vars` | `string → string` | Build tool (site/page vars), `x-for` (loop vars), `x-let` (captured vars) | `<x-var>`, `<x-raw>`, `x-var:`, `<x-if var="...">`, `<x-let>` |
| `attrs` | `string → string` | `<x-include>` tag attributes | `<x-attr>`, `x-attr:`, `<x-if attr="...">` |
| `slots` | `string → string` | `<x-define>`, page body (anonymous slot) | `<x-slot>`, `<x-if slot="...">` |
| `collections` | `string → Entry[]` | Build tool (data lists, page collections) | `<x-for>` |
| `err_detail` | `?*ErrorDetail` | Caller (optional) | Set by engine on error |

**Context propagation rules:**
- `<x-extend>`: child slots are merged into the parent context; `vars`, `attrs`, `collections`, and `err_detail` are inherited
- `<x-include>`: `vars`, `collections`, and `err_detail` are inherited; `attrs` are replaced with the include's tag attributes; `slots` are replaced (anonymous slot = include body, named slots from `<x-define>` children)
- `<x-for>`: loop variables (item prefix + optional alias metadata) are added to `vars`; all other context is inherited
- `<x-let>`: captured variables are added to `vars` in the current scope; visible to subsequent content and includes
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
| `MalformedElement` | Unclosed tag, missing required attribute, malformed syntax, non-numeric limit/offset, unknown transform |
| `TemplateNotFound` | `<x-extend>` or `<x-include>` references a template not in the Resolver |
| `CircularReference` | Template extend chain forms a cycle, or include depth exceeds 50 |
| `DuplicateSlotDefinition` | Same slot name defined twice in one `<x-include>` |
| `UndefinedVariable` | Self-closing `<x-var>` or `<x-raw>` references a variable not in `ctx.vars` and no default body or `default` transform is provided |
| `OutOfMemory` | Allocator exhausted |

### ErrorDetail

Optional error context with source location. Set `ctx.err_detail` to a `*ErrorDetail` before calling `render()` to receive line/column information on errors:

```zig
pub const ErrorDetail = struct {
    line: usize = 0,      // 1-based line number within the template
    column: usize = 0,    // 1-based column number within the line
    source_file: []const u8 = "",  // set by caller (e.g. generate.zig)
    message: []const u8 = "",      // variable name, template name, or descriptive message
};
```

- When `ctx.err_detail` is `null` (the default), errors are returned without position information (backward compatible)
- When set, the engine populates `line`, `column`, and `message` at each error site before returning the error
- For `UndefinedVariable`, `message` is the variable name (e.g. `"page.author"`)
- For `TemplateNotFound` and `CircularReference`, `message` is the template name
- For `MalformedElement`, `message` describes the issue (e.g. `"unclosed x-let element"`, `"missing 'name' attribute on x-var"`)
- `source_file` is not set by the template engine; the caller should set it to the page/template path for context

## Testing

All template elements are tested via inline `test` blocks in `template.zig`. Run with `zig build test` or `zig test src/template.zig`. Tests use `std.testing.allocator` (which detects memory leaks) and cover:

- `x-var`: basic, missing is error, HTML escaping, dotted path, attribute binding, missing attribute omission, default used/not used, nested default, empty default, default not escaped, existing value escaped, strict no error (13 tests)
- `x-raw`: basic, HTML not escaped, missing is error, in for loop, default used/not used, strict missing is error (7 tests)
- `x-slot`/`x-define`: named, anonymous, default content filled/unfilled, empty unfilled (5 tests)
- `x-extend`: two-level, three-level chain, circular detection (3 tests)
- `x-include`/`x-attr`: simple, with body, with attrs, combined, attribute context, nested, circular detection, scope isolation, named slot single/multiple/with anonymous/no anonymous/default used/overridden/with attrs, duplicate define error, attr binding optional (17 tests)
- `x-if`/`x-elif`/`x-else`: var exists true/false, equals, not-equals, not-exists, else, elif chain, attr scope, slot scope (9 tests)
- `x-for`: data list, pages, sorted asc/desc, draft exclusion, nested with shadowing, as index/number, as coexists with item prefix, without as backward compatible, nested independent aliases, limit only, offset only, limit+offset, offset beyond items, limit zero, all attrs combined (16 tests)
- `x-comment`: block stripped, self-closing stripped, nested elements not rendered, surrounding content preserved (4 tests)
- `x-let`: basic capture, nested elements, transform, subsequent content, chained transforms, for scoped, overrides var, visible to include (8 tests)
- Transforms: upper, lower, capitalize, slugify, truncate, truncate short unchanged, replace, default on missing, trim, chain replace+capitalize, chain three, on raw, on var escapes after, empty value (14 tests)
- Nesting: nested if both true, inner false with else, outer false, with elif, elif with inner chain, else with inner chain, nested for loops, nested if in for, complex if-for-if (9 tests)
- Indentation: simple, multi-line, nested structure, include body, named slots at different levels, zero-level slot, empty content (7 tests)
- Integration: full page render through 3-level extend chain with includes, variables, loops, and conditionals (1 test)
- ErrorDetail: undefined variable line/message, malformed element, line after newlines, column, message includes name, null detail backward compatible (6 tests)
- Malformed/error: extend missing template, include missing template, orphan else/elif, unclosed if/for/slot/comment/var/raw, var/raw no name, var block no name, for no in, for limit non-numeric, transform truncate non-numeric, unknown transform, let no name, let unclosed, unfilled slot renders default/self-closing empty, extend/include no template attr (23 tests)
- **Total: 142 tests** (verified by `zig build test`, all passing, zero memory leaks)
