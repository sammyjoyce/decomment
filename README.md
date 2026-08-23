# decomment

A dependency-free Zig CLI and library for removing source-code comments while preserving byte length and line positions.

## One system, internal plugins

`decomment` has one runtime: `System`. It does not expose separate lexer engines or a special ECMAScript path.

Every supported language is installed as an internal `Plugin`. JavaScript, TypeScript, JSX, and TSX are handled by a single `ecmascript` plugin. The other built-ins are plugins too. Shared scanners and lexical profiles are implementation details behind those plugins, not runtime components.

The composition model is deliberately small:

- `System.installPlugin(plugin)` applies a reversible registration effect and returns an `Effect` receipt.
- `System.recover(effect)` removes exactly that plugin registration.
- `Plugin.requires` declares runtime plugin dependencies. A dependent remains registered but is unresolved whenever a required provider disappears, and becomes resolvable again when the provider is restored.
- Language selection and stripping always route through `System`; no language bypasses plugin resolution.

This mirrors spatiotemporal composition at the plugin boundary: reversible installation/removal provides the temporal dimension, while declared `requires` relationships provide the spatial dimension.

## Usage

```sh
# Auto-detect the internal plugin from the extension
decomment src/app.ts > build/app.ts
decomment src/main.c > build/main.c
decomment tool.py > tool.clean.py

# Explicit plugin/language name, useful for stdin
cat query.sql | decomment --language sql
cat component.tsx | decomment --language tsx

# Rewrite files atomically
decomment --write src/app.ts src/main.c scripts/tool.py

# CI check
decomment --check src/app.ts src/main.c scripts/tool.py

# Inspect built-ins
decomment --list-languages
```

## ECMAScript plugin

The internal `ecmascript` plugin accepts these language names:

- `javascript`, `js`
- `typescript`, `ts`
- `jsx`
- `tsx`

and detects `.js`, `.mjs`, `.cjs`, `.ts`, `.mts`, `.cts`, `.jsx`, and `.tsx`.

Its dedicated syntax-aware scanner remains intact, including regular-expression literals, templates, JSX/TSX, ASI-sensitive cases, hashbangs, and token-boundary preservation. The important architectural change is that this scanner is now reachable only through the same plugin interface as every other language.

## Built-in plugins

The system includes internal plugins for ECMAScript, C, C++, Java, C#, Go, Rust, Zig, Swift, Kotlin, Dart, PHP, Python, shell, SQL, CSS, SCSS/Sass/Less, HTML, XML/SVG, Haskell, OCaml, Lua, PowerShell, R, and JSONC.

Some generic-profile plugins still have explicitly documented lexical gaps: Rust raw strings, SQL dialect-specific dollar quoting, and Lua long brackets with equals signs. Those can be replaced by dedicated plugin implementations without changing the `System` API or the other plugins.

## Zig plugin

The internal `zig` plugin accepts the language names `zig` and `zon`, and detects `.zig` and `.zon`. ZON shares Zig's comment and literal syntax, so both use one plugin.

It removes `//` line comments, `///` doc comments, and `//!` container doc comments. Zig has no block comments, so `/*` and `*/` are never treated as comment markers.

Multiline string literals are preserved verbatim. A `\\` literal runs to the end of the line, takes no escapes, and has no closing delimiter, so its contents are never scanned for comment markers:

```zig
const help =
    \\ See https://ziglang.org for docs
    \\ const example = 1; // not a comment
;
```

Both `//` sequences above survive stripping. This is expressed in the generic engine as `Profile.line_strings`, a literal that begins with a prefix and ends at the line break.

## Library

```zig
const decomment = @import("decomment");

var system = decomment.builtinSystem();

var result = try system.stripAlloc(allocator, source, .{
    .language = "typescript",
});
defer result.deinit(allocator);
```

Plugin lifecycle:

```zig
var system = decomment.System.init();

const installed = try system.installPlugin(&decomment.plugins.ecmascript);
std.debug.assert(system.resolveName("typescript") != null);

try system.recover(installed);
std.debug.assert(system.resolveName("typescript") == null);
```

## Build

Requires Zig 0.16.0.

```sh
zig build
zig build test
```
