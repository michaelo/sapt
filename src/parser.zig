const std = @import("std");
const debug = std.debug.print;
const testing = std.testing;

const main = @import("main.zig");
const errors = main.errors;
const Entry = main.Entry;
const HttpMethod = main.HttpMethod;
const HttpHeader = main.HttpHeader;
const ExtractionEntry = main.ExtractionEntry;

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

pub fn parseContents(data: []const u8, result: *Entry) errors!void {
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
                if(line.len == 0) continue;
                var lit = std.mem.split(u8, line, "=");
                result.extraction_entries.append(try ExtractionEntry.create(lit.next().?, lit.next().?)) catch {
                    return errors.ParseError;
                };
            }
        }
    }
}


test "parseContents" {
    var entry = Entry{};

    const data =
        \\> GET https://api.warnme.no/api/status
        \\
        \\Content-Type: application/json
        \\Accept: application/json
        \\
        \\< 200   some regex here  
        \\
        ;

    try parseContents(data, &entry);

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
}


test "parseContents extracts to variables" {
    var entry = Entry{};

    const data =
        \\> GET https://api.warnme.no/api/status
        \\
        \\Content-Type: application/json
        \\Accept: application/json
        \\
        \\< 200   some regex here  
        \\myvar=regexwhichextractsvalue
        \\
        ;

    try parseContents(data, &entry);
    // debug("sizeof(Entry): {}\n", .{@intToFloat(f64,@sizeOf(Entry))/1024/1024});
    try testing.expectEqual(@intCast(usize, 1), entry.extraction_entries.slice().len);
    try testing.expectEqualStrings("myvar", entry.extraction_entries.get(0).name.slice());
    try testing.expectEqualStrings("regexwhichextractsvalue", entry.extraction_entries.get(0).expression.slice());
}

const KeyValuePair = struct {
    key: std.BoundedArray(u8,1024) = main.initBoundedArray(u8, 1024),
    value: std.BoundedArray(u8,1024) = main.initBoundedArray(u8, 1024),
    pub fn create(key: []const u8, value: []const u8) !KeyValuePair {
        var result = KeyValuePair{};
        try result.key.insertSlice(0, key);
        try result.value.insertSlice(0, value);
        return result;
    }
};

/// buffer must be big enough to store the expanded variables. TBD: Manage on heap?
pub fn expandVariablesAndFunctions(comptime S: usize, buffer: *std.BoundedArray(u8, S), variables: []KeyValuePair) !void {
    if(buffer.slice().len == 0) return;

    const MAX_VARIABLES = 64;
    var pairs = try findAllVariables(buffer.buffer.len, MAX_VARIABLES, buffer);
    try expandVariables(buffer.buffer.len, MAX_VARIABLES, buffer, &pairs, variables);
}


test "expandVariablesAndFunctions" {
    var variables = [_]KeyValuePair{try KeyValuePair.create("key", "value")};
    try testing.expectEqualStrings("key", variables[0].key.slice());
    try testing.expectEqualStrings("value", variables[0].value.slice());
    // try testing.expect(mypair.key.capacity() == 1024);
    {
        var testbuf = try std.BoundedArray(u8, 1024).fromSlice("");
        try expandVariablesAndFunctions(testbuf.buffer.len, &testbuf, variables[0..]);
        try testing.expectEqualStrings("", testbuf.slice());
    }

    {
        var testbuf = try std.BoundedArray(u8, 1024).fromSlice("hey");
        try expandVariablesAndFunctions(testbuf.buffer.len, &testbuf, variables[0..]);
        try testing.expectEqualStrings("hey", testbuf.slice());
    }

    {
        var testbuf = try std.BoundedArray(u8, 1024).fromSlice("{{key}}");
        try expandVariablesAndFunctions(testbuf.buffer.len, &testbuf, variables[0..]);
        try testing.expectEqualStrings("value", testbuf.slice());
    }

    {
        var testbuf = try std.BoundedArray(u8, 1024).fromSlice("woop {{key}} doop");
        try expandVariablesAndFunctions(testbuf.buffer.len, &testbuf, variables[0..]);
        try testing.expectEqualStrings("woop value doop", testbuf.slice());
    }
}

const BracketPair = struct {
    start: usize = undefined,
    end: usize = undefined,
    depth: usize = undefined, // If nested, how deep
};

pub fn findAllVariables(comptime BufferSize: usize, comptime MaxNumVariables: usize, buffer: *std.BoundedArray(u8, BufferSize)) !std.BoundedArray(BracketPair, MaxNumVariables) {
    var opens: std.BoundedArray(usize, MaxNumVariables) = main.initBoundedArray(usize, MaxNumVariables);
    var pairs: std.BoundedArray(BracketPair, MaxNumVariables) = main.initBoundedArray(BracketPair, MaxNumVariables);
    var skip_next = false;

    for(buffer.slice()[0..buffer.slice().len-1]) |char, i| {
        if(skip_next) {
            skip_next = false;
            continue;
        }

        switch(char) {
            '{' => {
                if(buffer.slice()[i+1] == '{') {
                    try opens.append(i);
                    skip_next = true;
                }
            },
            '}' => {
                if(buffer.slice()[i+1] == '}') {
                    skip_next = true;
                    // pop, if any. 
                    if(opens.slice().len > 0) {
                        try pairs.append(BracketPair {
                            .start = opens.pop(),
                            .end = i+1,
                            .depth = opens.slice().len
                        });
                    } else {
                        debug("ERROR: Found close-brackets at idx={d} with none open", .{i});
                        return errors.ParseError;
                        // TODO: Print surrounding slice?
                    }
                }
            },
            else => {}
        }
    }

    if(opens.slice().len > 0) {
        for(opens.slice()) |idx| debug("ERROR: Brackets remaining open: idx={d}\n", .{idx});
        return errors.ParseError;
        // TODO: Print surrounding slice?
    }

    return pairs;
}

fn byDepthDesc(context: void, a: BracketPair, b: BracketPair) bool {
    _ = context;
    return a.depth > b.depth;
}

// TODO: Are there any stdlib-variants of this?
pub fn addUnsignedSigned(comptime UnsignedType: type, comptime SignedType:type, base: UnsignedType, delta: SignedType) !UnsignedType {
    if(delta >= 0) {
        return std.math.add(UnsignedType, base, std.math.absCast(delta));
    } else {
        return std.math.sub(UnsignedType, base, std.math.absCast(delta));
    }
}

test "addUnsignedSigned" {
    try testing.expect((try addUnsignedSigned(u64, i64, 1, 1)) == 2);
    try testing.expect((try addUnsignedSigned(u64, i64, 1, -1)) == 0);
    try testing.expectError(error.Overflow, addUnsignedSigned(u64, i64, 0, -1));
    try testing.expectError(error.Overflow, addUnsignedSigned(u64, i64, std.math.maxInt(u64), 1));
}

/// Buffer must be large enough to contain the expanded variant.
/// TODO: Test performance with fixed sizes. Possibly redesign the outer to utilize a common scrap buffer
pub fn expandVariables(comptime BufferSize: usize,
                       comptime MaxNumVariables: usize,
                       buffer: *std.BoundedArray(u8, BufferSize),
                       pairs: *std.BoundedArray(BracketPair, MaxNumVariables),
                       variables: []KeyValuePair) !void {
    // Algorithm:
    // * prereq: pairs are sorted by depth, desc
    // * pick entry from pairs until empty
    // * extract key
    // * get value for key
    // * store key.len+4-value.len (4 for {{}} ) as "end_delta"
    // * substitute slice in buffer
    // * loop through all remaining pairs and any .start or .end that's > prev.end + end_delta with x + end_delta

    _ = variables;
    _ = buffer;

    std.sort.sort(BracketPair, pairs.slice(), {}, byDepthDesc);

    for(pairs.slice()) |pair, i| {
        var pair_len = pair.end-pair.start+1;
        var key = buffer.slice()[pair.start+2..pair.end-1];
        _ = key; // TODO: use to lookup value / func
        var value = variables[0].value.slice();
        var value_len = value.len;
        var end_delta: i64 = @intCast(i32, value_len) - (@intCast(i32, key.len)+4); // 4 == {{}}
        buffer.replaceRange(pair.start, pair_len, value) catch {
            // debug("Could not replace '{s}' with '{s}'\n", .{key_slice, variables[0].value.slice()});
            return errors.ParseError; // TODO: Need more errors
        };

        for(pairs.slice()[i..]) |*pair2| {
            if(pair2.start > @intCast(i64, pair.end)+end_delta) pair2.start = try addUnsignedSigned(u64, i64, pair2.start, end_delta);
            if(pair2.end > @intCast(i64, pair.end)+end_delta) pair2.end = try addUnsignedSigned(u64, i64, pair2.end, end_delta);
        }
    }
}


test "bracketparser" {
    const MAX_VARIABLES = 64;
    var str = try std.BoundedArray(u8, 1024).fromSlice(
    \\begin
    \\{{var1}}
    \\{{var2}}
    \\{{myfunc({{var3}})}}
    \\end
    );
    var variables = [_]KeyValuePair{try KeyValuePair.create("var1", "value1"), try KeyValuePair.create("var2", "v2"), try KeyValuePair.create("var3", "woop")};
    // var functions = [_]Pair{};

    // TODO: How to detect functions... ()? Or <known keyword>()?
    var pairs = try findAllVariables(str.buffer.len, MAX_VARIABLES, &str);
    try expandVariables(str.buffer.len, MAX_VARIABLES, &str, &pairs, variables[0..]);

    // debug("Result: {s}\n", .{str.slice()});
}