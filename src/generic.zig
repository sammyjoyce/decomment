const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LineComment = struct {
    start: []const u8,
    boundary: Boundary = .anywhere,

    pub const Boundary = enum { anywhere, token_boundary, line_start };
};

pub const BlockComment = struct {
    start: []const u8,
    end: []const u8,
    nested: bool = false,
};

pub const StringSyntax = struct {
    start: []const u8,
    end: []const u8,
    escape: ?u8 = '\\',
    multiline: bool = false,
    doubled_end: bool = false,
};

pub const Profile = struct {
    line_comments: []const LineComment = &.{},
    block_comments: []const BlockComment = &.{},
    strings: []const StringSyntax = &.{},
    preserve_hashbang: bool = false,
};

pub const Result = struct {
    code: []u8,
    comments_removed: usize,

    pub fn deinit(self: *Result, allocator: Allocator) void {
        allocator.free(self.code);
        self.* = undefined;
    }
};

pub const StripError = error{UnterminatedBlockComment};

pub fn stripAlloc(allocator: Allocator, source: []const u8, profile: *const Profile) (Allocator.Error || StripError)!Result {
    const output = try allocator.dupe(u8, source);
    errdefer allocator.free(output);

    var scanner: Scanner = .{ .source = source, .output = output, .profile = profile };
    try scanner.run();
    return .{ .code = output, .comments_removed = scanner.comments_removed };
}

const Scanner = struct {
    source: []const u8,
    output: []u8,
    profile: *const Profile,
    i: usize = 0,
    line_has_code: bool = false,
    comments_removed: usize = 0,

    fn run(self: *Scanner) StripError!void {
        if (std.mem.startsWith(u8, self.source, "\xEF\xBB\xBF")) self.i = 3;
        if (self.profile.preserve_hashbang and self.startsWith("#!")) {
            self.line_has_code = true;
            while (self.i < self.source.len and lineTerminatorLen(self.source, self.i) == 0) self.i += 1;
        }

        while (self.i < self.source.len) {
            const line_len = lineTerminatorLen(self.source, self.i);
            if (line_len != 0) {
                self.i += line_len;
                self.line_has_code = false;
                continue;
            }

            if (self.matchString()) |syntax| {
                self.scanString(syntax);
                self.line_has_code = true;
                continue;
            }
            if (self.matchBlock()) |block| {
                try self.stripBlock(block);
                continue;
            }
            if (self.matchLine()) |line| {
                self.stripLine(line.start.len);
                continue;
            }

            if (!isWhitespaceAt(self.source, self.i)) self.line_has_code = true;
            self.i += codePointLen(self.source, self.i);
        }
    }

    fn matchString(self: *Scanner) ?*const StringSyntax {
        var best: ?*const StringSyntax = null;
        for (self.profile.strings) |*syntax| {
            if (!self.startsWith(syntax.start)) continue;
            if (best == null or syntax.start.len > best.?.start.len) best = syntax;
        }
        return best;
    }

    fn matchBlock(self: *Scanner) ?*const BlockComment {
        var best: ?*const BlockComment = null;
        for (self.profile.block_comments) |*block| {
            if (!self.startsWith(block.start)) continue;
            if (best == null or block.start.len > best.?.start.len) best = block;
        }
        return best;
    }

    fn matchLine(self: *Scanner) ?*const LineComment {
        var best: ?*const LineComment = null;
        for (self.profile.line_comments) |*line| {
            if (!self.startsWith(line.start) or !self.boundaryAllows(line.*)) continue;
            if (best == null or line.start.len > best.?.start.len) best = line;
        }
        return best;
    }

    fn boundaryAllows(self: *Scanner, line: LineComment) bool {
        return switch (line.boundary) {
            .anywhere => true,
            .line_start => !self.line_has_code,
            .token_boundary => self.i == 0 or isWhitespaceByte(self.source[self.i - 1]) or isDelimiterByte(self.source[self.i - 1]),
        };
    }

    fn scanString(self: *Scanner, syntax: *const StringSyntax) void {
        self.i += syntax.start.len;
        while (self.i < self.source.len) {
            if (self.startsWith(syntax.end)) {
                if (syntax.doubled_end and self.i + syntax.end.len * 2 <= self.source.len and
                    std.mem.eql(u8, self.source[self.i .. self.i + syntax.end.len * 2], doubled(syntax.end)))
                {
                    self.i += syntax.end.len * 2;
                    continue;
                }
                self.i += syntax.end.len;
                return;
            }
            if (syntax.escape) |escape| {
                if (self.source[self.i] == escape) {
                    self.i += 1;
                    if (self.i < self.source.len) {
                        const ll = lineTerminatorLen(self.source, self.i);
                        self.i += if (ll != 0) ll else codePointLen(self.source, self.i);
                    }
                    continue;
                }
            }
            const ll = lineTerminatorLen(self.source, self.i);
            if (ll != 0) {
                // On malformed single-line strings, stop treating the rest of the
                // file as a string. The generic engine is deliberately tolerant.
                if (!syntax.multiline) return;
                self.i += ll;
                self.line_has_code = false;
            } else {
                self.i += codePointLen(self.source, self.i);
            }
        }
    }

    fn stripLine(self: *Scanner, prefix_len: usize) void {
        const start = self.i;
        self.i += prefix_len;
        while (self.i < self.source.len and lineTerminatorLen(self.source, self.i) == 0) self.i += codePointLen(self.source, self.i);
        blankRange(self.output, start, self.i);
        self.comments_removed += 1;
    }

    fn stripBlock(self: *Scanner, block: *const BlockComment) StripError!void {
        const start = self.i;
        self.i += block.start.len;
        var depth: usize = 1;
        while (self.i < self.source.len) {
            if (block.nested and self.startsWith(block.start)) {
                depth += 1;
                self.i += block.start.len;
                continue;
            }
            if (self.startsWith(block.end)) {
                depth -= 1;
                self.i += block.end.len;
                if (depth == 0) {
                    blankRange(self.output, start, self.i);
                    self.comments_removed += 1;
                    return;
                }
                continue;
            }
            const ll = lineTerminatorLen(self.source, self.i);
            if (ll != 0) {
                self.i += ll;
                self.line_has_code = false;
            } else self.i += codePointLen(self.source, self.i);
        }
        return error.UnterminatedBlockComment;
    }

    fn startsWith(self: *const Scanner, needle: []const u8) bool {
        return self.i + needle.len <= self.source.len and std.mem.eql(u8, self.source[self.i .. self.i + needle.len], needle);
    }
};

// Only used for one-byte quote delimiters in built-in SQL-like profiles.
fn doubled(end: []const u8) []const u8 {
    return if (std.mem.eql(u8, end, "'")) "''" else if (std.mem.eql(u8, end, "\"")) "\"\"" else if (std.mem.eql(u8, end, "`")) "``" else end;
}

/// Replaces a comment span with ASCII spaces, keeping line terminators and any
/// whitespace that is already there. Byte length and every following byte
/// offset are preserved.
///
/// A multi-byte code point becomes that many spaces rather than one same-width
/// Unicode space. The ECMAScript scanner does the opposite because JS treats
/// U+00A0 and U+2000 as whitespace, so it can also keep UTF-16 columns stable.
/// Most other languages accept only ASCII whitespace between tokens, so reusing
/// that trick here would turn any comment holding a non-ASCII character, such as
/// an en dash, into a syntax error.
fn blankRange(output: []u8, start: usize, end: usize) void {
    var cursor = start;
    while (cursor < end) {
        const ll = lineTerminatorLen(output, cursor);
        if (ll != 0) {
            cursor += ll;
            continue;
        }
        if (!isWhitespaceAt(output, cursor)) output[cursor] = ' ';
        cursor += 1;
    }
}

fn lineTerminatorLen(bytes: []const u8, i: usize) usize {
    if (i >= bytes.len) return 0;
    return switch (bytes[i]) {
        '\n' => 1,
        '\r' => if (i + 1 < bytes.len and bytes[i + 1] == '\n') 2 else 1,
        else => 0,
    };
}

fn codePointLen(bytes: []const u8, i: usize) usize {
    if (i >= bytes.len) return 0;
    const c = bytes[i];
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0 and i + 1 < bytes.len) return 2;
    if ((c & 0xF0) == 0xE0 and i + 2 < bytes.len) return 3;
    if ((c & 0xF8) == 0xF0 and i + 3 < bytes.len) return 4;
    return 1;
}

fn isWhitespaceAt(bytes: []const u8, i: usize) bool {
    if (i >= bytes.len) return false;
    return isWhitespaceByte(bytes[i]);
}

fn isWhitespaceByte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '\x0b' or c == '\x0c';
}
fn isDelimiterByte(c: u8) bool {
    return switch (c) {
        '(', ')', '[', ']', '{', '}', ';', ',', ':' => true,
        else => false,
    };
}

test "generic c-like preserves strings" {
    const p = Profile{
        .line_comments = &.{.{ .start = "//" }},
        .block_comments = &.{.{ .start = "/*", .end = "*/" }},
        .strings = &.{ .{ .start = "\"", .end = "\"" }, .{ .start = "'", .end = "'" } },
    };
    var result = try stripAlloc(std.testing.allocator, "const char *u = \"https://x\"; // bye\n/*x*/ int n;", &p);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "https://x") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "bye") == null);
}

test "non-ascii comment text is blanked with ascii spaces only" {
    const p = Profile{ .line_comments = &.{.{ .start = "//" }} };
    // The en dash is three UTF-8 bytes. It must become three ASCII spaces, not
    // one same-width Unicode space, or the result stops being valid in every
    // language that accepts only ASCII whitespace between tokens.
    var result = try stripAlloc(std.testing.allocator, "x; // en dash \xE2\x80\x93 here\ny;", &p);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("x;                    \ny;", result.code);
}

test "nested block comments" {
    const p = Profile{ .block_comments = &.{.{ .start = "{-", .end = "-}", .nested = true }} };
    var result = try stripAlloc(std.testing.allocator, "x {- a {- b -} c -} y", &p);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.comments_removed);
    try std.testing.expectEqual(result.code.len, "x {- a {- b -} c -} y".len);
}
