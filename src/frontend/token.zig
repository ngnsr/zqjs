//! Tokens. The lexer recognises the *whole* JavaScript punctuator set, not just the
//! operators ZQJS implements. Longest-match tokenisation (`**=` is one token, not
//! `**` + `=`) is what lets the parser tell "invalid JavaScript" apart from
//! "valid JavaScript we don't support" (LANGUAGE.md §1).

const std = @import("std");

pub const Tag = enum {
    eof,
    number,
    bigint,
    string,
    template_no_sub,
    template_head,
    template_middle,
    template_tail,
    identifier,
    private_ident,
    kw_true,
    kw_false,
    kw_null,
    kw_const,
    kw_if,
    kw_else,
    kw_while,
    kw_for,
    kw_break,
    kw_continue,
    // `let` is not a keyword: in sloppy scripts it is an ordinary identifier
    // (`let = 1;` is valid JS), so the parser treats it contextually.
    /// Characters with no meaning to ZQJS: `#`, `@`, `` ` ``, `\`, `<!--`, ASCII control chars.
    unknown,

    // Punctuators ZQJS implements.
    l_paren,
    r_paren,
    semicolon,
    plus,
    minus,
    star,
    slash,
    percent,
    star_star,
    bang,
    lt,
    le,
    gt,
    ge,
    eq3,
    neq3,
    amp_amp,
    pipe_pipe,

    // Punctuators ZQJS recognises but does not implement yet.
    eq2,
    neq2,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    dot,
    ellipsis,
    comma,
    question,
    question_dot,
    question2,
    colon,
    eq,
    arrow,
    tilde,
    plus2,
    minus2,
    shl,
    shr,
    ushr,
    amp,
    pipe,
    caret,
    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    percent_eq,
    star_star_eq,
    shl_eq,
    shr_eq,
    ushr_eq,
    amp_eq,
    pipe_eq,
    caret_eq,
    amp_amp_eq,
    pipe_pipe_eq,
    question2_eq,
};

pub fn isKeyword(tag: Tag) bool {
    return switch (tag) {
        .kw_true, .kw_false, .kw_null, .kw_const, .kw_if, .kw_else, .kw_while, .kw_for, .kw_break, .kw_continue => true,
        else => false,
    };
}

/// Reserved words of sloppy-mode scripts that lex as plain identifiers in ZQJS
/// (the ones with their own Tag are covered by `isKeyword`). None of them may name
/// a variable; most of them start constructs ZQJS doesn't have yet.
pub const reserved_identifiers = std.StaticStringMap(void).initComptime(.{
    .{"case"},   .{"catch"}, .{"class"},      .{"debugger"}, .{"default"}, .{"delete"},
    .{"do"},     .{"enum"},  .{"export"},     .{"extends"},  .{"finally"}, .{"function"},
    .{"import"}, .{"in"},    .{"instanceof"}, .{"new"},      .{"return"},  .{"super"},
    .{"switch"}, .{"this"},  .{"throw"},      .{"try"},      .{"typeof"},  .{"var"},
    .{"void"},   .{"with"},
});

pub const Token = struct {
    tag: Tag,
    /// Byte offsets into the source, `start..end`. u32 because sources are limited
    /// to far less than 4 GiB (Limits.max_source_bytes) and it halves the token size.
    start: u32,
    end: u32,
    /// A line terminator (or a multi-line comment containing one) precedes this token.
    /// Needed only to tell an ASI situation (Unsupported) from a SyntaxError.
    newline_before: bool,

    pub fn text(t: Token, source: []const u8) []const u8 {
        return source[t.start..t.end];
    }
};

/// Sorted longest-first so the first match is the longest match.
pub const punctuators = [_]struct { []const u8, Tag }{
    .{ ">>>=", .ushr_eq },
    .{ "<!--", .unknown }, // HTML-like comment opener in sloppy scripts; never ours.
    .{ "...", .ellipsis },
    .{ "===", .eq3 },
    .{ "!==", .neq3 },
    .{ "**=", .star_star_eq },
    .{ "<<=", .shl_eq },
    .{ ">>=", .shr_eq },
    .{ ">>>", .ushr },
    .{ "&&=", .amp_amp_eq },
    .{ "||=", .pipe_pipe_eq },
    .{ "??=", .question2_eq },
    .{ "=>", .arrow },
    .{ "==", .eq2 },
    .{ "!=", .neq2 },
    .{ "<=", .le },
    .{ ">=", .ge },
    .{ "&&", .amp_amp },
    .{ "||", .pipe_pipe },
    .{ "??", .question2 },
    .{ "?.", .question_dot },
    .{ "**", .star_star },
    .{ "++", .plus2 },
    .{ "--", .minus2 },
    .{ "<<", .shl },
    .{ ">>", .shr },
    .{ "+=", .plus_eq },
    .{ "-=", .minus_eq },
    .{ "*=", .star_eq },
    .{ "/=", .slash_eq },
    .{ "%=", .percent_eq },
    .{ "&=", .amp_eq },
    .{ "|=", .pipe_eq },
    .{ "^=", .caret_eq },
    .{ "(", .l_paren },
    .{ ")", .r_paren },
    .{ "{", .l_brace },
    .{ "}", .r_brace },
    .{ "[", .l_bracket },
    .{ "]", .r_bracket },
    .{ ";", .semicolon },
    .{ ",", .comma },
    .{ "<", .lt },
    .{ ">", .gt },
    .{ "+", .plus },
    .{ "-", .minus },
    .{ "*", .star },
    .{ "/", .slash },
    .{ "%", .percent },
    .{ "&", .amp },
    .{ "|", .pipe },
    .{ "^", .caret },
    .{ "!", .bang },
    .{ "~", .tilde },
    .{ "?", .question },
    .{ ":", .colon },
    .{ "=", .eq },
    .{ ".", .dot },
};

test "punctuator table is longest-first" {
    var prev: usize = std.math.maxInt(usize);
    for (punctuators) |p| {
        try std.testing.expect(p[0].len <= prev);
        prev = p[0].len;
    }
}
