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
