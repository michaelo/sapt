const std = @import("std");
const debug = std.debug.print;
const expect = std.testing.expect;

const errors = error {
    Ok,
    ParseError,
    TestsFailed
};

const HttpMethod = enum {
    Get,
    Post,
    Put,
    Delete
};

pub fn main() anyerror!void {
    std.log.info("All your codebase are belong to us.", .{});
}

const Entry = struct {
    name: [1024]u8,
    method: HttpMethod,
    url: [2056]u8,
    headers: [32][256]u8,
    payload: [1024*1024]u8
};

// fn run_entry(entry: *Entry) !void {
//     // 
// }

fn parse_contents(data: []const u8, result: *Entry) errors!void {
    debug("Parse contents\n", .{});
    _ = data;
    result.name[0] = 'H';
    // Name is set based on file name
    // Headers is parsed from first section
}

test "parse_entry" {
    var entry: Entry = undefined;
    const data =
        \\> GET https:\\my.api/action
        \\
        \\Content-Type: application/json
        \\Accept: application/json
        \\
        \\< 200
        \\
        ;
    debug("{s}\n", .{data});
    try parse_contents(data, &entry);

    try expect(std.mem.eql(u8, entry.url[0..], "https:\\my.api/action"));
    try expect(entry.method == HttpMethod.Get);
}