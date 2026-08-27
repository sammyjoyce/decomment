const std = @import("std");
const cli_integration_options = @import("cli_integration_options");

const Allocator = std.mem.Allocator;
const Io = std.Io;

fn expectExited(term: std.process.Child.Term, expected: u8) !void {
    switch (term) {
        .exited => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}

fn readTestFile(dir: Io.Dir, io: Io, allocator: Allocator, path: []const u8) ![]u8 {
    return dir.readFileAlloc(io, path, allocator, .limited(1024));
}

fn decommentExecutablePath(io: Io, allocator: Allocator) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, cli_integration_options.decomment_exe });
}

test "multi-file write continues after a malformed input" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const a_source = "const a = 1; // comment A\n";
    const bad_source = "const broken = 'oops\n";
    const clean_source = "const clean = true;\n";
    const c_source = "const c = 3; // comment C\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "a.js", .data = a_source });
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.js", .data = bad_source });
    try tmp.dir.writeFile(io, .{ .sub_path = "clean.js", .data = clean_source });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.js", .data = c_source });

    const decomment_exe = try decommentExecutablePath(io, allocator);
    defer allocator.free(decomment_exe);

    const argv = [_][]const u8{
        decomment_exe,
        "--write",
        "a.js",
        "bad.js",
        "clean.js",
        "c.js",
    };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try expectExited(result.term, 2);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings(
        "decomment: bad.js: unterminated string literal\n" ++
            "decomment: --write incomplete: 4 files attempted; 2 rewritten, 1 unchanged, 1 failed\n",
        result.stderr,
    );

    const a = try readTestFile(tmp.dir, io, allocator, "a.js");
    defer allocator.free(a);
    const bad = try readTestFile(tmp.dir, io, allocator, "bad.js");
    defer allocator.free(bad);
    const clean = try readTestFile(tmp.dir, io, allocator, "clean.js");
    defer allocator.free(clean);
    const c = try readTestFile(tmp.dir, io, allocator, "c.js");
    defer allocator.free(c);
    try std.testing.expectEqual(a_source.len, a.len);
    try std.testing.expect(std.mem.indexOf(u8, a, "comment A") == null);
    try std.testing.expectEqualStrings(bad_source, bad);
    try std.testing.expectEqualStrings(clean_source, clean);
    try std.testing.expectEqual(c_source.len, c.len);
    try std.testing.expect(std.mem.indexOf(u8, c, "comment C") == null);
}

test "multi-file check continues after a malformed input" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const a_source = "const a = 1; // comment A\n";
    const bad_source = "const broken = 'oops\n";
    const clean_source = "const clean = true;\n";
    const c_source = "const c = 3; // comment C\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "a.js", .data = a_source });
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.js", .data = bad_source });
    try tmp.dir.writeFile(io, .{ .sub_path = "clean.js", .data = clean_source });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.js", .data = c_source });

    const decomment_exe = try decommentExecutablePath(io, allocator);
    defer allocator.free(decomment_exe);

    const argv = [_][]const u8{
        decomment_exe,
        "--check",
        "a.js",
        "bad.js",
        "clean.js",
        "c.js",
    };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try expectExited(result.term, 2);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings(
        "a.js: 1 comment\n" ++
            "decomment: bad.js: unterminated string literal\n" ++
            "c.js: 1 comment\n" ++
            "decomment: --check incomplete: 4 files attempted; 2 with comments, 1 clean, 1 failed\n",
        result.stderr,
    );

    const a = try readTestFile(tmp.dir, io, allocator, "a.js");
    defer allocator.free(a);
    const bad = try readTestFile(tmp.dir, io, allocator, "bad.js");
    defer allocator.free(bad);
    const clean = try readTestFile(tmp.dir, io, allocator, "clean.js");
    defer allocator.free(clean);
    const c = try readTestFile(tmp.dir, io, allocator, "c.js");
    defer allocator.free(c);
    try std.testing.expectEqualStrings(a_source, a);
    try std.testing.expectEqualStrings(bad_source, bad);
    try std.testing.expectEqualStrings(clean_source, clean);
    try std.testing.expectEqualStrings(c_source, c);
}

test "Nix files are detected and preserve comments only inside literals" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\{
        \\  script = ''
        \\    # shell text
        \\    ${let value = { nested = 1; }; # Nix interpolation comment
        \\      in value.nested}
        \\  '';
        \\} # Nix outer comment
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "flake.nix", .data = source });

    const decomment_exe = try decommentExecutablePath(io, allocator);
    defer allocator.free(decomment_exe);

    const decomment_argv = [_][]const u8{ decomment_exe, "--write", "flake.nix" };
    const decomment_result = try std.process.run(allocator, io, .{
        .argv = &decomment_argv,
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(decomment_result.stdout);
    defer allocator.free(decomment_result.stderr);

    try expectExited(decomment_result.term, 0);
    try std.testing.expectEqualStrings("", decomment_result.stdout);
    try std.testing.expectEqualStrings("", decomment_result.stderr);

    const cleaned = try readTestFile(tmp.dir, io, allocator, "flake.nix");
    defer allocator.free(cleaned);
    try std.testing.expectEqual(source.len, cleaned.len);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "# shell text") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "Nix interpolation comment") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "Nix outer comment") == null);

    const check_argv = [_][]const u8{ decomment_exe, "--check", "flake.nix" };
    const check_result = try std.process.run(allocator, io, .{
        .argv = &check_argv,
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(check_result.stdout);
    defer allocator.free(check_result.stderr);

    try expectExited(check_result.term, 0);
    try std.testing.expectEqualStrings("", check_result.stdout);
    try std.testing.expectEqualStrings("", check_result.stderr);
}
