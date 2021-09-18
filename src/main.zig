const std = @import("std");
const debug = std.debug.print;
const testing = std.testing;

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

const HttpHeader = struct {
    name: std.BoundedArray(u8,256),
    value: std.BoundedArray(u8,1024),
    pub fn create(name: []const u8, value: []const u8) !HttpHeader {
        return HttpHeader {
            .name = std.BoundedArray(u8,256).fromSlice(std.mem.trim(u8, name, " ")) catch { return errors.ParseError; },
            .value = std.BoundedArray(u8,1024).fromSlice(std.mem.trim(u8, value, " ")) catch { return errors.ParseError; },
        };
    }
};

const Entry = struct {
    name: std.BoundedArray(u8,1024),
    method: HttpMethod,
    url: std.BoundedArray(u8,2048),
    headers: std.BoundedArray(HttpHeader,32), // TODO: Make BoundedArray of HttpHeader?
    payload: std.BoundedArray(u8,1024*1024),
    expected_http_code: u64, // 0 == don't care
    expected_response_regex: std.BoundedArray(u8,1024),

    pub fn create() Entry {
        return Entry {
            .name = initBoundedArray(u8, 1024),
            .method = undefined,
            .url =  initBoundedArray(u8, 2048),
            .headers = initBoundedArray(HttpHeader, 32), // [_]std.BoundedArray(u8, 256){initBoundedArray(u8, 256)}**32,
            .payload = initBoundedArray(u8, 1024*1024),
            .expected_http_code = 0,
            .expected_response_regex = initBoundedArray(u8, 1024),
        };
    }
};

// fn run_entry(entry: *Entry) !void {
//     // 
// }

fn parseHttpMethod(raw: []const u8) errors!HttpMethod {
    if(std.mem.eql(u8, raw, "GET")) {
        return HttpMethod.Get;
    } else if(std.mem.eql(u8, raw, "POST")) {
        return HttpMethod.Post;
    } else if(std.mem.eql(u8, raw, "PUT")) {
        return HttpMethod.Put;
    } else if(std.mem.eql(u8, raw, "DELETE")) {
        return HttpMethod.Delete;
    }
    return errors.ParseError;
}

test "parseHttpMethod" {
    try testing.expect((try parseHttpMethod("GET")) == HttpMethod.Get);
    try testing.expect((try parseHttpMethod("POST")) == HttpMethod.Post);
    try testing.expect((try parseHttpMethod("PUT")) == HttpMethod.Put);
    try testing.expect((try parseHttpMethod("DELETE")) == HttpMethod.Delete);
    try testing.expectError(errors.ParseError, parseHttpMethod("BLAH"));
    try testing.expectError(errors.ParseError, parseHttpMethod(""));
    try testing.expectError(errors.ParseError, parseHttpMethod(" GET"));
}

fn parseStrToDec(comptime T: type, str: []const u8) T {
    // TODO: Handle negatives?
    var result: T = 0;
    for (str) |v, i| {
        result += (@as(T, v) - '0') * std.math.pow(T, 10, str.len - 1 - i);
    }
    return result;
}

fn parse_contents(data: []const u8, result: *Entry) errors!void {
    const ParseState = enum {
        Init,
        InputSection,
        OutputSection,
    };
    // result.name[0] = 'H';
    // Name is set based on file name - i.e: not handled here
    // Tokenize by line ending. Check for first char being > and < to determine sections, then do section-specific parsing.
    var state = ParseState.Init;
    var it = std.mem.split(u8, data, "\n");
    while(it.next()) |line| {
        // TODO: Refactor. State-names are confusing.
        switch(state) {
            ParseState.Init => {
                if(line[0] == '>') {
                    state = ParseState.InputSection;

                    var lit = std.mem.split(u8, line[0..], " ");
                    _ = lit.next(); // skip >
                    result.method = try parseHttpMethod(lit.next().?[0..]);
                    const url = lit.next().?[0..];
                    result.url.insertSlice(0, url) catch {
                        return errors.ParseError;
                    };
                } else {
                    return errors.ParseError;
                }
            },
            ParseState.InputSection => {
                if(line.len == 0) continue;
                if(line[0] == '<') {
                    // Parse initial expected output section
                    state = ParseState.OutputSection;
                    var lit = std.mem.split(u8, line, " ");
                    _ = lit.next(); // skip <
                    result.expected_http_code = parseStrToDec(u64, lit.next().?[0..]);
                    result.expected_response_regex.insertSlice(0, std.mem.trim(u8, lit.rest()[0..], " ")) catch {
                        // Too big?
                        return errors.ParseError;
                    };
                } else {
                    var lit = std.mem.split(u8, line, ":");
                    result.headers.append(try HttpHeader.create(lit.next().?, lit.next().?)) catch {
                        return errors.ParseError;
                    };
                }
            },
            ParseState.OutputSection => {
                // TODO: Nothing to do?
            }
        }
    }
}

// Convenience-function to initiate a bounded-array without inital size of 0, removing the error-case brough by .init(size)
fn initBoundedArray(comptime T: type, comptime capacity: usize) std.BoundedArray(T,capacity) {
    return (std.BoundedArray(T, capacity)){.buffer=undefined};
}

test "string exploration" {
    const str1 = "test";
    var buf = initBoundedArray(u8, 64);
    try testing.expect(buf.buffer.len == 64);
    try testing.expect(str1.len == 4);
    try testing.expect(buf.slice().len == 0);
    try buf.insertSlice(0, str1);
    try testing.expect(buf.slice().len == 4);
}

test "parse_contents" {
    var entry = Entry.create();

    const data =
        \\> GET https://api.warnme.no/api/status
        \\
        \\Content-Type: application/json
        \\Accept: application/json
        \\
        \\< 200   some regex here  
        \\
        ;
    // debug("{s}\n", .{data});
    try parse_contents(data, &entry);

    try testing.expectEqual(entry.method, HttpMethod.Get);
    try testing.expectEqualStrings(entry.url.slice(), "https://api.warnme.no/api/status");
    try testing.expectEqual(entry.expected_http_code, 200);
    try testing.expectEqualStrings(entry.expected_response_regex.slice(), "some regex here");

    // Header-parsing:
    try testing.expectEqual(entry.headers.slice().len, 2);
    try testing.expectEqualStrings("Content-Type", entry.headers.get(0).name.slice());
    try testing.expectEqualStrings("application/json", entry.headers.get(0).value.slice());
    try testing.expectEqualStrings("Accept", entry.headers.get(1).name.slice());
    try testing.expectEqualStrings("application/json", entry.headers.get(1).value.slice());
    // try expect(entry.headers[0].slice())
}
