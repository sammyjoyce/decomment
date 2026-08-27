const std = @import("std");
const Allocator = std.mem.Allocator;

const javascript = @import("javascript.zig");
const nix = @import("nix.zig");
const generic = @import("generic.zig");

pub const Result = struct {
    code: []u8,
    comments_removed: usize,

    pub fn deinit(self: *Result, allocator: Allocator) void {
        allocator.free(self.code);
        self.* = undefined;
    }
};

pub const Invocation = struct {
    /// The explicit language spelling used by the caller, if any.
    language: ?[]const u8 = null,
    /// Path used for extension-driven behavior such as JSX/TSX.
    path: ?[]const u8 = null,
    /// Compatibility override for ECMAScript JSX handling.
    jsx_override: ?bool = null,
};

pub const Plugin = struct {
    id: []const u8,
    names: []const []const u8,
    extensions: []const []const u8,
    requires: []const []const u8 = &.{},
    notes: []const u8 = "",
    implementation: Implementation,

    pub const Implementation = union(enum) {
        ecmascript,
        nix,
        generic: *const generic.Profile,
    };

    pub fn stripAlloc(self: *const Plugin, allocator: Allocator, source: []const u8, invocation: Invocation) !Result {
        return switch (self.implementation) {
            .ecmascript => blk: {
                const result = try javascript.stripAlloc(allocator, source, .{
                    .jsx = resolveJsx(invocation),
                    .typescript = resolveTypeScript(invocation),
                });
                break :blk .{ .code = result.code, .comments_removed = result.comments_removed };
            },
            .nix => blk: {
                const result = try nix.stripAlloc(allocator, source);
                break :blk .{ .code = result.code, .comments_removed = result.comments_removed };
            },
            .generic => |profile| blk: {
                const result = try generic.stripAlloc(allocator, source, profile);
                break :blk .{ .code = result.code, .comments_removed = result.comments_removed };
            },
        };
    }
};

pub const SystemError = error{ MissingDependency, RegistryFull, StaleEffect, UnknownLanguage };

/// The single decomment runtime. Language support is composed only through
/// internal plugins; scanner implementations are private details of plugins.
///
/// Plugin installation is a revertible effect: installPlugin returns a receipt
/// that can remove precisely that registration later. `requires` is the plugin's
/// coeffect specification: a registered plugin is resolvable only while all of
/// its required plugin ids are present.
pub const System = struct {
    const max_plugins = 64;

    slots: [max_plugins]?*const Plugin = .{null} ** max_plugins,
    generations: [max_plugins]u32 = .{0} ** max_plugins,

    pub const Effect = struct {
        slot: usize,
        generation: u32,
    };

    pub fn init() System {
        return .{};
    }

    pub fn installPlugin(self: *System, plugin: *const Plugin) SystemError!Effect {
        if (!self.dependenciesSatisfied(plugin)) return error.MissingDependency;

        for (&self.slots, 0..) |*slot, i| {
            if (slot.* == null) {
                self.generations[i] +%= 1;
                slot.* = plugin;
                return .{ .slot = i, .generation = self.generations[i] };
            }
        }
        return error.RegistryFull;
    }

    /// Reverts exactly one plugin-registration effect.
    /// Dependents remain registered but become unresolved until their required
    /// provider is installed again.
    pub fn recover(self: *System, effect: Effect) SystemError!void {
        if (effect.slot >= self.slots.len or
            self.generations[effect.slot] != effect.generation or
            self.slots[effect.slot] == null)
        {
            return error.StaleEffect;
        }
        self.slots[effect.slot] = null;
    }

    pub fn resolveName(self: *const System, name: []const u8) ?*const Plugin {
        for (self.slots) |maybe_plugin| if (maybe_plugin) |plugin| {
            if (!self.isActive(plugin)) continue;
            if (std.ascii.eqlIgnoreCase(name, plugin.id)) return plugin;
            for (plugin.names) |candidate| {
                if (std.ascii.eqlIgnoreCase(name, candidate)) return plugin;
            }
        };
        return null;
    }

    pub fn resolvePath(self: *const System, path: []const u8) ?*const Plugin {
        for (self.slots) |maybe_plugin| if (maybe_plugin) |plugin| {
            if (!self.isActive(plugin)) continue;
            for (plugin.extensions) |ext| {
                if (endsWithIgnoreCase(path, ext)) return plugin;
            }
        };
        return null;
    }

    pub fn stripAlloc(self: *const System, allocator: Allocator, source: []const u8, invocation: Invocation) !Result {
        const plugin = if (invocation.language) |name|
            self.resolveName(name) orelse return error.UnknownLanguage
        else if (invocation.path) |path|
            self.resolvePath(path) orelse return error.UnknownLanguage
        else
            self.resolveName("javascript") orelse return error.UnknownLanguage;

        return plugin.stripAlloc(allocator, source, invocation);
    }

    fn dependenciesSatisfied(self: *const System, plugin: *const Plugin) bool {
        for (plugin.requires) |required_id| {
            if (self.findInstalledById(required_id) == null) return false;
        }
        return true;
    }

    fn isActive(self: *const System, plugin: *const Plugin) bool {
        return self.dependenciesSatisfied(plugin);
    }

    fn findInstalledById(self: *const System, id: []const u8) ?*const Plugin {
        for (self.slots) |maybe_plugin| if (maybe_plugin) |plugin| {
            if (std.ascii.eqlIgnoreCase(plugin.id, id)) return plugin;
        };
        return null;
    }
};

// ------------------------- shared lexical profiles -------------------------
// These are implementation data, not runtime components. The runtime composes
// language plugins only.
const quote_c = [_]generic.StringSyntax{
    .{ .start = "\"", .end = "\"" },
    .{ .start = "'", .end = "'" },
};
const quote_go = [_]generic.StringSyntax{
    .{ .start = "`", .end = "`", .escape = null, .multiline = true },
    .{ .start = "\"", .end = "\"" },
    .{ .start = "'", .end = "'" },
};
const quote_triple = [_]generic.StringSyntax{
    .{ .start = "\"\"\"", .end = "\"\"\"", .multiline = true },
    .{ .start = "'''", .end = "'''", .multiline = true },
    .{ .start = "\"", .end = "\"" },
    .{ .start = "'", .end = "'" },
};
const quote_sql = [_]generic.StringSyntax{
    .{ .start = "'", .end = "'", .escape = null, .multiline = true, .doubled_end = true },
    .{ .start = "\"", .end = "\"", .escape = null, .multiline = true, .doubled_end = true },
    .{ .start = "`", .end = "`", .escape = null, .multiline = true, .doubled_end = true },
};
const quote_shell = [_]generic.StringSyntax{
    .{ .start = "\"", .end = "\"", .multiline = true },
    .{ .start = "'", .end = "'", .escape = null, .multiline = true },
};

const c_profile = generic.Profile{
    .line_comments = &.{.{ .start = "//" }},
    .block_comments = &.{.{ .start = "/*", .end = "*/" }},
    .strings = &quote_c,
};
const nested_c_profile = generic.Profile{
    .line_comments = &.{.{ .start = "//" }},
    .block_comments = &.{.{ .start = "/*", .end = "*/", .nested = true }},
    .strings = &quote_triple,
};
const go_profile = generic.Profile{
    .line_comments = &.{.{ .start = "//" }},
    .block_comments = &.{.{ .start = "/*", .end = "*/" }},
    .strings = &quote_go,
};
// Zig has no block comments. `//`, `///` and `//!` are all line comments, and
// `\\` starts a multiline string literal that runs to the end of the line with
// no escape processing, so its contents must never be scanned for comments.
const zig_profile = generic.Profile{
    .line_comments = &.{.{ .start = "//" }},
    .strings = &quote_c,
    .line_strings = &.{.{ .start = "\\\\" }},
};
const python_profile = generic.Profile{ .line_comments = &.{.{ .start = "#" }}, .strings = &quote_triple, .preserve_hashbang = true };
const shell_profile = generic.Profile{ .line_comments = &.{.{ .start = "#", .boundary = .token_boundary }}, .strings = &quote_shell, .preserve_hashbang = true };
const sql_profile = generic.Profile{ .line_comments = &.{.{ .start = "--" }}, .block_comments = &.{.{ .start = "/*", .end = "*/" }}, .strings = &quote_sql };
const css_profile = generic.Profile{ .block_comments = &.{.{ .start = "/*", .end = "*/" }}, .strings = &quote_c };
const scss_profile = generic.Profile{ .line_comments = &.{.{ .start = "//" }}, .block_comments = &.{.{ .start = "/*", .end = "*/" }}, .strings = &quote_c };
const html_profile = generic.Profile{ .block_comments = &.{.{ .start = "<!--", .end = "-->" }}, .strings = &quote_c };
const haskell_profile = generic.Profile{ .line_comments = &.{.{ .start = "--" }}, .block_comments = &.{.{ .start = "{-", .end = "-}", .nested = true }}, .strings = &quote_c };
const ocaml_profile = generic.Profile{ .block_comments = &.{.{ .start = "(*", .end = "*)", .nested = true }}, .strings = &quote_c };
const lua_profile = generic.Profile{ .line_comments = &.{.{ .start = "--" }}, .block_comments = &.{.{ .start = "--[[", .end = "]]" }}, .strings = &quote_c, .preserve_hashbang = true };
const powershell_profile = generic.Profile{ .line_comments = &.{.{ .start = "#" }}, .block_comments = &.{.{ .start = "<#", .end = "#>" }}, .strings = &quote_c };
const hash_profile = generic.Profile{ .line_comments = &.{.{ .start = "#" }}, .strings = &quote_c };
const php_profile = generic.Profile{ .line_comments = &.{ .{ .start = "//" }, .{ .start = "#" } }, .block_comments = &.{.{ .start = "/*", .end = "*/" }}, .strings = &quote_c };

// ----------------------------- internal plugins ----------------------------
pub const plugins = struct {
    /// JavaScript, TypeScript, JSX and TSX are one internal ECMAScript plugin.
    /// There is no ECMAScript engine outside the plugin system.
    pub const ecmascript = Plugin{
        .id = "ecmascript",
        .names = &.{ "javascript", "js", "typescript", "ts", "jsx", "tsx" },
        .extensions = &.{ ".js", ".mjs", ".cjs", ".ts", ".mts", ".cts", ".jsx", ".tsx" },
        .implementation = .ecmascript,
    };
    pub const c = genericPlugin("c", &.{"c"}, &.{ ".c", ".h" }, &c_profile, "");
    pub const cpp = genericPlugin("cpp", &.{ "cpp", "c++", "cxx" }, &.{ ".cc", ".cpp", ".cxx", ".hh", ".hpp", ".hxx" }, &c_profile, "");
    pub const java = genericPlugin("java", &.{"java"}, &.{".java"}, &c_profile, "");
    pub const csharp = genericPlugin("csharp", &.{ "csharp", "c#", "cs" }, &.{".cs"}, &c_profile, "");
    pub const go = genericPlugin("go", &.{"go"}, &.{".go"}, &go_profile, "");
    pub const rust = genericPlugin("rust", &.{ "rust", "rs" }, &.{".rs"}, &nested_c_profile, "raw strings with comment markers require a dedicated Rust plugin implementation");
    /// Also covers ZON, which shares Zig's comment and string-literal syntax.
    pub const zig = genericPlugin("zig", &.{ "zig", "zon" }, &.{ ".zig", ".zon" }, &zig_profile, "");
    pub const swift = genericPlugin("swift", &.{"swift"}, &.{".swift"}, &nested_c_profile, "");
    pub const kotlin = genericPlugin("kotlin", &.{ "kotlin", "kt" }, &.{ ".kt", ".kts" }, &nested_c_profile, "");
    pub const dart = genericPlugin("dart", &.{"dart"}, &.{".dart"}, &nested_c_profile, "");
    pub const php = genericPlugin("php", &.{"php"}, &.{ ".php", ".phtml" }, &php_profile, "");
    pub const python = genericPlugin("python", &.{ "python", "py" }, &.{ ".py", ".pyw", ".pyi" }, &python_profile, "");
    pub const shell = genericPlugin("shell", &.{ "shell", "sh", "bash", "zsh" }, &.{ ".sh", ".bash", ".zsh" }, &shell_profile, "");
    pub const sql = genericPlugin("sql", &.{"sql"}, &.{".sql"}, &sql_profile, "dialect-specific dollar-quoted strings require a dialect plugin");
    pub const css = genericPlugin("css", &.{"css"}, &.{".css"}, &css_profile, "");
    pub const scss = genericPlugin("scss", &.{ "scss", "sass", "less" }, &.{ ".scss", ".sass", ".less" }, &scss_profile, "");
    pub const html = genericPlugin("html", &.{"html"}, &.{ ".html", ".htm" }, &html_profile, "");
    pub const xml = genericPlugin("xml", &.{"xml"}, &.{ ".xml", ".svg" }, &html_profile, "");
    pub const haskell = genericPlugin("haskell", &.{ "haskell", "hs" }, &.{ ".hs", ".lhs" }, &haskell_profile, "");
    pub const ocaml = genericPlugin("ocaml", &.{"ocaml"}, &.{ ".ml", ".mli" }, &ocaml_profile, "");
    pub const lua = genericPlugin("lua", &.{"lua"}, &.{".lua"}, &lua_profile, "long-bracket strings/comments with equals signs require a dedicated Lua plugin implementation");
    pub const powershell = genericPlugin("powershell", &.{ "powershell", "ps1" }, &.{ ".ps1", ".psm1", ".psd1" }, &powershell_profile, "");
    pub const r = genericPlugin("r", &.{"r"}, &.{ ".r", ".R" }, &hash_profile, "");
    pub const jsonc = genericPlugin("jsonc", &.{"jsonc"}, &.{".jsonc"}, &c_profile, "");
    pub const nix = Plugin{
        .id = "nix",
        .names = &.{"nix"},
        .extensions = &.{".nix"},
        .implementation = .nix,
    };
};

pub const builtin_plugins = [_]*const Plugin{
    &plugins.ecmascript,
    &plugins.c,
    &plugins.cpp,
    &plugins.java,
    &plugins.csharp,
    &plugins.go,
    &plugins.rust,
    &plugins.zig,
    &plugins.swift,
    &plugins.kotlin,
    &plugins.dart,
    &plugins.php,
    &plugins.python,
    &plugins.shell,
    &plugins.sql,
    &plugins.css,
    &plugins.scss,
    &plugins.html,
    &plugins.xml,
    &plugins.haskell,
    &plugins.ocaml,
    &plugins.lua,
    &plugins.powershell,
    &plugins.r,
    &plugins.jsonc,
    &plugins.nix,
};

pub fn builtinSystem() System {
    var system = System.init();
    for (builtin_plugins) |plugin| {
        _ = system.installPlugin(plugin) catch unreachable;
    }
    return system;
}

/// Backward-compatible convenience API. It still routes through the same
/// plugin system; no language bypasses System.
pub fn stripAlloc(allocator: Allocator, source: []const u8, invocation: Invocation) !Result {
    var system = builtinSystem();
    return system.stripAlloc(allocator, source, invocation);
}

fn genericPlugin(
    comptime id: []const u8,
    comptime names: []const []const u8,
    comptime extensions: []const []const u8,
    profile: *const generic.Profile,
    comptime notes: []const u8,
) Plugin {
    return .{
        .id = id,
        .names = names,
        .extensions = extensions,
        .notes = notes,
        .implementation = .{ .generic = profile },
    };
}

fn resolveJsx(invocation: Invocation) bool {
    if (invocation.jsx_override) |value| return value;
    if (invocation.language) |name| return !isPlainTypeScriptName(name);
    if (invocation.path) |path| return !isPlainTypeScriptPath(path);
    return true;
}

fn isPlainTypeScriptName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "typescript") or std.ascii.eqlIgnoreCase(name, "ts");
}

fn isPlainTypeScriptPath(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".ts") or endsWithIgnoreCase(path, ".mts") or endsWithIgnoreCase(path, ".cts");
}

fn resolveTypeScript(invocation: Invocation) bool {
    if (invocation.language) |name| {
        return isPlainTypeScriptName(name) or std.ascii.eqlIgnoreCase(name, "tsx");
    }
    if (invocation.path) |path| {
        return isPlainTypeScriptPath(path) or endsWithIgnoreCase(path, ".tsx");
    }
    return false;
}

fn endsWithIgnoreCase(path: []const u8, suffix: []const u8) bool {
    if (suffix.len > path.len) return false;
    return std.ascii.eqlIgnoreCase(path[path.len - suffix.len ..], suffix);
}

test "ECMAScript is an internal plugin in the same system" {
    var system = System.init();
    try std.testing.expect(system.resolveName("javascript") == null);
    const effect = try system.installPlugin(&plugins.ecmascript);
    try std.testing.expect(system.resolveName("javascript") == &plugins.ecmascript);
    try std.testing.expect(system.resolveName("typescript") == &plugins.ecmascript);
    try std.testing.expect(system.resolvePath("view.tsx") == &plugins.ecmascript);
    try system.recover(effect);
    try std.testing.expect(system.resolveName("javascript") == null);
}

test "all stripping routes through plugins" {
    const allocator = std.testing.allocator;
    var system = builtinSystem();

    var js = try system.stripAlloc(allocator, "const x = /a\\/\\/b/; // remove\n", .{ .language = "javascript" });
    defer js.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), js.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, js.code, "/a\\/\\/b/") != null);

    var py = try system.stripAlloc(allocator, "x = '# keep' # remove\n", .{ .language = "python" });
    defer py.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), py.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, py.code, "# keep") != null);
}

test "JavaScript inputs are JSX-capable by default" {
    const allocator = std.testing.allocator;
    var system = builtinSystem();
    const source =
        \\const Link = () => <Text>Read https://example.com before continuing.</Text>;
        \\// remove
        \\
    ;
    const invocations = [_]Invocation{
        .{ .path = "app.js" },
        .{ .path = "app.mjs" },
        .{ .path = "app.cjs" },
        .{},
        .{ .language = "javascript" },
        .{ .language = "js" },
        .{ .language = "ecmascript" },
    };

    for (invocations) |invocation| {
        var result = try system.stripAlloc(allocator, source, invocation);
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.comments_removed);
        try std.testing.expect(std.mem.indexOf(u8, result.code, "https://example.com before continuing.</Text>;") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.code, "remove") == null);
        try std.testing.expectEqual(source.len, result.code.len);
    }
}

test "JavaScript JSX text may contain apostrophes by default" {
    const allocator = std.testing.allocator;
    var system = builtinSystem();
    const source = "const Link = () => <Text>You're almost there!</Text>; // remove\n";
    const invocations = [_]Invocation{
        .{ .path = "app.js" },
        .{ .path = "app.mjs" },
        .{ .path = "app.cjs" },
        .{},
        .{ .language = "javascript" },
    };

    for (invocations) |invocation| {
        var result = try system.stripAlloc(allocator, source, invocation);
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.comments_removed);
        try std.testing.expect(std.mem.indexOf(u8, result.code, "You're almost there!</Text>;") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.code, "remove") == null);
        try std.testing.expectEqual(source.len, result.code.len);
    }
}

test "JavaScript JSX wins over TypeScript generic syntax" {
    const allocator = std.testing.allocator;
    var system = builtinSystem();
    const source = "const view = <A extends U>(go to https://example.com)</A>; // remove\n";
    const invocations = [_]Invocation{
        .{ .path = "app.js" },
        .{ .path = "app.mjs" },
        .{ .path = "app.cjs" },
        .{ .path = "app.jsx" },
        .{},
        .{ .language = "javascript" },
        .{ .language = "jsx" },
    };

    for (invocations) |invocation| {
        var result = try system.stripAlloc(allocator, source, invocation);
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.comments_removed);
        try std.testing.expect(std.mem.indexOf(u8, result.code, "https://example.com)</A>;") != null);
    }
}

test "TypeScript inputs keep JSX disabled unless requested" {
    const allocator = std.testing.allocator;
    var system = builtinSystem();
    const source = "const value = <string>input; // remove\n";
    const invocations = [_]Invocation{
        .{ .path = "app.ts" },
        .{ .path = "app.mts" },
        .{ .path = "app.cts" },
        .{ .language = "typescript" },
        .{ .language = "ts" },
    };

    for (invocations) |invocation| {
        var result = try system.stripAlloc(allocator, source, invocation);
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.comments_removed);
        try std.testing.expect(std.mem.indexOf(u8, result.code, "<string>input") != null);
    }

    var tsx = try system.stripAlloc(
        allocator,
        "const id = <T,>(x: T) => x; // remove\n",
        .{ .path = "app.tsx" },
    );
    defer tsx.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), tsx.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, tsx.code, "<T,>(x: T) => x") != null);
}

test "explicit JSX overrides win over language and extension defaults" {
    const allocator = std.testing.allocator;
    var system = builtinSystem();

    try std.testing.expect(!resolveJsx(.{ .path = "app.js", .jsx_override = false }));
    try std.testing.expect(resolveJsx(.{ .path = "app.ts", .jsx_override = true }));
    try std.testing.expect(!resolveJsx(.{ .language = "typescript", .path = "app.js" }));
    try std.testing.expect(resolveJsx(.{ .language = "javascript", .path = "app.ts" }));
    try std.testing.expect(!resolveTypeScript(.{ .path = "app.js" }));
    try std.testing.expect(resolveTypeScript(.{ .path = "app.tsx" }));
    try std.testing.expect(!resolveTypeScript(.{ .language = "javascript", .path = "app.tsx" }));
    try std.testing.expect(resolveTypeScript(.{ .language = "tsx", .path = "app.js" }));

    try std.testing.expectError(
        error.UnterminatedString,
        system.stripAlloc(
            allocator,
            "const Link = () => <Text>you're ready</Text>;",
            .{ .path = "app.js", .jsx_override = false },
        ),
    );

    var relational = try system.stripAlloc(
        allocator,
        "const obj = { of: 1 }; const Right = 2; const value = 3; const x = obj.of<Right>value; // remove\n",
        .{ .path = "app.js", .jsx_override = false },
    );
    defer relational.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), relational.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, relational.code, "obj.of<Right>value") != null);
}

test "zig multiline string literals are never scanned for comments" {
    const allocator = std.testing.allocator;
    var system = builtinSystem();

    const source =
        \\//! container doc
        \\const url =
        \\    \\ https://ziglang.org // still string text
        \\    \\ const fake = 1; // still string text
        \\;
        \\const slash = '/'; /// doc comment
        \\
    ;

    var result = try system.stripAlloc(allocator, source, .{ .path = "sample.zig" });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.comments_removed);
    try std.testing.expectEqual(source.len, result.code.len);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "https://ziglang.org // still string text") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "const fake = 1; // still string text") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "const slash = '/';") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "container doc") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "doc comment") == null);
}

test "zig plugin also resolves zon" {
    var system = builtinSystem();
    try std.testing.expect(system.resolvePath("build.zig.zon") == &plugins.zig);
    try std.testing.expect(system.resolvePath("src/main.zig") == &plugins.zig);
    try std.testing.expect(system.resolveName("zon") == &plugins.zig);
}

test "Nix uses its dedicated scanner through the plugin system" {
    const allocator = std.testing.allocator;
    var system = builtinSystem();

    try std.testing.expect(system.resolvePath("flake.nix") == &plugins.nix);
    try std.testing.expect(system.resolveName("nix") == &plugins.nix);

    const source =
        \\{
        \\  script = ''
        \\    # preserved shell text
        \\    ${let x = 1; # removed Nix comment
        \\      in x}
        \\  '';
        \\} # removed outer comment
        \\
    ;
    var result = try system.stripAlloc(allocator, source, .{ .path = "flake.nix" });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.comments_removed);
    try std.testing.expectEqual(source.len, result.code.len);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "# preserved shell text") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "removed Nix comment") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "removed outer comment") == null);
}

test "plugin dependencies behave as reactive coeffects" {
    const provider = Plugin{
        .id = "provider",
        .names = &.{"provider"},
        .extensions = &.{".provider"},
        .implementation = .{ .generic = &zig_profile },
    };
    const dependent = Plugin{
        .id = "dependent",
        .names = &.{"dependent"},
        .extensions = &.{".dependent"},
        .requires = &.{"provider"},
        .implementation = .{ .generic = &zig_profile },
    };

    var system = System.init();
    try std.testing.expectError(error.MissingDependency, system.installPlugin(&dependent));
    const provider_effect = try system.installPlugin(&provider);
    _ = try system.installPlugin(&dependent);
    try std.testing.expect(system.resolveName("dependent") != null);
    try system.recover(provider_effect);
    try std.testing.expect(system.resolveName("dependent") == null);
}

test "recovering one plugin leaves independent plugins intact" {
    var system = System.init();
    const python_effect = try system.installPlugin(&plugins.python);
    _ = try system.installPlugin(&plugins.c);
    try system.recover(python_effect);
    try std.testing.expect(system.resolveName("python") == null);
    try std.testing.expect(system.resolveName("c") != null);
}
