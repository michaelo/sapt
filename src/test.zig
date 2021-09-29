// The place for explorative stuff

const std = @import("std");
const testing = std.testing;
const debug = std.debug.print;

const re = @cImport({
    @cInclude("tiny-regex-c/re.h");
});

const re2 = @cImport({
    @cInclude("sys/types.h");
    @cInclude("ht-regex/regex.h");
});

pub fn main() anyerror!void {
    {
        debug("typeof: {s}\n", .{@TypeOf(re2.re_pattern_buffer)});
        // var exp: re2.regex_t = re2.regex_t{};
        // _ = exp;
    }
    {    // Standard int to hold length of match
        var match_length: c_int = 0;

        // Standard null-terminated C-string to search:
        var string_to_search: [:0]const u8 = "id=myidhere";

        // Compile a simple regular expression using character classes, meta-char and greedy + non-greedy quantifiers:
        var pattern: re.re_t = re.re_compile("id=\\w+");

        // Check if the regex matches the text:
        var match_idx: c_int = re.re_matchp(pattern, string_to_search, &match_length);
        if (match_idx != -1)
        {
            debug("match at idx {d}, {d} chars long.\n", .{match_idx, match_length});
        }
    }
}
