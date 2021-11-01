const std = @import("std");
const debug = std.debug.print;
const testing = std.testing;

const main = @import("main.zig");
const kvstore = @import("kvstore.zig");
const io = @import("io.zig");
const config = @import("config.zig");
const utils = @import("utils.zig");
const types = @import("types.zig");

const errors = main.errors;
const Entry = main.Entry;
const HttpMethod = types.HttpMethod;
const HttpHeader = types.HttpHeader;
const ExtractionEntry = types.ExtractionEntry;

const Console = @import("console.zig").Console;

pub fn parseError(comptime text: []const u8, line_no: usize, col_no: usize, buf: []const u8, line: []const u8) void {
    parseErrorArg(text, .{}, line_no, col_no, buf, line);
}

pub fn parseErrorArg(comptime text: []const u8, args: anytype, line_no: usize, col_no: usize, buf: []const u8, line: ?[]const u8) void {
    _ = buf;
    _ = col_no;
    Console.red("ERROR: ", .{});
    Console.plain(text, args);
    if (line) |line_value| {
        Console.plain("\n       Line: {d}: {s}\n", .{ line_no + 1, line_value });
    } else {
        Console.plain("\n", .{});
    }
}

/// data: the data to parse - all expansions etc must have been done before this.
/// result: pre-allocated struct to popuplate with parsed data
/// line_idx_offset: Which line_idx in the source file the data originates from. Used to 
///                  generate better parse errors.
pub fn parseContents(data: []const u8, result: *Entry, line_idx_offset: usize) errors!void {
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
            _result.method = HttpMethod.create(lit.next().?[0..]) catch return errors.ParseErrorInputSectionNoSuchMethod;
            const url = lit.next().?[0..];
            _result.url.insertSlice(0, url) catch return errors.ParseErrorInputSectionUrlTooLong;
        }

        fn parseOutputSectionHeader(line: []const u8, _result: *Entry) !void {
            var lit = std.mem.split(u8, line, " ");
            _ = lit.next(); // skip <
            if (lit.next()) |http_code| {
                _result.expected_http_code = std.fmt.parseInt(u64, http_code[0..], 10) catch return errors.ParseErrorOutputSection;
                _result.expected_response_substring.insertSlice(0, std.mem.trim(u8, lit.rest()[0..], " ")) catch return errors.ParseErrorOutputSection;
            } else {
                return errors.ParseErrorOutputSection;
            }
        }

        fn parseHeaderEntry(line: []const u8, _result: *Entry) !void {
            var lit = std.mem.split(u8, line, ":");
            if (lit.next()) |key| {
                if (lit.next()) |value| {
                    _result.headers.append(try HttpHeader.create(key, value)) catch return errors.ParseErrorHeaderEntry;
                } else {
                    return error.ParseErrorHeaderEntry;
                }
            } else {
                return error.ParseErrorHeaderEntry;
            }
        }

        fn parseExtractionEntry(line: []const u8, _result: *Entry) !void {
            var lit = std.mem.split(u8, line, "=");
            if (lit.next()) |key| {
                if (lit.next()) |value| {
                    _result.extraction_entries.append(try ExtractionEntry.create(key, value)) catch return errors.ParseErrorExtractionEntry;
                } else {
                    return error.ParseErrorExtractionEntry;
                }
            } else {
                return error.ParseErrorExtractionEntry;
            }
        }

        fn parseInputPayloadLine(line: []const u8, _result: *Entry) !void {
            _result.payload.appendSlice(line) catch return errors.ParseErrorInputPayload; // .Overflow
            _result.payload.append('\n') catch return errors.ParseErrorInputPayload; // .Overflow
        }
    };

    // Name is set based on file name - i.e: not handled here
    // Tokenize by line ending. Check for first char being > and < to determine sections, then do section-specific parsing.
    var state = ParseState.Init;
    var it = std.mem.split(u8, data, io.getLineEnding(data));
    var line_idx: usize = line_idx_offset;
    while (it.next()) |line| : (line_idx += 1) {
        // TBD: Refactor? State-names may be confusing.
        switch (state) {
            ParseState.Init => {
                if (ParserFunctions.isEmptyLineOrComment(line)) continue;
                if (line[0] == '>') {
                    state = ParseState.InputSection;
                    ParserFunctions.parseInputSectionHeader(line, result) catch |e| {
                        parseError("Could not parse input section header", line_idx, 0, data, line);
                        return e;
                    };
                } else {
                    parseError("Expected input section header", line_idx, 0, data, line);
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
                    ParserFunctions.parseOutputSectionHeader(line, result) catch |e| {
                        parseError("Could not parse output section header", line_idx, 0, data, line);
                        return e;
                    };
                } else {
                    // Parse headers
                    ParserFunctions.parseHeaderEntry(line, result) catch |e| {
                        parseError("Could not parse header entry", line_idx, 0, data, line);
                        return e;
                    };
                }
            },
            ParseState.InputPayloadSection => { // Optional section
                if (line.len == 0) continue;
                // TODO: This exit-condition for payloads are not sufficient. Will e.g. likely cause false positive for XML payloads
                if (line[0] == '<') {
                    // Check if payload has been added, and trim trailing newline
                    if (result.payload.slice().len > 0) {
                        _ = result.payload.pop();
                    }

                    // Parse initial expected output section
                    state = ParseState.OutputSection;
                    ParserFunctions.parseOutputSectionHeader(line, result) catch |e| {
                        parseError("Could not parse output section header", line_idx, 0, data, line);
                        return e;
                    };
                } else {
                    // Add each line verbatim to payload-buffer
                    ParserFunctions.parseInputPayloadLine(line, result) catch |e| {
                        parseErrorArg("Could not parse payload section - it's too big. Max payload size is {d}B", .{result.payload.capacity()}, line_idx, 0, data, line);
                        return e;
                    };
                }
            },
            ParseState.OutputSection => {
                if (ParserFunctions.isEmptyLineOrComment(line)) continue;

                // Parse extraction_entries
                ParserFunctions.parseExtractionEntry(line, result) catch |e| {
                    parseError("Could not parse extraction entry", line_idx, 0, data, line);
                    return e;
                };
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

    try parseContents(data, &entry, 0);

    try testing.expectEqual(entry.method, HttpMethod.GET);
    try testing.expectEqualStrings(entry.url.slice(), "https://api.warnme.no/api/status");
    try testing.expectEqual(entry.expected_http_code, 200);
    try testing.expectEqualStrings(entry.expected_response_substring.slice(), "some regex here");

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

    try parseContents(data, &entry, 0);
    // debug("sizeof(Entry): {}\n", .{@intToFloat(f64,@sizeOf(Entry))/1024/1024});
    try testing.expectEqual(@intCast(usize, 1), entry.extraction_entries.slice().len);
    try testing.expectEqualStrings("myvar", entry.extraction_entries.get(0).name.slice());
    try testing.expectEqualStrings("regexwhichextractsvalue", entry.extraction_entries.get(0).expression.slice());
}

pub fn dumpUnresolvedBracketPairsForBuffer(buf: []const u8, brackets: []const BracketPair) void {
    for (brackets) |pair, i| {
        if (pair.resolved) continue;
        debug("{d}: [{d}-{d}, {d}]: {s}\n", .{i, pair.start, pair.end, pair.depth, buf[pair.start..pair.end+1]});
    }
}

/// buffer must be big enough to store the expanded variables. TBD: Manage on heap?
pub fn expandVariablesAndFunctions(comptime S: usize, buffer: *std.BoundedArray(u8, S), maybe_variables_sets: ?[]*kvstore.KvStore) !void {
    if (buffer.slice().len == 0) return;
    const MAX_VARIABLES = 64;

    const SortBracketsFunc = struct {
        pub fn byDepthDesc(context: void, a: BracketPair, b: BracketPair) bool {
            _ = context;
            return a.depth > b.depth;
        }
    };

    var pairs = try findAllVariables(buffer.buffer.len, MAX_VARIABLES, buffer);
    std.sort.sort(BracketPair, pairs.slice(), {}, SortBracketsFunc.byDepthDesc);

    if(maybe_variables_sets) |variables_sets| for (variables_sets) |variables| {
        // dumpUnresolvedBracketPairsForBuffer(buffer.constSlice(), pairs.constSlice()); // DEBUG
        expandVariables(buffer.buffer.len, MAX_VARIABLES, buffer, &pairs, variables) catch |e| switch(e) {
            //error.NoSuchVariableFound => {}, // This is OK, as we don't know which variable_set the variable to expand may be in 
            else => return e
        };
    };

    try expandFunctions(buffer.buffer.len, MAX_VARIABLES, buffer, &pairs);
}

test "expandVariablesAndFunctions" {
    var variables = kvstore.KvStore{};
    var variables_sets = [_]*kvstore.KvStore{&variables};
    try variables.add("key", "value");

    {
        var testbuf = try std.BoundedArray(u8, 1024).fromSlice("");
        try expandVariablesAndFunctions(testbuf.buffer.len, &testbuf, variables_sets[0..]);
        try testing.expectEqualStrings("", testbuf.slice());
    }

    {
        var testbuf = try std.BoundedArray(u8, 1024).fromSlice("hey");
        try expandVariablesAndFunctions(testbuf.buffer.len, &testbuf, variables_sets[0..]);
        try testing.expectEqualStrings("hey", testbuf.slice());
    }

    {
        var testbuf = try std.BoundedArray(u8, 1024).fromSlice("{{key}}");
        try expandVariablesAndFunctions(testbuf.buffer.len, &testbuf, variables_sets[0..]);
        try testing.expectEqualStrings("value", testbuf.slice());
    }

    {
        var testbuf = try std.BoundedArray(u8, 1024).fromSlice("{{key}}{{key}}");
        try expandVariablesAndFunctions(testbuf.buffer.len, &testbuf, variables_sets[0..]);
        try testing.expectEqualStrings("valuevalue", testbuf.slice());
    }

    {
        var testbuf = try std.BoundedArray(u8, 1024).fromSlice("woop {{key}} doop");
        try expandVariablesAndFunctions(testbuf.buffer.len, &testbuf, variables_sets[0..]);
        try testing.expectEqualStrings("woop value doop", testbuf.slice());
    }
}

test "expansion bug" {
    var variables = kvstore.KvStore{};
    try variables.add("my_token", "valuevaluevaluevaluevaluevaluevaluevaluevaluevaluevalue");

    var testbuf = try std.BoundedArray(u8, 8 * 1024).fromSlice(
        \\Authorization: bearer {{my_token}}
        \\Cookie: RandomSecurityToken={{my_token}}; SomeOtherRandomCookie={{my_token}}
        \\RandomSecurityToken: {{my_token}}
    );
    try expandVariablesAndFunctions(testbuf.buffer.len, &testbuf, ([_]*kvstore.KvStore{&variables})[0..]);
    try testing.expectEqualStrings(
        \\Authorization: bearer valuevaluevaluevaluevaluevaluevaluevaluevaluevaluevalue
        \\Cookie: RandomSecurityToken=valuevaluevaluevaluevaluevaluevaluevaluevaluevaluevalue; SomeOtherRandomCookie=valuevaluevaluevaluevaluevaluevaluevaluevaluevaluevalue
        \\RandomSecurityToken: valuevaluevaluevaluevaluevaluevaluevaluevaluevaluevalue
    , testbuf.slice());
}

const BracketPair = struct {
    start: usize = undefined,
    end: usize = undefined,
    depth: usize = undefined, // If nested, how deep
    resolved: bool = false,
};

pub fn findAllVariables(comptime BufferSize: usize, comptime MaxNumVariables: usize, buffer: *std.BoundedArray(u8, BufferSize)) !std.BoundedArray(BracketPair, MaxNumVariables) {
    var opens: std.BoundedArray(usize, MaxNumVariables) = utils.initBoundedArray(usize, MaxNumVariables);
    var pairs: std.BoundedArray(BracketPair, MaxNumVariables) = utils.initBoundedArray(BracketPair, MaxNumVariables);
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
                        // TODO: convert to line and col
                        // TODO: Print surrounding slice?
                        // Not an error. E.g. for json-payloads... 
                        debug("WARNING: Found close-brackets at idx={d} with none open\n", .{i});
                        // return errors.ParseError;
                    }
                }
            },
            else => {},
        }
    }

    if (opens.slice().len > 0) {
        for (opens.slice()) |idx| debug("WARNING: Brackets remaining open: idx={d}\n", .{idx});
        // return errors.ParseError;
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

const FunctionEntryFuncPtr = fn (*std.mem.Allocator, []const u8, *std.BoundedArray(u8, 1024)) anyerror!void;

const FunctionEntry = struct {
    name: []const u8,
    function: FunctionEntryFuncPtr,
    fn create(name: []const u8, function: FunctionEntryFuncPtr) FunctionEntry {
        return .{ .name = name, .function = function };
    }
};

// Split out such functions to separate file
fn funcWoop(_: *std.mem.Allocator, value: []const u8, out_buf: *std.BoundedArray(u8, 1024)) !void {
    _ = value;
    try out_buf.insertSlice(0, "woop");
}

fn funcBlank(_: *std.mem.Allocator, value: []const u8, out_buf: *std.BoundedArray(u8, 1024)) !void {
    _ = value;
    try out_buf.insertSlice(0, "");
}

fn funcMyfunc(_: *std.mem.Allocator, value: []const u8, out_buf: *std.BoundedArray(u8, 1024)) !void {
    try out_buf.insertSlice(0, value);
}

fn funcBase64enc(_: *std.mem.Allocator, value: []const u8, out_buf: *std.BoundedArray(u8, 1024)) !void {
    var buffer: [1024]u8 = undefined;
    try out_buf.insertSlice(0, std.base64.standard.Encoder.encode(&buffer, value));
}

fn funcEnv(allocator: *std.mem.Allocator, value: []const u8, out_buf: *std.BoundedArray(u8, 1024)) !void {
    const env_value = try std.process.getEnvVarOwned(allocator, value);
    defer allocator.free(env_value);
    try out_buf.insertSlice(0, utils.sliceUpTo(u8, env_value, 0, 1024));
    if(env_value.len > out_buf.capacity()) {
        return error.Overflow;
    }
}

test "funcBase64enc" {
    var input = "abcde12345:";
    var expected = "YWJjZGUxMjM0NTo=";

    var output = try std.BoundedArray(u8, 1024).init(0);
    try funcBase64enc(std.testing.allocator, input, &output);
    try testing.expectEqualStrings(expected, output.constSlice());
}

test "funcEnv" {
    var input = "PATH";

    var output = try std.BoundedArray(u8, 1024).init(0);
    funcEnv(std.testing.allocator, input, &output) catch |e| switch(e) {
        error.Overflow => {},
        else => return e
    };
    try testing.expect(output.slice().len > 0);
}

// fn funcBase64dec() !void {

// }

// fn funcUrlencode() !void {

// }

const global_functions = [_]FunctionEntry{
    FunctionEntry.create("woopout", funcWoop),
    FunctionEntry.create("blank", funcBlank),
    FunctionEntry.create("myfunc", funcMyfunc),
    FunctionEntry.create("base64enc", funcBase64enc),
    FunctionEntry.create("env", funcEnv),
};

fn getFunction(name: []const u8) !FunctionEntryFuncPtr {
    // Att: Inefficient. If data set increases, improve (PERFORMANCE)
    for (global_functions) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry.function;
        }
    }

    return errors.NoSuchFunction;
}

test "getFunction" {
    var buf = utils.initBoundedArray(u8, 1024);
    try (try getFunction("woopout"))(std.testing.allocator, "doesntmatter", &buf);
    try testing.expectEqualStrings("woop", buf.slice());

    try buf.resize(0);
    try (try getFunction("blank"))(std.testing.allocator, "doesntmatter", &buf);
    try testing.expectEqualStrings("", buf.slice());

    try buf.resize(0);
    try testing.expectError(errors.NoSuchFunction, getFunction("nosuchfunction"));

    try (try getFunction("myfunc"))(std.testing.allocator, "mydata", &buf);
    try testing.expectEqualStrings("mydata", buf.slice());
}

fn expandFunctions(comptime BufferSize: usize, comptime MaxNumVariables: usize, buffer: *std.BoundedArray(u8, BufferSize), pairs: *std.BoundedArray(BracketPair, MaxNumVariables)) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    var end_delta: i64 = 0;
    for (pairs.slice()) |*pair, i| {
        if(pair.resolved) continue;
        var pair_len = pair.end - pair.start + 1;
        var key = buffer.slice()[pair.start + 2 .. pair.end - 1];
        // debug("Checking for function by key: {s}\n", .{key});

        // check if key is a function, otherwise ignore
        if (std.mem.indexOf(u8, key, "(") != null and std.mem.indexOf(u8, key, ")") != null) {
            // Parse function name, extract "parameter", lookup and call proper function
            var func_key = key[0..std.mem.indexOf(u8, key, "(").?];
            var func_arg = key[std.mem.indexOf(u8, key, "(").? + 1 .. std.mem.indexOf(u8, key, ")").?];
            var function = try getFunction(func_key);
            var func_buf = utils.initBoundedArray(u8, 1024);
            try function(allocator, func_arg, &func_buf);

            buffer.replaceRange(pair.start, pair_len, func_buf.slice()) catch {
                // .Overflow
                return errors.BufferTooSmall;
            };
            pair.resolved = true;
            end_delta = @intCast(i32, func_buf.slice().len) - (@intCast(i32, key.len) + 4); // 4 == {{}}

            for (pairs.slice()[i + 1 ..]) |*pair2| {
                if (pair2.start > @intCast(i64, pair.start + 1)) pair2.start = try addUnsignedSigned(u64, i64, pair2.start, end_delta);
                if (pair2.end > @intCast(i64, pair.start + 1)) pair2.end = try addUnsignedSigned(u64, i64, pair2.end, end_delta);
            }
        }
    }
}

/// Buffer must be large enough to contain the expanded variant.
/// TODO: Test performance with fixed sizes. Possibly redesign the outer to utilize a common scrap buffer
fn expandVariables(comptime BufferSize: usize, comptime MaxNumVariables: usize, buffer: *std.BoundedArray(u8, BufferSize), pairs: *std.BoundedArray(BracketPair, MaxNumVariables), variables: *kvstore.KvStore) !void {
    // Algorithm:
    // * prereq: pairs are sorted by depth, desc
    // * pick entry from pairs until empty
    // * extract key
    // * get value for key
    // * store key.len+4-value.len (4 for {{}} ) as "end_delta"
    // * substitute slice in buffer
    // * loop through all remaining pairs and any .start or .end that's > prev.end + end_delta with x + end_delta

    var end_delta: i64 = 0;
    for (pairs.slice()) |*pair| {
        if (pair.resolved) continue;
        var pair_len = pair.end - pair.start + 1;
        var key = buffer.slice()[pair.start + 2 .. pair.end - 1];
        // debug("Checking for variable by key: {s}\n", .{key});

        // check if key is a variable (not function)
        if (!(std.mem.indexOf(u8, key, "(") != null and std.mem.indexOf(u8, key, ")") != null)) {
            if (variables.get(key)) |value| {
                var value_len = value.len;
                end_delta = @intCast(i32, value_len) - (@intCast(i32, key.len) + 4); // 4 == {{}}
                buffer.replaceRange(pair.start, pair_len, value) catch {
                    return errors.BufferTooSmall;
                };
                pair.resolved = true;

                // for (pairs.slice()[i + 1 ..]) |*pair2| {
                for (pairs.slice()[0..]) |*pair2| {
                    if (pair2.resolved) continue;// Since we no longer go exclusively by depth (we run this function multiple times with different sets), we have to check from start and filter out resolved instead
                    if (pair2.start > @intCast(i64, pair.start + 1)) pair2.start = try addUnsignedSigned(u64, i64, pair2.start, end_delta);
                    if (pair2.end > @intCast(i64, pair.start + 1)) pair2.end = try addUnsignedSigned(u64, i64, pair2.end, end_delta);
                }
            } else {
                // TODO: Make debug, and verbose-dependent?
                // debug("WARNING: Could not resolve variable: '{s}'\n", .{key});
                // result = error.NoSuchVariableFound;
            }
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

    var pairs = try findAllVariables(str.buffer.len, MAX_VARIABLES, &str);
    try expandVariables(str.buffer.len, MAX_VARIABLES, &str, &pairs, &variables);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "{{var1}}") == null);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "{{var2}}") == null);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "{{var3}}") == null);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "{{myfunc") != null);

    try testing.expect(std.mem.indexOf(u8, str.slice(), "value1") != null);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "v2") != null);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "woop") != null);

    try expandFunctions(str.buffer.len, MAX_VARIABLES, &str, &pairs);
    try testing.expect(std.mem.indexOf(u8, str.slice(), "{{myfunc") == null);
}

// TODO: Add more stress-tests for advanced variable/function-substitution

test "substitution advanced tests" {
    var str = try std.BoundedArray(u8, 1024).fromSlice(
        \\{{s1_var}}
        \\{{s1_var2}}
        \\{{myfunc({{s3_var}}:{{s2_var}})}}
        \\{{s2_var}}
        \\{{s3_var}}
    );

    var str_expected = 
    \\s1varlongervaluehere
    \\
    \\s3varlongervaluehere:
    \\
    \\s3varlongervaluehere
    ;
    var s1 = kvstore.KvStore{};
    try s1.add("s1_var", "s1varlongervaluehere");
    try s1.add("s1_var2", "");
    var s2 = kvstore.KvStore{};
    try s2.add("s2_var", "");

    var s3 = kvstore.KvStore{};
    try s3.add("s3_var", "s3varlongervaluehere");

    var sets = [_]*kvstore.KvStore{&s1, &s2, &s3};

    try expandVariablesAndFunctions(str.buffer.len, &str, sets[0..]);

    try testing.expectEqualStrings(str_expected, str.slice());
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

    try parseContents(data, &entry, 0);
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

    try parseContents(data, &entry, 0);
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

pub const PlaybookSegmentType = enum { Unknown, TestInclude, EnvInclude, TestRaw, EnvRaw };

pub const SegmentMetadata = union(PlaybookSegmentType) {
    Unknown: void,
    TestInclude: struct {
        repeats: u32,
    },
    EnvInclude: void,
    TestRaw: void,
    EnvRaw: void,
};

pub const PlaybookSegment = struct {
    line_start: u64,
    segment_type: PlaybookSegmentType = .Unknown,
    slice: []const u8 = undefined, // Slice into raw buffer
    meta: SegmentMetadata = undefined,
};

/// Parses a playbook-file into a list of segments. Each segment must then be further processed according to the segment-type
pub fn parsePlaybook(buf: []const u8, result: []PlaybookSegment) usize {
    var main_it = std.mem.split(u8, buf, io.getLineEnding(buf));
    var line_idx: u64 = 0;
    var seg_idx: u64 = 0;

    while (main_it.next()) |line| : (line_idx += 1) {
        if (line.len == 0) continue; // ignore blank lines
        if (line[0] == '#') continue; // ignore comments

        // Top level evaluation
        switch (line[0]) {
            '@' => {
                // Got file inclusion segment
                var sub_it = std.mem.split(u8, line[1..], "*");
                var path = std.mem.trim(u8, sub_it.next().?, " "); // expected to be there, otherwise error

                if (std.mem.endsWith(u8, path, config.FILE_EXT_TEST)) {
                    var meta_raw = sub_it.next(); // may be null
                    var repeats: u32 = 1;
                    if (meta_raw) |meta| {
                        repeats = std.fmt.parseInt(u32, std.mem.trim(u8, meta, " "), 10) catch {
                            return 1;
                        };
                    }

                    result[seg_idx] = .{
                        .line_start = line_idx,
                        .segment_type = .TestInclude,
                        .slice = path,
                        .meta = .{
                            .TestInclude = .{
                                .repeats = repeats,
                            },
                        },
                    };
                    seg_idx += 1;
                } else if (std.mem.endsWith(u8, path, config.FILE_EXT_ENV)) {
                    result[seg_idx] = .{ .line_start = line_idx, .segment_type = .EnvInclude, .slice = path };
                    seg_idx += 1;
                }
            },
            '>' => {
                // Parse "in-filed" test
                // This parses until we find start of another known segment type
                // This chunk will later be properly validated when attempted parsed
                // Strategy: store pointer to start, iterate until end, store pointer to end, create slice from pointers
                var buf_start = @ptrToInt(buf.ptr);
                var chunk_line_start = line_idx;
                var start_idx = @ptrToInt(line.ptr) - buf_start;
                var end_idx: ?u64 = null;
                // Parse until next >, @ or eof
                chunk_blk: while (main_it.next()) |line2| {
                    line_idx += 1;
                    // Check the following line, spin until we've reached another segment
                    if (main_it.rest().len == 0) break; // EOF
                    switch (main_it.rest()[0]) {
                        '>', '@' => {
                            end_idx = @ptrToInt(&line2[line2.len - 1]) - buf_start; // line2.len-1?
                            result[seg_idx] = .{
                                .line_start = chunk_line_start,
                                .segment_type = .TestRaw,
                                .slice = buf[start_idx .. end_idx.? + 1],
                            };
                            seg_idx += 1;
                            break :chunk_blk;
                        },
                        else => {},
                    }
                }

                if (end_idx == null) {
                    // Reached end of file
                    end_idx = @ptrToInt(&buf[buf.len - 1]) - buf_start;

                    result[seg_idx] = .{
                        .line_start = chunk_line_start,
                        .segment_type = .TestRaw,
                        .slice = buf[start_idx .. end_idx.? + 1],
                    };
                    seg_idx += 1;
                }
            },
            else => {
                if (std.mem.indexOf(u8, line, "=") != null) {
                    result[seg_idx] = .{ .line_start = line_idx, .segment_type = .EnvRaw, .slice = line[0..] };
                    seg_idx += 1;
                } else {
                    // Unsupported
                    unreachable;
                }
            },
        }
    }

    return seg_idx;
}

test "parse playbook single test fileref" {
    const buf =
        \\@some/test.pi
        \\
    ;
    var segments = utils.initBoundedArray(PlaybookSegment, 128);
    try segments.resize(parsePlaybook(buf, segments.unusedCapacitySlice()));

    try testing.expectEqual(@intCast(usize, 1), segments.len);

    try testing.expectEqual(PlaybookSegmentType.TestInclude, segments.get(0).segment_type);
    try testing.expectEqualStrings("some/test.pi", segments.get(0).slice);
}

test "parse playbook test filerefs can have repeats" {
    const buf =
        \\@some/test.pi*10
        \\
    ;
    var segments = utils.initBoundedArray(PlaybookSegment, 128);
    try segments.resize(parsePlaybook(buf, segments.unusedCapacitySlice()));

    try testing.expectEqual(@intCast(usize, 1), segments.len);

    try testing.expectEqual(@intCast(usize, 10), segments.get(0).meta.TestInclude.repeats);
}

test "parse playbook fileref and envref" {
    const buf =
        \\@some/test.pi
        \\@some/.env
        \\
    ;
    var segments = utils.initBoundedArray(PlaybookSegment, 128);
    try segments.resize(parsePlaybook(buf, segments.unusedCapacitySlice()));

    try testing.expectEqual(@intCast(usize, 2), segments.len);

    try testing.expectEqual(PlaybookSegmentType.EnvInclude, segments.get(1).segment_type);
    try testing.expectEqualStrings("some/.env", segments.get(1).slice);
}

test "parse playbook single raw var" {
    const buf =
        \\MY_ENV=somevalue
        \\
    ;
    var segments = utils.initBoundedArray(PlaybookSegment, 128);
    try segments.resize(parsePlaybook(buf, segments.unusedCapacitySlice()));

    try testing.expectEqual(@intCast(usize, 1), segments.len);

    try testing.expectEqual(PlaybookSegmentType.EnvRaw, segments.get(0).segment_type);
    try testing.expectEqualStrings("MY_ENV=somevalue", segments.get(0).slice);
}

test "parse playbook raw test" {
    const buf =
        \\> GET https://my.service/api
        \\< 200
    ;
    var segments = utils.initBoundedArray(PlaybookSegment, 128);
    try segments.resize(parsePlaybook(buf, segments.unusedCapacitySlice()));

    try testing.expectEqual(@intCast(usize, 1), segments.len);

    try testing.expectEqual(PlaybookSegmentType.TestRaw, segments.get(0).segment_type);
    try testing.expectEqualStrings("> GET https://my.service/api\n< 200", segments.get(0).slice);
}

test "parse playbook two raw tests, one with extraction-expressions" {
    const buf =
        \\> GET https://my.service/api
        \\< 200
        \\> GET https://my.service/api2
        \\< 200
        \\RESPONSE=()
    ;
    var segments = utils.initBoundedArray(PlaybookSegment, 128);
    try segments.resize(parsePlaybook(buf, segments.unusedCapacitySlice()));

    try testing.expectEqual(@intCast(usize, 2), segments.len);

    try testing.expectEqual(PlaybookSegmentType.TestRaw, segments.get(0).segment_type);
    try testing.expectEqualStrings("> GET https://my.service/api\n< 200", segments.get(0).slice);
    try testing.expectEqualStrings("> GET https://my.service/api2\n< 200\nRESPONSE=()", segments.get(1).slice);
}

const buf_complex_playbook_example =
    \\# Exploration of integrated tests in playbooks
    \\# Can rely on newline+> to indicate new tests.
    \\# Can allow for a set of variables defined at top before first test as well.
    \\#     The format should allow combination of file-references as well as inline definitions
    \\# Syntax (proposal):
    \\#    Include file directive starts with @
    \\#       If file-ext matches test-file then allow for repeat-counts as well
    \\#       If file-ext matches .env then treat as envs
    \\#       If file-ext matches playbook-file then include playbook? TBD. Must avoid recursion-issues and such. Not pri. Pr now: report as error
    \\#    Included tests starts with a line with '>' and ends with a line with either '@' (new include) or new '>' (new test). Otherwise treated exactly as regular test-files. Repeat-control?
    \\#    If line not inside inline-test, and not starts with @, check for = and if match treat as variable definition
    \\#    Otherwise: syntax error
    \\#    
    \\# Load env from file
    \\@myservice/.env
    \\# Define env in-file
    \\MY_ENV=Woop
    \\
    \\# Refer to external test
    \\@generic/01-oidc-auth.pi
    \\
    \\# Refer to external test with repeats
    \\@myservice/01-getentries.pi * 50
    \\
    \\# Inline-test 1
    \\> GET https://my.service/api/health
    \\Accept: application/json
    \\Cookie: SecureToken={{oidc_token}}
    \\< 200 OK
    \\# Store entire response:
    \\EXTRACTED_ENTRY=()
    \\
    \\# Refer to external test inbetween inlines
    \\@myservice/01-getentries.pi * 50
    \\
    \\# Another inline-test
    \\> GET https://my.service/api/health
    \\Accept: application/json
    \\Cookie: SecureToken={{oidc_token}}
    \\< 200
;

test "parse super complex playbook" {
    var segments = utils.initBoundedArray(PlaybookSegment, 128);
    try segments.resize(parsePlaybook(buf_complex_playbook_example, segments.unusedCapacitySlice()));

    // for(segments.constSlice()) |segment, idx| {
    //     debug("{d}: {s}: {s}\n", .{idx, segment.segment_type, segment.slice});
    // }

    try testing.expectEqual(@intCast(usize, 7), segments.len);
    try testing.expectEqual(PlaybookSegmentType.EnvInclude, segments.get(0).segment_type);
    try testing.expectEqual(PlaybookSegmentType.EnvRaw, segments.get(1).segment_type);
    try testing.expectEqual(PlaybookSegmentType.TestInclude, segments.get(2).segment_type);
    try testing.expectEqual(PlaybookSegmentType.TestInclude, segments.get(3).segment_type);
    try testing.expectEqual(PlaybookSegmentType.TestRaw, segments.get(4).segment_type);
    try testing.expectEqual(PlaybookSegmentType.TestInclude, segments.get(5).segment_type);
    try testing.expectEqual(PlaybookSegmentType.TestRaw, segments.get(6).segment_type);
}
