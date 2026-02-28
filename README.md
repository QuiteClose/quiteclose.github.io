# quiteclose.github.io

Personal website built with Wig, a custom static site generator written in Zig.

## Development

Build for development (includes pattern library and draft pages):

```
zig build draft
```

Start the dev server:

```
zig build serve
```

Build for production:

```
zig build
```

Run tests:

```
zig build test
```

Output goes to `zig-out/site/`.
