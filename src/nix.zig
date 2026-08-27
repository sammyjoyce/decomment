const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Result = struct {
    code: []u8,
    comments_removed: usize,

    pub fn deinit(self: *Result, allocator: Allocator) void {
        allocator.free(self.code);
        self.* = undefined;
    }
};

pub const StripError = error{
    UnterminatedString,
    UnterminatedIndentedString,
    UnterminatedInterpolation,
    UnterminatedBlockComment,
    NestingTooDeep,
};

pub fn stripAlloc(allocator: Allocator, source: []const u8) (Allocator.Error || StripError)!Result {
    const output = try allocator.dupe(u8, source);
    errdefer allocator.free(output);

    var scanner: Scanner = .{ .source = source, .output = output };
    try scanner.scanCode(null);
    return .{ .code = output, .comments_removed = scanner.comments_removed };
}

const max_interpolation_nesting = 1024;

const Scanner = struct {
    source: []const u8,
    output: []u8,
    i: usize = 0,
    comments_removed: usize = 0,
    interpolation_depth: usize = 0,

    fn scanCode(self: *Scanner, terminator: ?u8) StripError!void {
        var brace_depth: usize = 0;
        while (self.i < self.source.len) {
            const c = self.source[self.i];
            if (terminator != null and c == terminator.? and brace_depth == 0) {
                self.i += 1;
                return;
            }
            if (self.startsWith("#!") and self.isHashbangStart()) {
                self.skipLine();
                continue;
            }
            if (self.startsWith("#")) {
                self.stripLineComment();
                continue;
            }
            if (self.startsWith("/*")) {
                try self.stripBlockComment();
                continue;
            }
            if (c == '"') {
                try self.scanQuotedString();
                continue;
            }
            if (self.startsWith("''") and self.canStartIndentedString()) {
                try self.scanIndentedString();
                continue;
            }
            if (self.startsWith("${")) {
                try self.scanInterpolation();
                continue;
            }
            if (terminator != null and c == '{') {
                if (brace_depth == max_interpolation_nesting) return error.NestingTooDeep;
                brace_depth += 1;
                self.i += 1;
                continue;
            }
            if (terminator != null and c == '}' and brace_depth != 0) {
                brace_depth -= 1;
                self.i += 1;
                continue;
            }
            if (c == '<' and (terminator == null or brace_depth == 0)) {
                if (self.lookupPathEnd()) |end| {
                    self.i = end;
                    continue;
                }
            }
            if (self.uriEnd()) |end| {
                self.i = end;
                continue;
            }
            self.i += codePointLen(self.source, self.i);
        }
        if (terminator != null) return error.UnterminatedInterpolation;
    }

    fn canStartIndentedString(self: *const Scanner) bool {
        return self.i == 0 or !isIdentifierChar(self.source[self.i - 1]);
    }

    fn scanQuotedString(self: *Scanner) StripError!void {
        self.i += 1;
        while (self.i < self.source.len) {
            if (self.source[self.i] == '"') {
                self.i += 1;
                return;
            }
            if (self.source[self.i] == '\\') {
                self.i += 1;
                if (self.i >= self.source.len) return error.UnterminatedString;
                self.i += codePointLen(self.source, self.i);
                continue;
            }
            if (self.startsWith("$${")) {
                self.i += 3;
                continue;
            }
            if (self.startsWith("${")) {
                try self.scanInterpolation();
                continue;
            }
            self.i += codePointLen(self.source, self.i);
        }
        return error.UnterminatedString;
    }

    fn scanIndentedString(self: *Scanner) StripError!void {
        self.i += 2;
        while (self.i < self.source.len) {
            if (self.startsWith("''$")) {
                self.i += 3;
                continue;
            }
            if (self.startsWith("''\\")) {
                self.i += 3;
                if (self.i >= self.source.len) return error.UnterminatedIndentedString;
                self.i += codePointLen(self.source, self.i);
                continue;
            }
            if (self.startsWith("$${")) {
                self.i += 3;
                continue;
            }
            if (self.startsWith("${")) {
                try self.scanInterpolation();
                continue;
            }
            if (self.startsWith("'''")) {
                self.i += 3;
                continue;
            }
            if (self.startsWith("''")) {
                self.i += 2;
                return;
            }
            self.i += codePointLen(self.source, self.i);
        }
        return error.UnterminatedIndentedString;
    }

    fn scanInterpolation(self: *Scanner) StripError!void {
        if (self.interpolation_depth == max_interpolation_nesting) return error.NestingTooDeep;
        self.interpolation_depth += 1;
        defer self.interpolation_depth -= 1;

        self.i += 2;
        try self.scanCode('}');
    }

    fn stripLineComment(self: *Scanner) void {
        const start = self.i;
        self.skipLine();
        blankRange(self.output, start, self.i);
        self.comments_removed += 1;
    }

    fn skipLine(self: *Scanner) void {
        while (self.i < self.source.len and lineTerminatorLen(self.source, self.i) == 0) {
            self.i += codePointLen(self.source, self.i);
        }
    }

    fn isHashbangStart(self: *const Scanner) bool {
        return self.i == 0 or (self.i == 3 and std.mem.startsWith(u8, self.source, "\xEF\xBB\xBF"));
    }

    fn stripBlockComment(self: *Scanner) StripError!void {
        const start = self.i;
        self.i += 2;
        while (self.i < self.source.len) {
            if (self.startsWith("*/")) {
                self.i += 2;
                blankRange(self.output, start, self.i);
                self.comments_removed += 1;
                return;
            }
            self.i += if (lineTerminatorLen(self.source, self.i) != 0)
                lineTerminatorLen(self.source, self.i)
            else
                codePointLen(self.source, self.i);
        }
        return error.UnterminatedBlockComment;
    }

    fn lookupPathEnd(self: *const Scanner) ?usize {
        if (self.source[self.i] != '<' or !self.canStartLookupPath()) return null;
        var cursor = self.i + 1;
        var segment_len: usize = 0;
        while (cursor < self.source.len) : (cursor += 1) {
            const c = self.source[cursor];
            if (c == '>') return if (segment_len != 0) cursor + 1 else null;
            if (c == '/') {
                if (segment_len == 0) return null;
                segment_len = 0;
                continue;
            }
            if (!isPathChar(c)) return null;
            segment_len += 1;
        }
        return null;
    }

    fn canStartLookupPath(self: *const Scanner) bool {
        if (self.i == 0) return true;
        const previous = self.source[self.i - 1];
        return isWhitespaceByte(previous) or switch (previous) {
            '(', '[', '{', '=', ':', ';', ',', '?', '+', '-', '*', '/', '!', '&', '|', '>' => true,
            else => false,
        };
    }

    fn uriEnd(self: *const Scanner) ?usize {
        if (!isAsciiAlpha(self.source[self.i]) or !self.canStartUri()) return null;
        var cursor = self.i + 1;
        while (cursor < self.source.len and isUriSchemeChar(self.source[cursor])) : (cursor += 1) {}
        if (cursor >= self.source.len or self.source[cursor] != ':') return null;
        cursor += 1;
        const body_start = cursor;
        while (cursor < self.source.len and isUriBodyChar(self.source[cursor])) : (cursor += 1) {}
        return if (cursor != body_start) cursor else null;
    }

    fn canStartUri(self: *const Scanner) bool {
        return self.i == 0 or !isIdentifierChar(self.source[self.i - 1]);
    }

    fn startsWith(self: *const Scanner, needle: []const u8) bool {
        return std.mem.startsWith(u8, self.source[self.i..], needle);
    }
};

fn blankRange(output: []u8, start: usize, end: usize) void {
    var cursor = start;
    while (cursor < end) {
        const line_len = lineTerminatorLen(output, cursor);
        if (line_len != 0) {
            cursor += line_len;
            continue;
        }
        if (!isWhitespaceByte(output[cursor])) output[cursor] = ' ';
        cursor += 1;
    }
}

fn lineTerminatorLen(bytes: []const u8, index: usize) usize {
    if (index >= bytes.len) return 0;
    return switch (bytes[index]) {
        '\n' => 1,
        '\r' => if (index + 1 < bytes.len and bytes[index + 1] == '\n') 2 else 1,
        else => 0,
    };
}

fn codePointLen(bytes: []const u8, index: usize) usize {
    if (index >= bytes.len) return 0;
    const c = bytes[index];
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0 and index + 1 < bytes.len) return 2;
    if ((c & 0xF0) == 0xE0 and index + 2 < bytes.len) return 3;
    if ((c & 0xF8) == 0xF0 and index + 3 < bytes.len) return 4;
    return 1;
}

fn isWhitespaceByte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '\x0b' or c == '\x0c';
}

fn isAsciiAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isAsciiDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isPathChar(c: u8) bool {
    return isAsciiAlpha(c) or isAsciiDigit(c) or c == '.' or c == '_' or c == '-' or c == '+';
}

fn isIdentifierChar(c: u8) bool {
    return isAsciiAlpha(c) or isAsciiDigit(c) or c == '_' or c == '\'' or c == '-';
}

fn isUriSchemeChar(c: u8) bool {
    return isAsciiAlpha(c) or isAsciiDigit(c) or c == '+' or c == '-' or c == '.';
}

fn isUriBodyChar(c: u8) bool {
    return isAsciiAlpha(c) or isAsciiDigit(c) or switch (c) {
        '%', '/', '?', ':', '@', '&', '=', '+', '$', ',', '-', '_', '.', '!', '~', '*', '\'' => true,
        else => false,
    };
}

fn expectStableLayout(input: []const u8, output: []const u8) !void {
    try std.testing.expectEqual(input.len, output.len);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\r' or input[i] == '\n') try std.testing.expectEqual(input[i], output[i]);
        i += 1;
    }
}

fn expectStripExact(input: []const u8, expected: []const u8, expected_count: usize) !void {
    var result = try stripAlloc(std.testing.allocator, input);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(expected_count, result.comments_removed);
    try std.testing.expectEqualStrings(expected, result.code);
    try expectStableLayout(input, result.code);

    var second = try stripAlloc(std.testing.allocator, result.code);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), second.comments_removed);
    try std.testing.expectEqualStrings(result.code, second.code);
}

test "Nix line and block comments are replaced with spaces" {
    try expectStripExact(
        "{ # line\r\n  value = 1; /* block\n  text */\n}\n",
        "{       \r\n  value = 1;         \n         \n}\n",
        2,
    );
}

test "Nix Unicode comments are blanked with ASCII spaces" {
    const source = "{ value = 1; } # café 😀 中\n";
    var result = try stripAlloc(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.comments_removed);
    try std.testing.expectEqual(source.len, result.code.len);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "café") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "😀") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "中") == null);
    for (result.code["{ value = 1; } ".len .. result.code.len - 1]) |byte| {
        try std.testing.expectEqual(@as(u8, ' '), byte);
    }
    try expectStableLayout(source, result.code);
}

test "Nix hashbang is preserved while later hash comments are removed" {
    const source = "#!/usr/bin/env nix-instantiate\n{ value = 1; } # remove\n";
    var result = try stripAlloc(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.comments_removed);
    try std.testing.expect(std.mem.startsWith(u8, result.code, "#!/usr/bin/env nix-instantiate\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.code, "remove") == null);
    try expectStableLayout(source, result.code);
}

test "Nix strings preserve comment markers and strip interpolation comments" {
    const source =
        \\{
        \\  url = "https://example.test/a#fragment/*literal*/";
        \\  escaped = "\\${literal} $${alsoLiteral}";
        \\  value = "before ${let x = 1; # interpolation line
        \\    in x /* interpolation block */} after"; # outer line
        \\}
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "https://example.test/a#fragment/*literal*/") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "\\${literal} $${alsoLiteral}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "interpolation line") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "interpolation block") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "outer line") == null);
    try expectStableLayout(source, result.code);
}

test "Nix quoted string escape pairs do not start interpolation" {
    const source =
        \\"literal \${PATH} and $${BASHVAR} # text /* text */" # remove
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "\\${PATH}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "$${BASHVAR}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "# text /* text */") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "remove") == null);
    try expectStableLayout(source, result.code);
}

test "Nix indented strings preserve escaped syntax and strip interpolation comments" {
    const source =
        \\{
        \\  script = ''
        \\    # shell text
        \\    echo "/* shell block text */"
        \\    echo ''${PATH} $${BASHVAR}
        \\    echo ''' and ''\\n
        \\    ${let x = 1; # interpolation line
        \\      in x /* interpolation block */}
        \\  '';
        \\} # outer line
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "# shell text") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "/* shell block text */") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "''${PATH} $${BASHVAR}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "echo ''' and ''\\\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "interpolation line") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "interpolation block") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "outer line") == null);
    try expectStableLayout(source, result.code);
}

test "Nix indented string escape runs cannot close the string early" {
    const source =
        \\''
        \\  ''' # still string text
        \\'' # remove
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "# still string text") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "remove") == null);
    try expectStableLayout(source, result.code);
}

test "Nix identifiers ending in apostrophes do not start indented strings" {
    const source =
        \\let
        \\  foo'' = 1;
        \\in foo'' # remove
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "foo'' = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "in foo''") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "remove") == null);
    try expectStableLayout(source, result.code);
}

test "Nix nested interpolation resumes the containing string" {
    const source =
        \\"outer ${"inner ${let x = 1; # nested line
        \\  in x}"} tail" # final line
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "outer ${\"inner ${") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "nested line") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "} tail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "final line") == null);
    try expectStableLayout(source, result.code);
}

test "Nix interpolation tracks nested attribute-set braces" {
    const source =
        \\"${let attrs = { value = { nested = 1; }; }; # inside interpolation
        \\  in attrs.value.nested}" # after string
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "{ value = { nested = 1; }; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "inside interpolation") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "after string") == null);
    try expectStableLayout(source, result.code);
}

test "Nix path and dynamic attribute interpolation strip comments" {
    const source =
        \\let
        \\  path = ./${let x = "# text"; # path line
        \\    in x}/file;
        \\  attrs = { ${let name = "/* text */"; /* attr block */ in name} = 1; };
        \\in attrs
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "\"# text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "\"/* text */\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "path line") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "attr block") == null);
    try expectStableLayout(source, result.code);
}

test "Nix interpolated paths resume after nested expressions" {
    const source =
        \\./prefix/${let attrs = { name = "part"; }; # path interpolation
        \\  in attrs.name}/suffix # outer comment
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "./prefix/${") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "}/suffix") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "path interpolation") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "outer comment") == null);
    try expectStableLayout(source, result.code);
}

test "Nix URI and lookup paths preserve hash and slash sequences" {
    const source =
        \\{
        \\  uri = https://example.test/a?x=1&y=2;
        \\  lookup = <nixpkgs/path>;
        \\} # remove
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "https://example.test/a?x=1&y=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "<nixpkgs/path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "remove") == null);
    try expectStableLayout(source, result.code);
}

test "Nix URI literals preserve block-comment markers in their path" {
    const source = "http://example.test/a/*literal*/ # remove\n";
    var result = try stripAlloc(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "http://example.test/a/*literal*/") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "remove") == null);
    try expectStableLayout(source, result.code);
}

test "Nix interpolation keeps URI and lookup path tokens intact" {
    const source =
        \\"${let uri = https://example.test/a?x=1&y=2; lookup = <nixpkgs/path>; # remove
        \\  in toString uri + toString lookup}"
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "https://example.test/a?x=1&y=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "<nixpkgs/path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "remove") == null);
    try expectStableLayout(source, result.code);
}

test "Nix comparison syntax is not mistaken for a lookup path" {
    const source =
        \\let
        \\  less = a < b;
        \\  greater = c > d; # remove line
        \\in less && greater
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.comments_removed);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "a < b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "c > d") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "remove line") == null);
    try expectStableLayout(source, result.code);
}

test "Nix block comments stop at the first closing delimiter" {
    try expectStripExact(
        "/* outer /* inner */ value */ 1\n",
        "                     value */ 1\n",
        1,
    );
}

test "repository flake comments are removed without changing layout" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const source = Io.Dir.cwd().readFileAlloc(io, "flake.nix", allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(source);

    var result = try stripAlloc(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expect(result.comments_removed != 0);
    try std.testing.expectEqual(source.len, result.code.len);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "# No x86_64-darwin") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "# build.zig.zon is the single source") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "# Pure Zig with zero external dependencies") == null);
    try expectStableLayout(source, result.code);
}

test "malformed Nix lexical constructs return errors" {
    try std.testing.expectError(error.UnterminatedString, stripAlloc(std.testing.allocator, "\"oops"));
    try std.testing.expectError(error.UnterminatedIndentedString, stripAlloc(std.testing.allocator, "''oops"));
    try std.testing.expectError(error.UnterminatedInterpolation, stripAlloc(std.testing.allocator, "\"${1"));
    try std.testing.expectError(error.UnterminatedBlockComment, stripAlloc(std.testing.allocator, "/* nope"));
}
