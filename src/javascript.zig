const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Parse JSX/TSX lexical regions. Comment-looking text in JSX children and
    /// quoted attributes is preserved; comments inside `{ ... }` expressions
    /// are removed.
    jsx: bool = false,
};

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
    UnterminatedTemplate,
    UnterminatedTemplateExpression,
    UnterminatedBlockComment,
    UnterminatedJsx,
    UnterminatedJsxExpression,
    NestingTooDeep,
};

/// Strip JavaScript or TypeScript comments into a newly allocated buffer.
///
/// Every non-line-terminator byte in a comment is replaced with a space. This
/// keeps byte offsets, columns, line numbers, and ASI-sensitive line breaks
/// stable while ensuring the comment text no longer exists in the output.
pub fn stripAlloc(
    allocator: Allocator,
    source: []const u8,
    options: Options,
) (Allocator.Error || StripError)!Result {
    const output = try allocator.dupe(u8, source);
    errdefer allocator.free(output);

    var scanner: Scanner = .{
        .source = source,
        .output = output,
        .options = options,
    };
    try scanner.scanProgram();

    return .{
        .code = output,
        .comments_removed = scanner.comments_removed,
    };
}

const max_nesting = 1024;

const ParenKind = enum { normal, control };
const BraceKind = enum { block, object };
const EmbeddedKind = enum { template, jsx };

const LexicalContext = struct {
    can_start_regex: bool,
    at_statement_start: bool,
    pending_control_paren: bool,
    pending_block: bool,
    pending_declaration_block: bool,
    paren_len: usize,
    brace_len: usize,
};

const Scanner = struct {
    source: []const u8,
    output: []u8,
    options: Options,

    i: usize = 0,
    comments_removed: usize = 0,

    can_start_regex: bool = true,
    at_statement_start: bool = true,
    pending_control_paren: bool = false,
    pending_block: bool = false,
    pending_declaration_block: bool = false,
    line_has_code: bool = false,

    paren_stack: [max_nesting]ParenKind = undefined,
    paren_len: usize = 0,
    brace_stack: [max_nesting]BraceKind = undefined,
    brace_len: usize = 0,

    fn scanProgram(self: *Scanner) StripError!void {
        // Preserve a UTF-8 BOM and a hashbang. A hashbang is executable
        // metadata rather than a JavaScript comment.
        if (std.mem.startsWith(u8, self.source, "\xEF\xBB\xBF")) self.i = 3;
        if (self.i + 1 < self.source.len and self.source[self.i] == '#' and self.source[self.i + 1] == '!') {
            self.line_has_code = true;
            while (self.i < self.source.len and lineTerminatorLen(self.source, self.i) == 0) self.i += 1;
        }

        while (self.i < self.source.len) {
            switch (self.source[self.i]) {
                '{' => try self.openBrace(),
                '}' => self.closeBrace(),
                else => try self.scanNonBraceToken(),
            }
        }
    }

    fn scanNonBraceToken(self: *Scanner) StripError!void {
        const c = self.source[self.i];
        const line_len = lineTerminatorLen(self.source, self.i);
        if (line_len != 0) {
            self.i += line_len;
            self.line_has_code = false;
            return;
        }
        const whitespace_len = whitespaceLen(self.source, self.i);
        if (whitespace_len != 0) {
            self.i += whitespace_len;
            return;
        }

        if (self.startsWith("//")) {
            self.stripLineComment(2);
            return;
        }
        if (self.startsWith("/*")) {
            try self.stripBlockComment();
            return;
        }

        // Annex-B HTML-like comments used by some classic scripts.
        if (self.startsWith("<!--")) {
            self.stripLineComment(4);
            return;
        }
        if (!self.line_has_code and self.startsWith("-->")) {
            self.stripLineComment(3);
            return;
        }

        if (c == '\'' or c == '"') {
            self.clearImmediatePending();
            try self.scanString(c);
            self.finishValue();
            return;
        }
        if (c == '`') {
            self.clearImmediatePending();
            try self.scanTemplate();
            self.finishValue();
            return;
        }
        if (self.options.jsx and c == '<' and self.can_start_regex and self.looksLikeJsxStart()) {
            self.clearImmediatePending();
            try self.scanJsxElement();
            self.finishValue();
            return;
        }
        if (isIdentifierStart(self.source, self.i)) {
            self.pending_block = false;
            self.scanIdentifier();
            return;
        }
        if (isDecimalDigit(c) or (c == '.' and self.i + 1 < self.source.len and isDecimalDigit(self.source[self.i + 1]))) {
            self.clearImmediatePending();
            self.scanNumber();
            self.finishValue();
            return;
        }

        try self.scanPunctuator();
    }

    fn stripLineComment(self: *Scanner, prefix_len: usize) void {
        const start = self.i;
        self.i += prefix_len;
        while (self.i < self.source.len and lineTerminatorLen(self.source, self.i) == 0) self.i += 1;
        self.blankRange(start, self.i);
        self.comments_removed += 1;
    }

    fn stripBlockComment(self: *Scanner) StripError!void {
        const start = self.i;
        self.i += 2;
        while (self.i < self.source.len) {
            if (self.startsWith("*/")) {
                self.i += 2;
                self.blankRange(start, self.i);
                self.comments_removed += 1;
                return;
            }
            const line_len = lineTerminatorLen(self.source, self.i);
            if (line_len != 0) {
                self.i += line_len;
                self.line_has_code = false;
            } else {
                self.i += codePointLen(self.source, self.i);
            }
        }
        return error.UnterminatedBlockComment;
    }

    fn blankRange(self: *Scanner, start: usize, end: usize) void {
        // Preserve existing whitespace and line terminators. For other text,
        // use whitespace with the same UTF-8 byte length and UTF-16 code-unit
        // length as the original code point. This keeps both byte-oriented
        // source maps and JS/TS compiler offsets stable.
        var cursor = start;
        while (cursor < end) {
            const line_len = lineTerminatorLen(self.output, cursor);
            if (line_len != 0) {
                cursor += line_len;
                continue;
            }
            const whitespace_len = whitespaceLen(self.output, cursor);
            if (whitespace_len != 0) {
                cursor += whitespace_len;
                continue;
            }

            const point_len = codePointLen(self.output, cursor);
            switch (point_len) {
                1 => self.output[cursor] = ' ',
                2 => self.output[cursor..][0..2].* = "\xC2\xA0".*,
                3 => self.output[cursor..][0..3].* = "\xE2\x80\x80".*,
                4 => self.output[cursor..][0..4].* = "\xC2\xA0\xC2\xA0".*,
                else => unreachable,
            }
            cursor += point_len;
        }
    }

    fn scanString(self: *Scanner, quote: u8) StripError!void {
        self.i += 1;
        while (self.i < self.source.len) {
            const c = self.source[self.i];
            if (c == quote) {
                self.i += 1;
                self.line_has_code = true;
                return;
            }
            if (c == '\\') {
                self.i += 1;
                if (self.i >= self.source.len) return error.UnterminatedString;
                const line_len = lineTerminatorLen(self.source, self.i);
                if (line_len != 0) {
                    self.i += line_len;
                    self.line_has_code = false;
                } else {
                    self.i += codePointLen(self.source, self.i);
                }
                continue;
            }
            if (lineTerminatorLen(self.source, self.i) != 0) return error.UnterminatedString;
            self.i += codePointLen(self.source, self.i);
        }
        return error.UnterminatedString;
    }

    fn scanTemplate(self: *Scanner) StripError!void {
        self.i += 1;
        self.line_has_code = true;
        while (self.i < self.source.len) {
            const c = self.source[self.i];
            if (c == '`') {
                self.i += 1;
                self.line_has_code = true;
                return;
            }
            if (c == '\\') {
                self.i += 1;
                if (self.i >= self.source.len) return error.UnterminatedTemplate;
                const line_len = lineTerminatorLen(self.source, self.i);
                if (line_len != 0) {
                    self.i += line_len;
                    self.line_has_code = false;
                } else {
                    self.i += codePointLen(self.source, self.i);
                    self.line_has_code = true;
                }
                continue;
            }
            if (c == '$' and self.i + 1 < self.source.len and self.source[self.i + 1] == '{') {
                self.i += 2;
                self.line_has_code = true;
                try self.scanEmbeddedExpression(.template);
                continue;
            }
            const line_len = lineTerminatorLen(self.source, self.i);
            if (line_len != 0) {
                self.i += line_len;
                self.line_has_code = false;
            } else {
                self.i += codePointLen(self.source, self.i);
                self.line_has_code = true;
            }
        }
        return error.UnterminatedTemplate;
    }

    fn scanEmbeddedExpression(self: *Scanner, kind: EmbeddedKind) StripError!void {
        const saved = self.saveContext();
        defer self.restoreContext(saved);

        self.can_start_regex = true;
        self.at_statement_start = false;
        self.pending_control_paren = false;
        self.pending_block = false;
        self.pending_declaration_block = false;

        var brace_depth: usize = 0;
        while (self.i < self.source.len) {
            switch (self.source[self.i]) {
                '{' => {
                    brace_depth += 1;
                    try self.openBrace();
                },
                '}' => {
                    if (brace_depth == 0) {
                        self.i += 1;
                        self.line_has_code = true;
                        return;
                    }
                    brace_depth -= 1;
                    self.closeBrace();
                },
                else => try self.scanNonBraceToken(),
            }
        }

        return switch (kind) {
            .template => error.UnterminatedTemplateExpression,
            .jsx => error.UnterminatedJsxExpression,
        };
    }

    fn scanIdentifier(self: *Scanner) void {
        const start = self.i;
        self.i = consumeIdentifier(self.source, self.i);
        const word = self.source[start..self.i];

        self.line_has_code = true;
        self.at_statement_start = false;
        self.pending_control_paren = false;

        if (isControlKeyword(word)) {
            self.can_start_regex = true;
            self.pending_control_paren = true;
            return;
        }
        if (isBlockKeyword(word)) {
            self.can_start_regex = true;
            self.pending_block = true;
            self.at_statement_start = true;
            return;
        }
        if (isDeclarationBlockKeyword(word)) {
            self.can_start_regex = true;
            self.pending_declaration_block = true;
            return;
        }
        if (isRegexPrefixKeyword(word)) {
            self.can_start_regex = true;
            return;
        }
        self.can_start_regex = false;
    }

    fn scanNumber(self: *Scanner) void {
        var previous: u8 = 0;
        while (self.i < self.source.len) {
            const c = self.source[self.i];
            if (isAsciiAlphaNumeric(c) or c == '_' or c == '.') {
                previous = c;
                self.i += 1;
                continue;
            }
            if ((c == '+' or c == '-') and (previous == 'e' or previous == 'E')) {
                previous = c;
                self.i += 1;
                continue;
            }
            break;
        }
        self.line_has_code = true;
    }

    fn scanPunctuator(self: *Scanner) StripError!void {
        const c = self.source[self.i];
        const was_can_start_regex = self.can_start_regex;

        if (c != '(') self.pending_control_paren = false;
        if (c != '{') self.pending_block = false;

        switch (c) {
            '(' => {
                const kind: ParenKind = if (self.pending_control_paren) .control else .normal;
                try self.pushParen(kind);
                self.pending_control_paren = false;
                self.pending_block = false;
                self.i += 1;
                self.can_start_regex = true;
                self.at_statement_start = false;
            },
            ')' => {
                const kind = self.popParen();
                self.i += 1;
                self.can_start_regex = kind == .control;
                self.at_statement_start = kind == .control;
                self.pending_block = true;
            },
            '[' => {
                self.i += 1;
                self.can_start_regex = true;
                self.at_statement_start = false;
            },
            ']' => {
                self.i += 1;
                self.finishValue();
            },
            ';' => {
                self.i += 1;
                self.can_start_regex = true;
                self.at_statement_start = true;
            },
            ',' => {
                self.i += 1;
                self.can_start_regex = true;
                self.at_statement_start = false;
            },
            ':' => {
                self.i += 1;
                self.can_start_regex = true;
                self.at_statement_start = false;
            },
            '.' => {
                if (self.startsWith("...")) {
                    self.i += 3;
                    self.can_start_regex = true;
                } else {
                    self.i += 1;
                    self.can_start_regex = false;
                }
                self.at_statement_start = false;
            },
            '?' => {
                if (self.startsWith("?.") and !(self.i + 2 < self.source.len and isDecimalDigit(self.source[self.i + 2]))) {
                    self.i += 2;
                    self.can_start_regex = false;
                } else if (self.startsWith("??=")) {
                    self.i += 3;
                    self.can_start_regex = true;
                } else if (self.startsWith("??")) {
                    self.i += 2;
                    self.can_start_regex = true;
                } else {
                    self.i += 1;
                    self.can_start_regex = true;
                }
                self.at_statement_start = false;
            },
            '+', '-' => {
                if (self.i + 1 < self.source.len and self.source[self.i + 1] == c) {
                    self.i += 2;
                    self.can_start_regex = false;
                } else {
                    self.i += if (self.i + 1 < self.source.len and self.source[self.i + 1] == '=') 2 else 1;
                    self.can_start_regex = true;
                }
                self.at_statement_start = false;
            },
            '!' => {
                if (self.startsWith("!==")) {
                    self.i += 3;
                    self.can_start_regex = true;
                } else if (self.startsWith("!=")) {
                    self.i += 2;
                    self.can_start_regex = true;
                } else {
                    self.i += 1;
                    // In TS, `value!` is a postfix non-null assertion.
                    self.can_start_regex = was_can_start_regex;
                }
                self.at_statement_start = false;
            },
            '=' => {
                if (self.startsWith("=>")) {
                    self.i += 2;
                    self.pending_block = true;
                } else if (self.startsWith("===")) {
                    self.i += 3;
                } else if (self.startsWith("==")) {
                    self.i += 2;
                } else {
                    self.i += 1;
                }
                self.can_start_regex = true;
                self.at_statement_start = false;
            },
            '/' => {
                if (self.can_start_regex) {
                    if (self.regexEnd(self.i)) |end| {
                        self.i = end;
                        self.finishValue();
                        return;
                    }
                }
                self.i += if (self.i + 1 < self.source.len and self.source[self.i + 1] == '=') 2 else 1;
                self.can_start_regex = true;
                self.at_statement_start = false;
            },
            '*', '%', '&', '|', '^', '~', '<', '>' => {
                self.i += punctuatorLength(self.source, self.i);
                self.can_start_regex = true;
                self.at_statement_start = false;
            },
            '@' => {
                self.i += 1;
                self.can_start_regex = true;
                self.at_statement_start = false;
            },
            '#' => {
                self.i += 1;
                self.can_start_regex = false;
                self.at_statement_start = false;
            },
            else => {
                self.i += codePointLen(self.source, self.i);
                self.can_start_regex = true;
                self.at_statement_start = false;
            },
        }
        self.line_has_code = true;
    }

    fn regexEnd(self: *const Scanner, start: usize) ?usize {
        var cursor = start + 1;
        var in_class = false;
        while (cursor < self.source.len) {
            const c = self.source[cursor];
            if (lineTerminatorLen(self.source, cursor) != 0) return null;
            if (c == '\\') {
                cursor += 1;
                if (cursor >= self.source.len or lineTerminatorLen(self.source, cursor) != 0) return null;
                cursor += codePointLen(self.source, cursor);
                continue;
            }
            if (c == '[') {
                in_class = true;
                cursor += 1;
                continue;
            }
            if (c == ']' and in_class) {
                in_class = false;
                cursor += 1;
                continue;
            }
            if (c == '/' and !in_class) {
                cursor += 1;
                while (cursor < self.source.len and isIdentifierPart(self.source, cursor)) {
                    cursor = consumeIdentifierPart(self.source, cursor);
                }
                return cursor;
            }
            cursor += codePointLen(self.source, cursor);
        }
        return null;
    }

    fn openBrace(self: *Scanner) StripError!void {
        const kind: BraceKind = if (self.pending_block or self.pending_declaration_block or self.at_statement_start)
            .block
        else
            .object;
        try self.pushBrace(kind);

        self.i += 1;
        self.pending_control_paren = false;
        self.pending_block = false;
        self.pending_declaration_block = false;
        self.can_start_regex = true;
        self.at_statement_start = kind == .block;
        self.line_has_code = true;
    }

    fn closeBrace(self: *Scanner) void {
        const kind = self.popBrace();
        self.i += 1;
        self.pending_control_paren = false;
        self.pending_block = false;
        self.can_start_regex = kind == .block;
        self.at_statement_start = kind == .block;
        self.line_has_code = true;
    }

    fn scanJsxElement(self: *Scanner) StripError!void {
        self.i += 1; // `<`
        if (self.i >= self.source.len) return error.UnterminatedJsx;

        var opened = false;
        while (self.i < self.source.len) {
            if (self.startsWith("/>")) {
                self.i += 2;
                self.line_has_code = true;
                return;
            }
            const c = self.source[self.i];
            if (c == '>') {
                self.i += 1;
                self.line_has_code = true;
                opened = true;
                break;
            }
            if (c == '\'' or c == '"') {
                try self.scanJsxAttributeString(c);
                continue;
            }
            if (c == '{') {
                self.i += 1;
                self.line_has_code = true;
                try self.scanEmbeddedExpression(.jsx);
                continue;
            }
            if (self.startsWith("//")) {
                self.stripLineComment(2);
                continue;
            }
            if (self.startsWith("/*")) {
                try self.stripBlockComment();
                continue;
            }
            const line_len = lineTerminatorLen(self.source, self.i);
            if (line_len != 0) {
                self.i += line_len;
                self.line_has_code = false;
            } else {
                self.i += codePointLen(self.source, self.i);
                self.line_has_code = true;
            }
        }
        if (!opened) return error.UnterminatedJsx;

        // Child text: comment-looking sequences are data, not code.
        while (self.i < self.source.len) {
            const c = self.source[self.i];
            if (c == '{') {
                self.i += 1;
                self.line_has_code = true;
                try self.scanEmbeddedExpression(.jsx);
                continue;
            }
            if (c == '<') {
                if (self.startsWith("</")) {
                    try self.scanJsxClosingTag();
                    return;
                }
                try self.scanJsxElement();
                continue;
            }
            const line_len = lineTerminatorLen(self.source, self.i);
            if (line_len != 0) {
                self.i += line_len;
                self.line_has_code = false;
            } else {
                self.i += codePointLen(self.source, self.i);
                self.line_has_code = true;
            }
        }
        return error.UnterminatedJsx;
    }

    fn scanJsxClosingTag(self: *Scanner) StripError!void {
        self.i += 2; // `</`
        while (self.i < self.source.len) {
            const c = self.source[self.i];
            if (c == '>') {
                self.i += 1;
                self.line_has_code = true;
                return;
            }
            const line_len = lineTerminatorLen(self.source, self.i);
            if (line_len != 0) {
                self.i += line_len;
                self.line_has_code = false;
            } else {
                self.i += codePointLen(self.source, self.i);
                self.line_has_code = true;
            }
        }
        return error.UnterminatedJsx;
    }

    fn scanJsxAttributeString(self: *Scanner, quote: u8) StripError!void {
        self.i += 1;
        while (self.i < self.source.len) {
            const c = self.source[self.i];
            if (c == quote) {
                self.i += 1;
                self.line_has_code = true;
                return;
            }
            const line_len = lineTerminatorLen(self.source, self.i);
            if (line_len != 0) {
                self.i += line_len;
                self.line_has_code = false;
            } else {
                self.i += codePointLen(self.source, self.i);
                self.line_has_code = true;
            }
        }
        return error.UnterminatedJsx;
    }

    fn looksLikeJsxStart(self: *const Scanner) bool {
        if (self.i + 1 >= self.source.len) return false;
        const next = self.source[self.i + 1];
        if (next == '>') return true; // fragment
        if (!(isAsciiIdentifierStart(next) or next >= 0x80)) return false;

        // Avoid the unambiguous generic-arrow forms used in TSX:
        // `<T,>(x) => x` and `<T extends U>(x) => x`.
        var cursor = self.i + 1;
        var saw_type_marker = false;
        var quote: u8 = 0;
        while (cursor < self.source.len and cursor - self.i <= 512) : (cursor += 1) {
            const c = self.source[cursor];
            if (quote != 0) {
                if (c == quote) quote = 0;
                continue;
            }
            if (c == '\'' or c == '"') {
                quote = c;
                continue;
            }
            if (c == ',') saw_type_marker = true;
            if (std.mem.startsWith(u8, self.source[cursor..], "extends") and
                (cursor == self.i + 1 or !isAsciiIdentifierPart(self.source[cursor - 1])) and
                (cursor + 7 >= self.source.len or !isAsciiIdentifierPart(self.source[cursor + 7])))
            {
                saw_type_marker = true;
            }
            if (c == '>') {
                if (!saw_type_marker) return true;
                cursor += 1;
                while (cursor < self.source.len) {
                    const ws_len = whitespaceLen(self.source, cursor);
                    if (ws_len == 0) break;
                    cursor += ws_len;
                }
                return !(cursor < self.source.len and self.source[cursor] == '(');
            }
            if (lineTerminatorLen(self.source, cursor) != 0) return true;
        }
        return true;
    }

    fn saveContext(self: *const Scanner) LexicalContext {
        return .{
            .can_start_regex = self.can_start_regex,
            .at_statement_start = self.at_statement_start,
            .pending_control_paren = self.pending_control_paren,
            .pending_block = self.pending_block,
            .pending_declaration_block = self.pending_declaration_block,
            .paren_len = self.paren_len,
            .brace_len = self.brace_len,
        };
    }

    fn restoreContext(self: *Scanner, context: LexicalContext) void {
        self.can_start_regex = context.can_start_regex;
        self.at_statement_start = context.at_statement_start;
        self.pending_control_paren = context.pending_control_paren;
        self.pending_block = context.pending_block;
        self.pending_declaration_block = context.pending_declaration_block;
        self.paren_len = context.paren_len;
        self.brace_len = context.brace_len;
    }

    fn clearImmediatePending(self: *Scanner) void {
        self.pending_control_paren = false;
        self.pending_block = false;
    }

    fn finishValue(self: *Scanner) void {
        self.can_start_regex = false;
        self.at_statement_start = false;
        self.pending_control_paren = false;
        self.pending_block = false;
        self.line_has_code = true;
    }

    fn pushParen(self: *Scanner, kind: ParenKind) StripError!void {
        if (self.paren_len == self.paren_stack.len) return error.NestingTooDeep;
        self.paren_stack[self.paren_len] = kind;
        self.paren_len += 1;
    }

    fn popParen(self: *Scanner) ParenKind {
        if (self.paren_len == 0) return .normal;
        self.paren_len -= 1;
        return self.paren_stack[self.paren_len];
    }

    fn pushBrace(self: *Scanner, kind: BraceKind) StripError!void {
        if (self.brace_len == self.brace_stack.len) return error.NestingTooDeep;
        self.brace_stack[self.brace_len] = kind;
        self.brace_len += 1;
    }

    fn popBrace(self: *Scanner) BraceKind {
        if (self.brace_len == 0) return .block;
        self.brace_len -= 1;
        return self.brace_stack[self.brace_len];
    }

    fn startsWith(self: *const Scanner, needle: []const u8) bool {
        return std.mem.startsWith(u8, self.source[self.i..], needle);
    }
};

fn lineTerminatorLen(source: []const u8, index: usize) usize {
    if (index >= source.len) return 0;
    return switch (source[index]) {
        '\n', '\r' => 1,
        0xE2 => if (index + 2 < source.len and source[index + 1] == 0x80 and
            (source[index + 2] == 0xA8 or source[index + 2] == 0xA9)) 3 else 0,
        else => 0,
    };
}

fn codePointLen(source: []const u8, index: usize) usize {
    if (index >= source.len) return 0;
    const first = source[index];
    const wanted: usize = if (first < 0x80)
        1
    else if (first < 0xE0)
        2
    else if (first < 0xF0)
        3
    else
        4;
    return @min(wanted, source.len - index);
}

fn whitespaceLen(source: []const u8, index: usize) usize {
    if (index >= source.len) return 0;
    return switch (source[index]) {
        ' ', '\t', '\x0B', '\x0C' => 1,
        0xC2 => if (index + 1 < source.len and source[index + 1] == 0xA0) 2 else 0, // U+00A0
        0xE1 => if (index + 2 < source.len and source[index + 1] == 0x9A and source[index + 2] == 0x80) 3 else 0, // U+1680
        0xE2 => if (index + 2 < source.len and ((source[index + 1] == 0x80 and source[index + 2] >= 0x80 and source[index + 2] <= 0x8A) or // U+2000..U+200A
            (source[index + 1] == 0x80 and source[index + 2] == 0xAF) or // U+202F
            (source[index + 1] == 0x81 and source[index + 2] == 0x9F))) 3 else 0, // U+205F
        0xE3 => if (index + 2 < source.len and source[index + 1] == 0x80 and source[index + 2] == 0x80) 3 else 0, // U+3000
        0xEF => if (index + 2 < source.len and source[index + 1] == 0xBB and source[index + 2] == 0xBF) 3 else 0, // U+FEFF
        else => 0,
    };
}

fn isDecimalDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAsciiAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isAsciiAlphaNumeric(c: u8) bool {
    return isAsciiAlpha(c) or isDecimalDigit(c);
}

fn isAsciiIdentifierStart(c: u8) bool {
    return isAsciiAlpha(c) or c == '_' or c == '$';
}

fn isAsciiIdentifierPart(c: u8) bool {
    return isAsciiIdentifierStart(c) or isDecimalDigit(c);
}

fn isIdentifierStart(source: []const u8, index: usize) bool {
    if (index >= source.len) return false;
    const c = source[index];
    return isAsciiIdentifierStart(c) or c >= 0x80 or
        (c == '\\' and index + 1 < source.len and source[index + 1] == 'u');
}

fn isIdentifierPart(source: []const u8, index: usize) bool {
    if (index >= source.len) return false;
    const c = source[index];
    return isAsciiIdentifierPart(c) or c >= 0x80 or
        (c == '\\' and index + 1 < source.len and source[index + 1] == 'u');
}

fn consumeIdentifier(source: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < source.len and isIdentifierPart(source, cursor)) {
        cursor = consumeIdentifierPart(source, cursor);
    }
    return cursor;
}

fn consumeIdentifierPart(source: []const u8, index: usize) usize {
    const c = source[index];
    if (c >= 0x80) return @min(source.len, index + codePointLen(source, index));
    if (c != '\\') return index + 1;

    var cursor = index + 2; // `\u`
    if (cursor < source.len and source[cursor] == '{') {
        cursor += 1;
        while (cursor < source.len and source[cursor] != '}') cursor += 1;
        if (cursor < source.len) cursor += 1;
        return cursor;
    }
    return @min(source.len, cursor + 4);
}

fn isControlKeyword(word: []const u8) bool {
    return eqlAny(word, &.{ "if", "while", "for", "with", "switch", "catch" });
}

fn isBlockKeyword(word: []const u8) bool {
    return eqlAny(word, &.{ "else", "do", "try", "finally" });
}

fn isDeclarationBlockKeyword(word: []const u8) bool {
    return eqlAny(word, &.{ "class", "interface", "enum", "namespace", "module" });
}

fn isRegexPrefixKeyword(word: []const u8) bool {
    return eqlAny(word, &.{
        "return",    "throw",      "case",  "delete", "void",    "typeof", "new",
        "in",        "instanceof", "yield", "await",  "extends", "of",     "as",
        "satisfies", "default",
    });
}

fn eqlAny(word: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, word, candidate)) return true;
    }
    return false;
}

fn punctuatorLength(source: []const u8, index: usize) usize {
    const remaining = source[index..];
    const candidates = [_][]const u8{
        ">>>=", "**=", "&&=", "||=", "??=", "<<=", ">>=", ">>>",
        "**",   "&&",  "||",  "<<",  ">>",  "<=",  ">=",  "+=",
        "-=",   "*=",  "%=",  "&=",  "|=",  "^=",
    };
    for (candidates) |candidate| {
        if (std.mem.startsWith(u8, remaining, candidate)) return candidate.len;
    }
    return 1;
}

fn containsBytes(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn utf16CodeUnits(bytes: []const u8) usize {
    var units: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const point_len = codePointLen(bytes, i);
        units += if (point_len == 4) 2 else 1;
        i += point_len;
    }
    return units;
}

fn expectStableLayout(input: []const u8, output: []const u8) !void {
    try std.testing.expectEqual(input.len, output.len);
    try std.testing.expectEqual(utf16CodeUnits(input), utf16CodeUnits(output));
    var i: usize = 0;
    while (i < input.len) {
        const line_len = lineTerminatorLen(input, i);
        if (line_len != 0) {
            try std.testing.expectEqualSlices(u8, input[i .. i + line_len], output[i .. i + line_len]);
            i += line_len;
        } else {
            i += 1;
        }
    }
}

fn expectStripExact(
    input: []const u8,
    expected: []const u8,
    expected_count: usize,
    options: Options,
) !void {
    var result = try stripAlloc(std.testing.allocator, input, options);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(expected_count, result.comments_removed);
    try std.testing.expectEqualStrings(expected, result.code);
    try expectStableLayout(input, result.code);

    var second = try stripAlloc(std.testing.allocator, result.code, options);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), second.comments_removed);
    try std.testing.expectEqualStrings(result.code, second.code);
}

fn expectPreserved(result: Result, needle: []const u8) !void {
    try std.testing.expect(containsBytes(result.code, needle));
}

fn expectRemoved(result: Result, needle: []const u8) !void {
    try std.testing.expect(!containsBytes(result.code, needle));
}

test "line and block comments are replaced with spaces" {
    try expectStripExact(
        "const x = 1; // hello\nconst y = /* why */ 2;\n",
        "const x = 1;         \nconst y =           2;\n",
        2,
        .{},
    );
}

test "comment markers in strings and URLs are preserved" {
    const source =
        \\const line = "// not a comment";
        \\const block = '/* also not */'; // remove this
        \\const url = "https://example.test/a/*b*/";
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.comments_removed);
    try expectPreserved(result, "\"// not a comment\"");
    try expectPreserved(result, "'/* also not */'");
    try expectPreserved(result, "https://example.test/a/*b*/");
    try expectRemoved(result, "remove this");
    try expectStableLayout(source, result.code);
}

test "regex literals are preserved, including slash-like patterns" {
    const source =
        \\const re = /https?:\/\/[^/]+\/\*x\*\//giu; // tail
        \\if (ok) /\/\//.test(text); /* block */
        \\function pick() { return /[/\\]/u; } // end
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.comments_removed);
    try expectPreserved(result, "/https?:\\/\\/[^/]+\\/\\*x\\*\\//giu");
    try expectPreserved(result, "/\\/\\//.test(text)");
    try expectPreserved(result, "/[/\\\\]/u");
    try expectRemoved(result, "tail");
    try expectRemoved(result, "block");
    try expectStableLayout(source, result.code);
}

test "division and TypeScript postfix non-null assertions are not regexes" {
    const source =
        \\const ratio = total / count; // mean
        \\const half = ({ value: 4 }).value / 2; /* half */
        \\const asserted = value! / 2; // postfix
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.comments_removed);
    try expectPreserved(result, "total / count");
    try expectPreserved(result, ").value / 2");
    try expectPreserved(result, "value! / 2");
    try expectRemoved(result, "mean");
    try expectRemoved(result, "half */");
    try expectRemoved(result, "postfix");
    try expectStableLayout(source, result.code);
}

test "template raw text is preserved while interpolation comments are removed" {
    const source =
        \\const value = `// raw ${1 /* expression */ + `${2 // nested
        \\}` } /* still raw */`; // tail
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.comments_removed);
    try expectPreserved(result, "`// raw ${");
    try expectPreserved(result, "/* still raw */`");
    try expectRemoved(result, "expression");
    try expectRemoved(result, "nested");
    try expectRemoved(result, "tail");
    try expectStableLayout(source, result.code);
}

test "hashbang and BOM are preserved" {
    const source = "\xEF\xBB\xBF#!/usr/bin/env node\n// banner\nconsole.log('ok');\n";
    var result = try stripAlloc(std.testing.allocator, source, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.comments_removed);
    try std.testing.expect(std.mem.startsWith(u8, result.code, "\xEF\xBB\xBF#!/usr/bin/env node\n"));
    try expectRemoved(result, "banner");
    try expectStableLayout(source, result.code);
}

test "Unicode comment text preserves UTF-8 and UTF-16 offsets" {
    const source =
        \\function pick() { return /* café 😀 中 */ /x/u; }
        \\const value = 1; // τέλος
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.comments_removed);
    try expectStableLayout(source, result.code);
    try expectPreserved(result, "return");
    try expectPreserved(result, "/x/u");
    try expectRemoved(result, "café");
    try expectRemoved(result, "😀");
    try expectRemoved(result, "中");
    try expectRemoved(result, "τέλος");

    var second = try stripAlloc(std.testing.allocator, result.code, .{});
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), second.comments_removed);
    try std.testing.expectEqualStrings(result.code, second.code);
}

test "CRLF and Unicode JavaScript line separators remain byte-identical" {
    const source = "let a = 1; /* x\r\ny */ let b = 2; // z\xE2\x80\xA8let c = 3;\xE2\x80\xA9";
    var result = try stripAlloc(std.testing.allocator, source, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.comments_removed);
    try expectStableLayout(source, result.code);
    try expectPreserved(result, "\r\n");
    try expectPreserved(result, "\xE2\x80\xA8");
    try expectPreserved(result, "\xE2\x80\xA9");
    try expectRemoved(result, " x");
    try expectRemoved(result, "// z");
}

test "JSX child text and attributes are data, JSX expressions are code" {
    const source =
        \\const view = <>
        \\  <div title="// attribute text">
        \\    /* child text */
        \\    {/* expression comment */ value}
        \\    <span>{name // expression line comment
        \\    }</span>
        \\  </div>
        \\</>; // tail
        \\const id = <T,>(x: T) => x; // generic arrow
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source, .{ .jsx = true });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), result.comments_removed);
    try expectPreserved(result, "title=\"// attribute text\"");
    try expectPreserved(result, "/* child text */");
    try expectPreserved(result, "const id = <T,>(x: T) => x;");
    try expectRemoved(result, "expression comment");
    try expectRemoved(result, "expression line comment");
    try expectRemoved(result, "generic arrow");
    try expectStableLayout(source, result.code);
}

test "Annex B HTML-like line comments are removed" {
    try expectStripExact(
        "<!-- legacy open\nlet x = 1;\n   --> legacy close\n",
        "                \nlet x = 1;\n                   \n",
        2,
        .{},
    );
}

test "comments between tokens cannot merge identifiers" {
    try expectStripExact(
        "const value = left/* separator */right;\n",
        "const value = left               right;\n",
        1,
        .{},
    );
}

test "triple-slash directives and source map comments are removed" {
    const source =
        \\/// <reference types="node" />
        \\const value: number = 1;
        \\//# sourceMappingURL=app.js.map
        \\
    ;
    var result = try stripAlloc(std.testing.allocator, source, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.comments_removed);
    try expectRemoved(result, "reference types");
    try expectRemoved(result, "sourceMappingURL");
    try expectPreserved(result, "const value: number = 1;");
    try expectStableLayout(source, result.code);
}

test "malformed lexical constructs return errors without partial output" {
    try std.testing.expectError(
        error.UnterminatedBlockComment,
        stripAlloc(std.testing.allocator, "const x = 1; /*", .{}),
    );
    try std.testing.expectError(
        error.UnterminatedString,
        stripAlloc(std.testing.allocator, "const x = 'oops", .{}),
    );
    try std.testing.expectError(
        error.UnterminatedTemplate,
        stripAlloc(std.testing.allocator, "const x = `oops", .{}),
    );
    try std.testing.expectError(
        error.UnterminatedJsx,
        stripAlloc(std.testing.allocator, "const x = <div>", .{ .jsx = true }),
    );
}
