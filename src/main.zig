const std = @import("std");
const decomment = @import("decomment");
const build_options = @import("build_options");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const max_input_bytes: usize = 1024 * 1024 * 1024;

const Mode = enum { emit, write, check };

const Cli = struct {
    mode: Mode = .emit,
    output_path: ?[]const u8 = null,
    jsx_override: ?bool = null,
    language: ?[]const u8 = null,
    list_languages: bool = false,
    help: bool = false,
    version: bool = false,
    inputs: std.ArrayList([]const u8) = .empty,
};

const CliError = error{
    MissingOutputPath,
    MissingLanguage,
    UnknownOption,
    ConflictingModes,
    OutputWithWriteOrCheck,
    TooManyInputs,
    WriteNeedsInput,
    CannotWriteStdin,
};

pub fn main(init: std.process.Init) !void {
    const exit_code = run(init) catch |err| {
        if (err != error.Reported) std.debug.print("decomment: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    if (exit_code != 0) std.process.exit(exit_code);
}

fn run(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const cli = parseArgs(arena, args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |cli_err| {
            reportCliError(cli_err, args);
            return error.Reported;
        },
    };

    if (cli.help) {
        try Io.File.stdout().writeStreamingAll(init.io, usage);
        return 0;
    }
    if (cli.version) {
        try Io.File.stdout().writeStreamingAll(init.io, "decomment " ++ build_options.version ++ "\n");
        return 0;
    }
    if (cli.list_languages) {
        try listLanguages(init.io);
        return 0;
    }

    const allocator = std.heap.page_allocator;
    return switch (cli.mode) {
        .emit => emitOne(init.io, allocator, cli),
        .write => writeFiles(init.io, allocator, cli),
        .check => checkFiles(init.io, allocator, cli),
    };
}

fn parseArgs(allocator: Allocator, args: []const []const u8) (Allocator.Error || CliError)!Cli {
    var cli: Cli = .{};
    errdefer cli.inputs.deinit(allocator);
    var positional_only = false;
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!positional_only and std.mem.eql(u8, arg, "--")) {
            positional_only = true;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help"))) {
            cli.help = true;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version"))) {
            cli.version = true;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--write"))) {
            if (cli.mode == .check) return error.ConflictingModes;
            cli.mode = .write;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--check"))) {
            if (cli.mode == .write) return error.ConflictingModes;
            cli.mode = .check;
            continue;
        }
        if (!positional_only and std.mem.eql(u8, arg, "--jsx")) {
            cli.jsx_override = true;
            continue;
        }
        if (!positional_only and std.mem.eql(u8, arg, "--no-jsx")) {
            cli.jsx_override = false;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--language"))) {
            i += 1;
            if (i >= args.len) return error.MissingLanguage;
            cli.language = args[i];
            continue;
        }
        if (!positional_only and std.mem.startsWith(u8, arg, "--language=")) {
            const value = arg["--language=".len..];
            if (value.len == 0) return error.MissingLanguage;
            cli.language = value;
            continue;
        }
        if (!positional_only and std.mem.eql(u8, arg, "--list-languages")) {
            cli.list_languages = true;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output"))) {
            i += 1;
            if (i >= args.len) return error.MissingOutputPath;
            cli.output_path = args[i];
            continue;
        }
        if (!positional_only and std.mem.startsWith(u8, arg, "--output=")) {
            const value = arg["--output=".len..];
            if (value.len == 0) return error.MissingOutputPath;
            cli.output_path = value;
            continue;
        }
        if (!positional_only and arg.len > 1 and arg[0] == '-') return error.UnknownOption;
        try cli.inputs.append(allocator, arg);
    }

    if (cli.help or cli.version or cli.list_languages) return cli;
    if (cli.output_path != null and cli.mode != .emit) return error.OutputWithWriteOrCheck;
    switch (cli.mode) {
        .emit => if (cli.inputs.items.len > 1) return error.TooManyInputs,
        .write => {
            if (cli.inputs.items.len == 0) return error.WriteNeedsInput;
            for (cli.inputs.items) |path| if (std.mem.eql(u8, path, "-")) return error.CannotWriteStdin;
        },
        .check => {},
    }
    return cli;
}

fn reportCliError(err: CliError, args: []const []const u8) void {
    _ = args;
    switch (err) {
        error.MissingOutputPath => std.debug.print("decomment: --output requires a path\n", .{}),
        error.MissingLanguage => std.debug.print("decomment: --language requires a language name\n", .{}),
        error.UnknownOption => std.debug.print("decomment: unknown option\n", .{}),
        error.ConflictingModes => std.debug.print("decomment: --write and --check cannot be used together\n", .{}),
        error.OutputWithWriteOrCheck => std.debug.print("decomment: --output cannot be used with --write or --check\n", .{}),
        error.TooManyInputs => std.debug.print("decomment: multiple inputs require --write or --check\n", .{}),
        error.WriteNeedsInput => std.debug.print("decomment: --write requires at least one file\n", .{}),
        error.CannotWriteStdin => std.debug.print("decomment: --write cannot be used with stdin ('-')\n", .{}),
    }
    std.debug.print("Try 'decomment --help' for usage.\n", .{});
}

fn emitOne(io: Io, allocator: Allocator, cli: Cli) !u8 {
    const path = if (cli.inputs.items.len == 0) "-" else cli.inputs.items[0];
    var result = stripPath(io, allocator, path, cli.language, cli.jsx_override) catch |err| {
        reportPathError(if (std.mem.eql(u8, path, "-")) "stdin" else path, err);
        return error.Reported;
    };
    defer result.deinit(allocator);

    if (cli.output_path) |output_path| {
        if (std.mem.eql(u8, output_path, "-")) try Io.File.stdout().writeStreamingAll(io, result.code) else try writeAtomic(io, output_path, result.code, null);
    } else try Io.File.stdout().writeStreamingAll(io, result.code);
    return 0;
}

fn writeFiles(io: Io, allocator: Allocator, cli: Cli) !u8 {
    for (cli.inputs.items) |path| {
        var result = stripPath(io, allocator, path, cli.language, cli.jsx_override) catch |err| {
            reportPathError(path, err);
            return error.Reported;
        };
        defer result.deinit(allocator);
        if (result.comments_removed == 0) continue;

        const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
            reportPathError(path, err);
            return error.Reported;
        };
        const stat = file.stat(io) catch |err| {
            file.close(io);
            reportPathError(path, err);
            return error.Reported;
        };
        file.close(io);
        writeAtomic(io, path, result.code, stat.permissions) catch |err| {
            reportPathError(path, err);
            return error.Reported;
        };
    }
    return 0;
}

fn checkFiles(io: Io, allocator: Allocator, cli: Cli) !u8 {
    var changed = false;
    if (cli.inputs.items.len == 0) {
        var result = stripPath(io, allocator, "-", cli.language, cli.jsx_override) catch |err| {
            reportPathError("stdin", err);
            return error.Reported;
        };
        defer result.deinit(allocator);
        if (result.comments_removed != 0) {
            std.debug.print("stdin: {d} comment{s}\n", .{ result.comments_removed, if (result.comments_removed == 1) "" else "s" });
            changed = true;
        }
    } else {
        for (cli.inputs.items) |path| {
            var result = stripPath(io, allocator, path, cli.language, cli.jsx_override) catch |err| {
                reportPathError(path, err);
                return error.Reported;
            };
            defer result.deinit(allocator);
            if (result.comments_removed != 0) {
                std.debug.print("{s}: {d} comment{s}\n", .{ path, result.comments_removed, if (result.comments_removed == 1) "" else "s" });
                changed = true;
            }
        }
    }
    return if (changed) 1 else 0;
}

fn stripPath(io: Io, allocator: Allocator, path: []const u8, language_name: ?[]const u8, jsx_override: ?bool) !decomment.Result {
    const source = try readPath(io, allocator, path);
    defer allocator.free(source);

    var system = decomment.builtinSystem();
    return system.stripAlloc(allocator, source, .{
        .language = language_name,
        .path = if (std.mem.eql(u8, path, "-")) null else path,
        .jsx_override = jsx_override,
    });
}

fn listLanguages(io: Io) !void {
    for (decomment.builtin_plugins) |plugin| {
        try Io.File.stdout().writeStreamingAll(io, plugin.id);
        if (plugin.names.len != 0) {
            try Io.File.stdout().writeStreamingAll(io, " (");
            for (plugin.names, 0..) |name, i| {
                if (i != 0) try Io.File.stdout().writeStreamingAll(io, ", ");
                try Io.File.stdout().writeStreamingAll(io, name);
            }
            try Io.File.stdout().writeStreamingAll(io, ")");
        }
        try Io.File.stdout().writeStreamingAll(io, "\n");
    }
}

fn readPath(io: Io, allocator: Allocator, path: []const u8) ![]u8 {
    if (!std.mem.eql(u8, path, "-")) return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_input_bytes));
    var buffer: [16 * 1024]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(max_input_bytes)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => |other| return other,
    };
}

fn writeAtomic(io: Io, path: []const u8, bytes: []const u8, permissions: ?Io.File.Permissions) !void {
    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .permissions = permissions orelse .default_file, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

fn reportPathError(path: []const u8, err: anyerror) void {
    std.debug.print("decomment: {s}: {s}\n", .{ path, friendlyError(err) });
}

fn friendlyError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "file not found",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "is a directory",
        error.StreamTooLong => "input exceeds 1 GiB limit",
        error.UnknownLanguage => "unknown language (use --language NAME or --list-languages)",
        error.UnterminatedString => "unterminated string literal",
        error.UnterminatedTemplate => "unterminated template literal",
        error.UnterminatedTemplateExpression => "unterminated template expression",
        error.UnterminatedBlockComment => "unterminated block comment",
        error.UnterminatedJsx => "unterminated JSX element",
        error.UnterminatedJsxExpression => "unterminated JSX expression",
        error.NestingTooDeep => "syntax nesting exceeds 1024 levels",
        else => @errorName(err),
    };
}

const usage =
    \\Usage: decomment [OPTIONS] [FILE]
    \\
    \\Remove comments from source code through one plugin-driven system.
    \\The language plugin is detected from FILE; stdin defaults to ECMAScript/JavaScript.
    \\
    \\Options:
    \\  -w, --write          Rewrite one or more files atomically in place
    \\  -c, --check          Report files containing comments; exit 1 if found
    \\  -o, --output PATH    Write one input to PATH instead of stdout
    \\  -l, --language NAME  Override language-plugin detection
    \\      --list-languages List built-in internal plugins and accepted language names
    \\      --jsx            Force JSX parsing inside the ECMAScript plugin
    \\      --no-jsx         Disable JSX parsing inside the ECMAScript plugin
    \\  -h, --help           Show this help
    \\  -V, --version        Show the version
    \\
    \\Examples:
    \\  decomment app.ts > app.clean.ts
    \\  decomment main.py --output main.clean.py
    \\  cat query.sql | decomment --language sql
    \\  decomment --write src/a.c scripts/tool.py app.ts
    \\  decomment --check src/**/*.rs
    \\
;

test "parse write mode and language" {
    const args = [_][]const u8{ "decomment", "--write", "--language", "typescript", "a.ts", "b.js" };
    var cli = try parseArgs(std.testing.allocator, &args);
    defer cli.inputs.deinit(std.testing.allocator);
    try std.testing.expectEqual(Mode.write, cli.mode);
    try std.testing.expectEqualStrings("typescript", cli.language.?);
    try std.testing.expectEqual(@as(usize, 2), cli.inputs.items.len);
}

test "reject conflicting modes" {
    const args = [_][]const u8{ "decomment", "--write", "--check", "a.ts" };
    try std.testing.expectError(error.ConflictingModes, parseArgs(std.testing.allocator, &args));
}
