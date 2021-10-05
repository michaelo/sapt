const std = @import("std");
const debug = std.debug.print;
const testing = std.testing;

const main = @import("main.zig");
const kvstore = @import("kvstore.zig");
const io = @import("io.zig");
const config = @import("config.zig");

const errors = main.errors;
const Entry = main.Entry;
const HttpMethod = main.HttpMethod;
const HttpHeader = main.HttpHeader;
const ExtractionEntry = main.ExtractionEntry;

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
        InputPayloadSection,
        OutputSection,
    };

    const ParserFunctions = struct {
        fn isEmptyLineOrComment(line: []const u8) bool {
            return (line.len == 0 or line[0] == '#');
        }

        fn parseInputSectionHeader(line: []const u8, _result: *Entry) !void {
            var lit = std.mem.split(u8, line[0..], " ");
            _ = lit.next(); // skip >
            _result.method = HttpMethod.create(lit.next().?[0..]) catch return errors.ParseError;
            const url = lit.next().?[0..];
            _result.url.insertSlice(0, url) catch return errors.ParseError;
        }

        fn parseOutputSectionHeader(line: []const u8, _result: *Entry) !void {
            var lit = std.mem.split(u8, line, " ");
            _ = lit.next(); // skip <
            _result.expected_http_code = parseStrToDec(u64, lit.next().?[0..]);
            _result.expected_response_regex.insertSlice(0, std.mem.trim(u8, lit.rest()[0..], " ")) catch return errors.ParseError;
        }

        fn parseHeaderEntry(line: []const u8, _result: *Entry) !void {
            var lit = std.mem.split(u8, line, ":");
            _result.headers.append(try HttpHeader.create(lit.next().?, lit.next().?)) catch return errors.ParseError;
        }

        fn parseExtractionEntry(line: []const u8, _result: *Entry) !void {
            var lit = std.mem.split(u8, line, "=");
            _result.extraction_entries.append(try ExtractionEntry.create(lit.next().?, lit.next().?)) catch return errors.ParseError;
        }

        fn parseInputPayloadLine(line: []const u8, _result: *Entry) !void {
            _result.payload.appendSlice(line) catch return errors.ParseError;
            _result.payload.append('\n') catch return errors.ParseError;
        }
    };

    // Name is set based on file name - i.e: not handled here
    // Tokenize by line ending. Check for first char being > and < to determine sections, then do section-specific parsing.
    var state = ParseState.Init;
    // TODO: Check for any \r\n in data, if so split by that, otherwise \n
    var it = std.mem.split(u8, data, io.getLineEnding(data));
    while (it.next()) |line| {
        // TODO: Refactor. State-names are confusing.
        switch (state) {
            ParseState.Init => {
                if (ParserFunctions.isEmptyLineOrComment(line)) continue;
                if (line[0] == '>') {
                    state = ParseState.InputSection;
                    try ParserFunctions.parseInputSectionHeader(line, result);
                } else {
                    return errors.ParseError;
                }
            },
            ParseState.InputSection => {
                if (ParserFunctions.isEmptyLineOrComment(line)) continue;
                if (line[0] == '-') {
                    state = ParseState.InputPayloadSection;
                } else if (line[0] == '<') {
                    // Parse initial expected output section
                    state = ParseState.OutputSection;
                    try ParserFunctions.parseOutputSectionHeader(line, result);
                } else {
                    // Parse headers
                    try ParserFunctions.parseHeaderEntry(line, result);
                }
            },
            ParseState.InputPayloadSection => { // Optional section
                if (line[0] == '<') {
                    // Check if payload has been added, and trim trailing newline
                    if (result.payload.slice().len > 0) {
                        _ = result.payload.pop();
                    }

                    // Parse initial expected output section
                    state = ParseState.OutputSection;
                    try ParserFunctions.parseOutputSectionHeader(line, result);
                } else {
                    // Add each line verbatim to payload-buffer
                    try ParserFunctions.parseInputPayloadLine(line, result);
                }
            },
            ParseState.OutputSection => {
                if (ParserFunctions.isEmptyLineOrComment(line)) continue;

                // Parse extraction_entries
                try ParserFunctions.parseExtractionEntry(line, result);
            },
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

/// buffer must be big enough to store the expanded variables. TBD: Manage on heap?
// TODO: Pass inn proper kvstore instead of []KeyValuePair
pub fn expandVariablesAndFunctions(comptime S: usize, buffer: *std.BoundedArray(u8, S), variables: *kvstore.KvStore) !void {
    if (buffer.slice().len == 0) return;

    const MAX_VARIABLES = 64;
    var pairs = try findAllVariables(buffer.buffer.len, MAX_VARIABLES, buffer);
    try expandVariables(buffer.buffer.len, MAX_VARIABLES, buffer, &pairs, variables);
}

test "expandVariablesAndFunctions" {
    var variables = kvstore.KvStore{};
    try variables.add("key", "value");

    {
        var testbuf = try std.BoundedArray(u8, 1024).fromSlice("");
        try expandVariablesAndFunctions(testbuf.buffer.len, &testbuf, &variables);
        try testing.expectEqualStrings("", testbuf.slice());
    }

    {
        var testbuf = try std.BoundedArray(u8, 1024).fromSlice("hey");
        try expandVariablesAndFunctions(testbuf.buffer.len, &testbuf, &variables);
        try testing.expectEqualStrings("hey", testbuf.slice());
    }

    {
        var testbuf = try std.BoundedArray(u8, 1024).fromSlice("{{key}}");
        try expandVariablesAndFunctions(testbuf.buffer.len, &testbuf, &variables);
        try testing.expectEqualStrings("value", testbuf.slice());
    }

    {
        var testbuf = try std.BoundedArray(u8, 1024).fromSlice("woop {{key}} doop");
        try expandVariablesAndFunctions(testbuf.buffer.len, &testbuf, &variables);
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

    for (buffer.slice()[0 .. buffer.slice().len - 1]) |char, i| {
        if (skip_next) {
            skip_next = false;
            continue;
        }

        switch (char) {
            '{' => {
                if (buffer.slice()[i + 1] == '{') {
                    try opens.append(i);
                    skip_next = true;
                }
            },
            '}' => {
                if (buffer.slice()[i + 1] == '}') {
                    skip_next = true;
                    // pop, if any.
                    if (opens.slice().len > 0) {
                        try pairs.append(BracketPair{ .start = opens.pop(), .end = i + 1, .depth = opens.slice().len });
                    } else {
                        debug("ERROR: Found close-brackets at idx={d} with none open", .{i});
                        return errors.ParseError;
                        // TODO: Print surrounding slice?
                    }
                }
            },
            else => {},
        }
    }

    if (opens.slice().len > 0) {
        for (opens.slice()) |idx| debug("ERROR: Brackets remaining open: idx={d}\n", .{idx});
        return errors.ParseError;
        // TODO: Print surrounding slice?
    }

    return pairs;
}

// TODO: Are there any stdlib-variants of this?
fn addUnsignedSigned(comptime UnsignedType: type, comptime SignedType: type, base: UnsignedType, delta: SignedType) !UnsignedType {
    if (delta >= 0) {
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

const FunctionEntryFuncPtr = fn ([]const u8, *std.BoundedArray(u8, 1024)) anyerror!void;

const FunctionEntry = struct {
    name: []const u8,
    function: FunctionEntryFuncPtr,
    fn create(name: []const u8, function: FunctionEntryFuncPtr) FunctionEntry {
        return .{ .name = name, .function = function };
    }
};

// Split out such functions to separate file
fn funcWoop(value: []const u8, out_buf: *std.BoundedArray(u8, 1024)) !void {
    _ = value;
    try out_buf.insertSlice(0, "woop");
}

fn funcBlank(value: []const u8, out_buf: *std.BoundedArray(u8, 1024)) !void {
    _ = value;
    try out_buf.insertSlice(0, "");
}

fn funcMyfunc(value: []const u8, out_buf: *std.BoundedArray(u8, 1024)) !void {
    try out_buf.insertSlice(0, value);
}

fn funcBase64enc(value: []const u8, out_buf: *std.BoundedArray(u8, 1024)) !void {
    var buffer: [1024]u8 = undefined;
    try out_buf.insertSlice(0, std.base64.standard.Encoder.encode(&buffer, value));
}

// fn funcBase64dec() !void {

// }

// fn funcUrlencode() !void {

// }

test "funcBase64enc" {
    var input = "abcde12345:";
    var expected = "YWJjZGUxMjM0NTo=";

    var output = try std.BoundedArray(u8, 1024).init(0);
    try funcBase64enc(input, &output);
    try testing.expectEqualStrings(expected, output.constSlice());
}

const global_functions = [_]FunctionEntry{
    FunctionEntry.create("woopout", funcWoop),
    FunctionEntry.create("blank", funcBlank),
    FunctionEntry.create("myfunc", funcMyfunc),
    FunctionEntry.create("base64enc", funcBase64enc),
};

fn getFunction(name: []const u8) !FunctionEntryFuncPtr {
    // TODO: Inefficient
    for (global_functions) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry.function;
        }
    }

    return errors.ParseError; // TODO: Better error
}

test "getFunction" {
    var buf = main.initBoundedArray(u8, 1024);
    try (try getFunction("woopout"))("doesntmatter", &buf);
    try testing.expectEqualStrings("woop", buf.slice());

    try buf.resize(0);
    try (try getFunction("blank"))("doesntmatter", &buf);
    try testing.expectEqualStrings("", buf.slice());

    try buf.resize(0);
    try testing.expectError(errors.ParseError, getFunction("nosuchfunction"));

    try (try getFunction("myfunc"))("mydata", &buf);
    try testing.expectEqualStrings("mydata", buf.slice());
}

/// Buffer must be large enough to contain the expanded variant.
/// TODO: Test performance with fixed sizes. Possibly redesign the outer to utilize a common scrap buffer
pub fn expandVariables(comptime BufferSize: usize, comptime MaxNumVariables: usize, buffer: *std.BoundedArray(u8, BufferSize), pairs: *std.BoundedArray(BracketPair, MaxNumVariables), variables: *kvstore.KvStore) !void {
    // Algorithm:
    // * prereq: pairs are sorted by depth, desc
    // * pick entry from pairs until empty
    // * extract key
    // * get value for key
    // * store key.len+4-value.len (4 for {{}} ) as "end_delta"
    // * substitute slice in buffer
    // * loop through all remaining pairs and any .start or .end that's > prev.end + end_delta with x + end_delta

    const SortFunc = struct {
        pub fn byDepthDesc(context: void, a: BracketPair, b: BracketPair) bool {
            _ = context;
            return a.depth > b.depth;
        }
    };

    std.sort.sort(BracketPair, pairs.slice(), {}, SortFunc.byDepthDesc);
    var end_delta: i64 = 0;
    for (pairs.slice()) |pair, i| {
        var pair_len = pair.end - pair.start + 1;
        var key = buffer.slice()[pair.start + 2 .. pair.end - 1];

        // check if key is a variable or function
        if (std.mem.indexOf(u8, key, "(") != null and std.mem.indexOf(u8, key, ")") != null) {
            // Found function:
            // Parse function name, extract "parameter", lookup and call proper function
            var func_key = key[0..std.mem.indexOf(u8, key, "(").?];
            var func_arg = key[std.mem.indexOf(u8, key, "(").? + 1 .. std.mem.indexOf(u8, key, ")").?];
            var function = try getFunction(func_key);
            var func_buf = main.initBoundedArray(u8, 1024);
            try function(func_arg, &func_buf);

            buffer.replaceRange(pair.start, pair_len, func_buf.slice()) catch {
                return errors.ParseError; // TODO: Need more errors
            };
            end_delta = @intCast(i32, func_buf.slice().len) - (@intCast(i32, key.len) + 4); // 4 == {{}}
        } else {
            if (variables.get(key)) |value| {
                var value_len = value.len;
                end_delta = @intCast(i32, value_len) - (@intCast(i32, key.len) + 4); // 4 == {{}}
                buffer.replaceRange(pair.start, pair_len, value) catch {
                    return errors.ParseError; // TODO: Need more errors
                };
            } else {
                return error.NoSuchVariableFound;
            }
        }

        // debug("\n{s}\n", .{buffer.constSlice()});

        for (pairs.slice()[i + 1 ..]) |*pair2| {
            if (pair2.start > @intCast(i64, pair.start + 1) + end_delta) pair2.start = try addUnsignedSigned(u64, i64, pair2.start, end_delta);
            if (pair2.end > @intCast(i64, pair.start + 1) + end_delta) pair2.end = try addUnsignedSigned(u64, i64, pair2.end, end_delta);
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
    var variables = kvstore.KvStore{};
    try variables.add("var1", "value1");
    try variables.add("var2", "v2");
    try variables.add("var3", "woop");
    // var functions = [_]Pair{};

    // TODO: How to detect functions... ()? Or <known keyword>()?
    var pairs = try findAllVariables(str.buffer.len, MAX_VARIABLES, &str);
    try expandVariables(str.buffer.len, MAX_VARIABLES, &str, &pairs, &variables);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "{{var1}}") == null);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "{{var2}}") == null);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "{{var3}}") == null);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "{{myfunc") == null);

    try testing.expect(std.mem.indexOf(u8, str.slice(), "value1") != null);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "v2") != null);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "woop") != null);
}

test "parseContents ignores comments" {
    var entry = Entry{};

    const data =
        \\> GET https://api.warnme.no/api/status
        \\
        \\# Content-Type: application/json
        \\# Accept: application/json
        \\
        \\< 200   some regex here  
        \\
    ;

    try parseContents(data, &entry);
    try testing.expect(entry.headers.slice().len == 0);
}

test "parseContents shall extract payload" {
    var entry = Entry{};

    const data =
        \\> GET https://api.warnme.no/api/status
        \\
        \\Content-Type: application/json
        \\Accept: application/json
        \\
        \\-
        \\Payload goes here
        \\and here
        \\< 200   some regex here  
        \\
    ;

    try parseContents(data, &entry);
    // TODO: Should we trim trailing newline of payload?
    try testing.expectEqualStrings("Payload goes here\nand here", entry.payload.slice());
}

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

        if (end_pos == 0) end_pos = buf.len;

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



const PlaybookSegmentType = enum {
    Unknown,
    Comment, // ignore?
    TestInclude,
    EnvInclude,
    TestRaw,
    EnvRaw
};

const PlaybookSegment = struct {
    segment_type:PlaybookSegmentType = .Unknown,
    slice: []const u8 = undefined, // Slice into raw buffer
    // TODO: add run-spec for e.g. test-repetitions
};



fn parsePlaybook(buf: []const u8, result: []PlaybookSegment) usize {
    _ = buf;
    _ = result;
    var main_it = std.mem.split(u8, buf, io.getLineEnding(buf));
    var line_idx: u64 = 0;
    var seg_idx: u64 = 0;
    while(main_it.next()) |line| {
    // var jumpback: bool = true;
        line_idx += 1;
        if(line.len == 0) continue; // ignore blank lines TBD: Must be sure we don't skip them if part of payload
        if(line[0] == '#') continue; // ignore comments

        // jumpbackblock: while(jumpback) {
        //     jumpback = false;
            // Top level evaluation
            switch(line[0]) {
                '@' => {
                    // Got file inclusion segment
                    // TODO: it doesn't necessarily end with the ext - it may containt runtime-specs as well (e.g. repetitions)
                    //       TBD: imlement non-space separator? e.g. '*'? 
                    // var sub_it = std.mem.split(u8, line, "*");
                    if(std.mem.endsWith(u8, line, config.CONFIG_FILE_EXT_TEST)) {
                        result[seg_idx] = .{
                            .segment_type = .TestInclude,
                            .slice = line[1..]
                        };
                        seg_idx += 1;
                    } else if(std.mem.endsWith(u8, line, config.CONFIG_FILE_EXT_ENV)) {
                        result[seg_idx] = .{
                            .segment_type = .EnvInclude,
                            .slice = line[1..]
                        };
                        seg_idx += 1;
                    }
                },
                '>' => {
                    var buf_start = @ptrToInt(buf.ptr);
                    var start_idx = @ptrToInt(line.ptr)-buf_start;
                    var end_idx: ?u64 = null;
                    // Parse "in-filed" test
                    // Parse until next >, @ or eof
                    // Opt: store pointer to start, iterate until end, store pointer to end, create slice from pointers?
                    while(main_it.next()) |line2| {
                        line_idx += 1;
                        switch(line2[0]) {
                            '>','@' => {
                                end_idx = @ptrToInt(line2.ptr)-buf_start-1;
                                // PROBLEM: We now have a new top-line section that should be process - need to to back to top-switch... TODO
                                result[seg_idx] = .{
                                    .segment_type = .TestRaw,
                                    .slice = buf[start_idx..end_idx.?+1],
                                };
                                seg_idx += 1;
                                // jumpback = true;
                                // break :jumpbackblock;// break while...
                            },
                            else => {}
                        }
                    }

                    if(end_idx == null) {
                        // Reached end of file
                        end_idx = @ptrToInt(&buf[buf.len-1]) - buf_start;

                        result[seg_idx] = .{
                            .segment_type = .TestRaw,
                            .slice = buf[start_idx..end_idx.?+1],
                        };
                        seg_idx += 1;
                    }
                },
                else => {
                    if(std.mem.indexOf(u8, line, "=") != null) {
                        result[seg_idx] = .{
                            .segment_type = .EnvRaw,
                            .slice = line[0..]
                        };
                        seg_idx += 1;
                    }
                }
            }
        // }
    }
    debug("return: {}\n", .{seg_idx});
    return seg_idx;
}

test "parse playbook" {
    { // include single test
        const buf =
        \\@some/test.pi
        \\
        ;
        var segments = main.initBoundedArray(PlaybookSegment, 128);
        try segments.resize(parsePlaybook(buf, segments.unusedCapacitySlice()));

        try testing.expectEqual(@intCast(usize, 1), segments.len);

        try testing.expectEqual(PlaybookSegmentType.TestInclude, segments.get(0).segment_type);
        try testing.expectEqualStrings("some/test.pi", segments.get(0).slice);
    }

    { // include test and env
        const buf =
        \\@some/test.pi
        \\@some/.env
        \\
        ;
        var segments = main.initBoundedArray(PlaybookSegment, 128);
        try segments.resize(parsePlaybook(buf, segments.unusedCapacitySlice()));

        try testing.expect(segments.len == 2);

        try testing.expectEqual(PlaybookSegmentType.EnvInclude, segments.get(1).segment_type);
        try testing.expectEqualStrings("some/.env", segments.get(1).slice);
    }

    {
        // include specific env
        const buf =
        \\MY_ENV=somevalue
        \\
        ;
        var segments = main.initBoundedArray(PlaybookSegment, 128);
        try segments.resize(parsePlaybook(buf, segments.unusedCapacitySlice()));

        try testing.expect(segments.len == 1);

        try testing.expectEqual(PlaybookSegmentType.EnvRaw, segments.get(0).segment_type);
        try testing.expectEqualStrings("MY_ENV=somevalue", segments.get(0).slice);
    }

    {
        // include specific test
        const buf =
        \\> GET https://my.service/api
        \\< 200
        ;
        var segments = main.initBoundedArray(PlaybookSegment, 128);
        try segments.resize(parsePlaybook(buf, segments.unusedCapacitySlice()));

        try testing.expect(segments.len == 1);

        try testing.expectEqual(PlaybookSegmentType.TestRaw, segments.get(0).segment_type);
        try testing.expectEqualStrings("> GET https://my.service/api\n< 200", segments.get(0).slice);
    }


    {
        // include specific test
        const buf =
        \\> GET https://my.service/api
        \\< 200
        \\> GET https://my.service/api2
        \\< 200
        ;
        var segments = main.initBoundedArray(PlaybookSegment, 128);
        try segments.resize(parsePlaybook(buf, segments.unusedCapacitySlice()));

        try testing.expect(segments.len == 2);

        try testing.expectEqual(PlaybookSegmentType.TestRaw, segments.get(0).segment_type);
        try testing.expectEqualStrings("> GET https://my.service/api\n< 200", segments.get(0).slice);
        try testing.expectEqualStrings("> GET https://my.service/api2\n< 200", segments.get(1).slice);
    }


}