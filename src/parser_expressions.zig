const std = @import("std");
const testing = std.testing;

pub const ExpressionMatch = struct {
    result: []const u8 = undefined,
};

/// Will scan the buf for pattern. Pattern can contain () to indicate narrow group to extract.
/// Currently no support for character classes and other patterns.
pub fn expressionExtractor(buf: []const u8, pattern: []const u8) ?ExpressionMatch {
    _ = buf;
    _ = pattern;
    if (std.mem.indexOf(u8, pattern, "()")) |pos| {
        var start_slice = pattern[0..pos];
        var end_slice = pattern[pos + 2 ..];

        var start_pos = std.mem.indexOf(u8, buf, start_slice) orelse return null;
        var end_pos = std.mem.indexOfPos(u8, buf, start_pos + start_slice.len, end_slice) orelse return null;

        // If no end-match, assume end of line...
        // This might come back to bite me, but it's as good as anything right now without particular usecases
        // This allows us to e.g. get particular headers-values. The more future-proof solution is to implement
        // bettter pattern-matching-engine.
        if (end_pos == 0) {
            if(std.mem.indexOfAny(u8, buf[start_pos + start_slice.len..], "\r\n")) |line_end| {
                end_pos = start_pos + start_slice.len + line_end;
            } else {
                end_pos = buf.len;
            }
        }

        return ExpressionMatch{
            .result = buf[start_pos + start_slice.len .. end_pos],
        };
    } else if (std.mem.indexOf(u8, buf, pattern)) |_| {
        return ExpressionMatch{
            .result = buf[0..],
        };
    }

    return null;
}

test "expressionExtractor" {
    try testing.expect(expressionExtractor("", "not there") == null);
    // Hvis match uten (): lagre hele payload?
    try testing.expectEqualStrings("match", expressionExtractor("match", "()").?.result);
    try testing.expectEqualStrings("match", expressionExtractor("match", "atc").?.result);
    try testing.expectEqualStrings("atc", expressionExtractor("match", "m()h").?.result);
    try testing.expectEqualStrings("123123", expressionExtractor("idtoken=123123", "token=()").?.result);
    try testing.expectEqualStrings("123123", expressionExtractor("123123=idtoken", "()=id").?.result);
}