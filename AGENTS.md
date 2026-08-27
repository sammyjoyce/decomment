# AGENTS.md

## Purpose and sources of truth

`decomment` is a dependency-free Zig 0.16.0 library and CLI that blanks source comments without moving later source positions.

- `README.md` defines the public library/CLI behavior and documents known lexical gaps.
- `build.zig.zon` is the package and version source of truth. `build.zig` imports its version for `--version`, and `flake.nix` reads it for the Nix package.
- `src/root.zig` is the public API, plugin registry, built-in language mapping, and language/extension dispatch.
- `src/javascript.zig` is the dedicated syntax-aware ECMAScript scanner.
- `src/nix.zig` is the dedicated syntax-aware Nix scanner.
- `src/generic.zig` is the profile-driven scanner used by the remaining built-ins.
- `src/main.zig` owns argument parsing, file I/O, diagnostics, exit codes, and atomic rewrites.

## Commands

Use Zig 0.16.0. `nix develop` provides the pinned Zig and ZLS environment when Nix is available.

```sh
# Run the CLI from the build graph; arguments after -- go to decomment.
zig build run -- --version
zig build run -- [decomment arguments]

# Fast scanner/library tests while iterating.
zig test src/generic.zig
zig test src/javascript.zig
zig test src/nix.zig
zig test src/root.zig

# Full verification. This matches CI and must include both test and build.
zig fmt --check build.zig src
zig build test
zig build
```

`zig build test` runs module tests, CLI unit tests, and subprocess integration tests against the emitted executable. CI runs the full verification on Linux, macOS, and Windows.

Nix packaging is separate from normal Zig verification:

- `nix build` deliberately skips tests.
- `nix flake check` includes the package build and the test-enabled derivation.
- Flake outputs intentionally cover `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`, not `x86_64-darwin`.

## Architecture and control flow

All public stripping routes through `System`: resolve one active `Plugin`, then dispatch to the dedicated ECMAScript scanner, the dedicated Nix scanner, or a generic lexical `Profile`. Do not add a language-specific bypass around `System`.

To add or change a built-in language:

1. Reuse or define a profile in `src/root.zig`, or extend `Plugin.Implementation` for a dedicated scanner when a profile cannot model the syntax safely.
2. Define the plugin in `plugins` with its canonical id, aliases, and suffixes.
3. Add it to `builtin_plugins`. That ordered array drives installation and `--list-languages` output.
4. Put scanner semantics in the scanner file and resolution/default tests in `src/root.zig`.

Plugin registration has non-obvious ordering semantics:

- The registry is a fixed 64-slot array.
- Name and path resolution are case-insensitive first-match scans; path matching is raw suffix matching. Avoid aliases or suffixes that collide with an earlier plugin.
- `requires` dependencies must already be installed. Providers therefore precede dependents in `builtin_plugins`; built-in installation treats failure as unreachable.
- Recovering a provider leaves dependents registered but unresolved until the provider is restored.
- `Effect` receipts are tied to a slot generation and cannot be reused after recovery.

The CLI creates a fresh built-in `System` for each input. Runtime installation/recovery is a library concern, not persistent CLI state.

## Behavioral invariants

Comment removal means blanking, not deletion. Preserve source length and line terminators so all later byte offsets and line positions remain stable. ECMAScript additionally preserves UTF-16 column counts for JS/TS tooling. Keep the scanners' different replacement strategies:

- `src/generic.zig` replaces non-whitespace comment bytes with ASCII spaces because many target languages do not accept arbitrary Unicode whitespace.
- `src/javascript.zig` chooses same-width ECMAScript whitespace for multi-byte code points so both UTF-8 byte offsets and UTF-16 positions remain stable.

Do not collapse the dedicated ECMAScript scanner into a generic profile. Its lexical state distinguishes comments from regex literals, division, templates, JSX child/attribute data, JSX expressions, TSX generic arrows, hashbangs, and ASI-sensitive contexts. Malformed ECMAScript strings, templates, block comments, and JSX return errors; the generic scanner is intentionally more tolerant of malformed single-line strings and reports only unterminated block comments.

Nix also requires its dedicated scanner. Preserve comment-looking text in double-quoted strings, indented strings, URI literals, and lookup paths, while scanning `${ ... }` interpolation as Nix code. Interpolations may contain nested strings, interpolations, and attribute-set braces. Nix block comments are non-nested and stop at the first `*/`; a leading hashbang is preserved.

ECMAScript selection precedence is important:

1. An explicit `jsx_override` wins.
2. An explicit language wins over the path.
3. Otherwise the path suffix controls the mode.
4. Pathless input defaults to JSX-capable JavaScript.

Consequently JavaScript/JSX enables JSX but not TypeScript, plain `.ts`/`.mts`/`.cts` enables TypeScript but not JSX, and TSX enables both. Preserve these distinctions when changing language resolution.

Generic-profile matching checks line strings, strings, block comments, then line comments. Longest-prefix selection is only within each category. Zig's `\\` multiline string line must therefore be recognized before `//` comments and preserved through end of line. Known profile gaps for Rust raw strings, SQL dialect dollar quoting, and Lua long brackets with equals signs are intentional; they require dedicated implementations rather than broader heuristics that regress other inputs.

`Result.code` is owned by the caller and must be released with `Result.deinit` using the allocator that created it.

## CLI contracts

The CLI reads the complete input, then allocates a same-sized output buffer; the 1 GiB input limit is not a streaming-memory bound.

- Emit mode accepts zero or one input; zero or `-` means stdin.
- `--write` requires file paths and rejects stdin. It writes only changed files via atomic replacement and preserves existing permissions.
- `--check` with no paths checks stdin.
- Multi-file `--write` and `--check` process inputs in argument order and continue after ordinary per-file errors; only out-of-memory aborts the loop.
- Atomicity is per file, not per batch. Successful earlier rewrites remain if a later input fails.
- Exit codes are part of the public contract: write uses `0`/`2`; check uses `0` for clean, `1` for comments found, and `2` for an incomplete run.
- Clean files are silent in check mode. Diagnostics and comment counts go to stderr.

## Testing conventions

Tests live beside the behavior they protect:

- `src/generic.zig`: profile scanner and byte-preservation behavior.
- `src/javascript.zig`: ECMAScript lexical ambiguity, layout invariants, malformed input, and idempotence.
- `src/nix.zig`: Nix strings, interpolation, paths/URIs, hashbangs, malformed input, and idempotence.
- `src/root.zig`: plugin lifecycle, resolution, language defaults, and cross-scanner routing.
- `src/main.zig`: argument parsing.
- `src/cli_integration_test.zig`: real process exit codes, exact stderr, atomic filesystem effects, and partial batch success.

For scanner changes, assert preserved syntax, removed comment text, comment count, stable layout, and a second stripping pass that removes zero comments when applicable. CLI integration tests intentionally compare diagnostics exactly; update them when changing user-visible wording or summaries.

## Packaging gotchas

`build.zig.zon` and the `flake.nix` source fileset intentionally list the files included in package builds. If runtime/build-required files move outside the current paths, update both lists or package/Nix builds may omit them. If the layout parsed by `flake.nix` changes, also review its fallback version so package metadata cannot silently drift.
