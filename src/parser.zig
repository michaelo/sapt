const std = @import("std");
const debug = std.debug.print;
const testing = std.testing;

const kvstore = @import("kvstore.zig");
const io = @import("io.zig");
const config = @import("config.zig");
const utils = @import("utils.zig");
const findAllVariables = @import("parser_variables.zig").findAllVariables;
const expandVariables = @import("parser_variables.zig").expandVariables;
const expandFunctions = @import("parser_variables.zig").expandFunctions;

const getGlobalFunction = @import("parser_variables.zig").getGlobalFunction;
const expressionExtractor = @import("parser_expressions.zig").expressionExtractor;
const BracketPair = @import("parser_variables.zig").BracketPair;

const types = @import("types.zig");
const Entry = types.Entry;
const HttpMethod = types.HttpMethod;
const HttpHeader = types.HttpHeader;
const ExtractionEntry = types.ExtractionEntry;

const Console = @import("console.zig").Console;
const addUnsignedSigned = utils.addUnsignedSigned;

pub const errors = error{
    ParseError,
    InputSectionError,
    OutputSectionError,
    HeaderEntryError,
    ExtractionEntryError,
    InputPayloadError,
    InputSectionNoSuchMethodError,
    InputSectionUrlTooLongError,
    BufferTooSmall,
    NoSuchFunction,
};

pub const Parser = struct {
    const Self = @This();

    console: *const Console,

    pub fn parseError(self: *Self, comptime text: []const u8, line_no: usize, col_no: usize, buf: []const u8, line: []const u8) void {
        self.parseErrorArg(text, .{}, line_no, col_no, buf, line);
    }

    pub fn parseErrorArg(self: *Self, comptime text: []const u8, args: anytype, line_no: usize, col_no: usize, buf: []const u8, line: ?[]const u8) void {
        const console = self.console;
        _ = buf;
        _ = col_no;

        console.errorPrint(text, args);
        if (line) |line_value| {
            console.errorPrintNoPrefix("\n       Line: {d}: {s}\n", .{ line_no + 1, line_value });
        } else {
            console.errorPrintNoPrefix("\n", .{});
        }
    }

    /// data: the data to parse - all expansions etc must have been done before this.
    /// result: pre-allocated struct to popuplate with parsed data
    /// line_idx_offset: Which line_idx in the source file the data originates from. Used to 
    ///                  generate better parse errors.
    pub fn parseContents(self: *Self, data: []const u8, result: *Entry, line_idx_offset: usize) errors!void {
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
                _result.method = HttpMethod.create(lit.next().?[0..]) catch return errors.InputSectionNoSuchMethodError;
                const url = lit.next().?[0..];
                _result.url.insertSlice(0, url) catch return errors.InputSectionUrlTooLongError;
            }

            fn parseOutputSectionHeader(line: []const u8, _result: *Entry) !void {
                var lit = std.mem.split(u8, line, " ");
                _ = lit.next(); // skip <
                if (lit.next()) |http_code| {
                    _result.expected_http_code = std.fmt.parseInt(u64, http_code[0..], 10) catch return errors.OutputSectionError;
                    _result.expected_response_substring.insertSlice(0, std.mem.trim(u8, lit.rest()[0..], " ")) catch return errors.OutputSectionError;
                } else {
                    return errors.OutputSectionError;
                }
            }

            fn parseHeaderEntry(line: []const u8, _result: *Entry) !void {
                var lit = std.mem.split(u8, line, ":");
                if (lit.next()) |key| {
                    if (lit.next()) |value| {
                        _result.headers.append(try HttpHeader.create(key, value)) catch return errors.HeaderEntryError;
                    } else {
                        return error.HeaderEntryError;
                    }
                } else {
                    return error.HeaderEntryError;
                }
            }

            fn parseExtractionEntry(line: []const u8, _result: *Entry) !void {
                var lit = std.mem.split(u8, line, "=");
                if (lit.next()) |key| {
                    if (lit.next()) |value| {
                        _result.extraction_entries.append(try ExtractionEntry.create(key, value)) catch return errors.ExtractionEntryError;
                    } else {
                        return error.ExtractionEntryError;
                    }
                } else {
                    return error.ExtractionEntryError;
                }
            }

            fn parseInputPayloadLine(line: []const u8, _result: *Entry) !void {
                _result.payload.appendSlice(line) catch return errors.InputPayloadError; // .Overflow
                _result.payload.append('\n') catch return errors.InputPayloadError; // .Overflow
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
                            self.parseError("Could not parse input section header", line_idx, 0, data, line);
                            return e;
                        };
                    } else {
                        self.parseError("Expected input section header", line_idx, 0, data, line);
                        return errors.ParseError;
                    }
                },
                ParseState.InputSection => {
                    if (ParserFunctions.isEmptyLineOrComment(line)) continue;
                    if (line.len == 1 and line[0] == '-') {
                        state = ParseState.InputPayloadSection;
                        continue;
                    } else if (line[0] == '<') {
                        // Parse initial expected output section
                        state = ParseState.OutputSection;
                        ParserFunctions.parseOutputSectionHeader(line, result) catch |e| {
                            self.parseError("Could not parse output section header", line_idx, 0, data, line);
                            return e;
                        };
                        continue;
                    }

                    // Parse headers
                    ParserFunctions.parseHeaderEntry(line, result) catch |e| {
                        self.parseError("Could not parse header entry", line_idx, 0, data, line);
                        return e;
                    };
                },
                ParseState.InputPayloadSection => { // Optional section
                    if (line.len > 0 and line[0] == '<') blk: {
                        // Really ensure. We're in payload-land and have really no control of what the user would want to put in there
                        ParserFunctions.parseOutputSectionHeader(line, result) catch {
                            //parseError("Could not parse output section header", line_idx, 0, data, line);
                            //return e;
                            // Doesn't look like we've found a proper output section header. Keep parsing as payload
                            break :blk;
                        };

                        // If we get here it seems we've parsed ourself a propeper-ish output section header
                        // Check if payload has been added, and trim trailing newline
                        if (result.payload.slice().len > 0) {
                            _ = result.payload.pop();
                        }

                        // Parse initial expected output section
                        state = ParseState.OutputSection;
                        continue;
                    }

                    // Add each line verbatim to payload-buffer
                    ParserFunctions.parseInputPayloadLine(line, result) catch |e| {
                        self.parseErrorArg("Could not parse payload section - it's too big. Max payload size is {d}B", .{result.payload.capacity()}, line_idx, 0, data, line);
                        return e;
                    };
                },
                ParseState.OutputSection => {
                    if (ParserFunctions.isEmptyLineOrComment(line)) continue;

                    // Parse extraction_entries
                    ParserFunctions.parseExtractionEntry(line, result) catch |e| {
                        self.parseError("Could not parse extraction entry", line_idx, 0, data, line);
                        return e;
                    };
                },
            }
        }
    }


    test "parseContents" {
        var entry = Entry{};
        var console = Console.initNull();
        var parser = Parser {
            .console = &console,
        };

        const data =
            \\> GET https://api.warnme.no/api/status
            \\
            \\Content-Type: application/json
            \\Accept: application/json
            \\
            \\< 200   some regex here  
            \\
        ;

        try parser.parseContents(data, &entry, 0);

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
        var console = Console.initNull();
        var parser = Parser {
            .console = &console,
        };

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

        try parser.parseContents(data, &entry, 0);
        try testing.expectEqual(@intCast(usize, 1), entry.extraction_entries.slice().len);
        try testing.expectEqualStrings("myvar", entry.extraction_entries.get(0).name.slice());
        try testing.expectEqualStrings("regexwhichextractsvalue", entry.extraction_entries.get(0).expression.slice());
    }

    test "parseContents supports JSON-payloads" {
        var console = Console.initNull();
        var parser = Parser {
            .console = &console,
        };

        {
            var entry = Entry{};

            const data =
                \\> POST https://my/service
                \\-
                \\{"key":{"inner-key":[1,2,3]}}
                \\< 200
                \\
            ;

            try parser.parseContents(data, &entry, 0);
            try testing.expectEqualStrings(
                \\{"key":{"inner-key":[1,2,3]}}
                , entry.payload.constSlice());
        }
        {
            var entry = Entry{};

            const data =
                \\> POST https://my/service
                \\-
                \\{"key":
                \\
                \\     {"inner-key":
                \\   [1
                \\  ,2,3]
                \\}}
                \\< 200
                \\
            ;

            try parser.parseContents(data, &entry, 0);
            try testing.expectEqualStrings(
                \\{"key":
                \\
                \\     {"inner-key":
                \\   [1
                \\  ,2,3]
                \\}}
                , entry.payload.constSlice());
        }
    }

    test "parseContents supports XML-payloads" {
        var console = Console.initNull();
        var parser = Parser {
            .console = &console,
        };
        var entry = Entry{};

        const data =
            \\> POST https://my/service
            \\-
            \\<SOAP-ENV:Envelope
            \\  xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/"
            \\  SOAP-ENV:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            \\   <SOAP-ENV:Body>
            \\       <m:GetLastTradePrice xmlns:m="Some-URI">
            \\           <symbol>DIS</symbol>
            \\       </m:GetLastTradePrice>
            \\   </SOAP-ENV:Body>
            \\</SOAP-ENV:Envelope>
            \\< 200
            \\
        ;

        try parser.parseContents(data, &entry, 0);
        try testing.expectEqualStrings(
            \\<SOAP-ENV:Envelope
            \\  xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/"
            \\  SOAP-ENV:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            \\   <SOAP-ENV:Body>
            \\       <m:GetLastTradePrice xmlns:m="Some-URI">
            \\           <symbol>DIS</symbol>
            \\       </m:GetLastTradePrice>
            \\   </SOAP-ENV:Body>
            \\</SOAP-ENV:Envelope>
            , entry.payload.constSlice());
    }

// test "parseContents supports binary-payloads?" {
    
// }

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

    test "bug: variable-expansions fail for long values" {
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
        var s2 = kvstore.KvStore{};
        var s3 = kvstore.KvStore{};
        try s1.add("s1_var", "s1varlongervaluehere");
        try s1.add("s1_var2", "");
        try s2.add("s2_var", "");
        try s3.add("s3_var", "s3varlongervaluehere");

        var sets = [_]*kvstore.KvStore{&s1, &s2, &s3};

        try expandVariablesAndFunctions(str.buffer.len, &str, sets[0..]);

        try testing.expectEqualStrings(str_expected, str.slice());
    }

    test "parseContents ignores comments" {
        var console = Console.initNull();
        var parser = Parser {
            .console = &console,
        };
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

        try parser.parseContents(data, &entry, 0);
        try testing.expect(entry.headers.slice().len == 0);
    }

    test "parseContents shall extract payload" {
        var console = Console.initNull();
        var parser = Parser {
            .console = &console,
        };
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

        try parser.parseContents(data, &entry, 0);
        try testing.expectEqualStrings("Payload goes here\nand here", entry.payload.slice());
    }

    /////////////////////////////////
    // Playbook handling
    /////////////////////////////////
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
};

test "parse playbook single test fileref" {
    const buf =
        \\@some/test.pi
        \\
    ;
    var segments = utils.initBoundedArray(Parser.PlaybookSegment, 128);
    try segments.resize(Parser.parsePlaybook(buf, segments.unusedCapacitySlice()));

    try testing.expectEqual(@intCast(usize, 1), segments.len);

    try testing.expectEqual(Parser.PlaybookSegmentType.TestInclude, segments.get(0).segment_type);
    try testing.expectEqualStrings("some/test.pi", segments.get(0).slice);
}

test "parse playbook test filerefs can have repeats" {
    const buf =
        \\@some/test.pi*10
        \\
    ;
    var segments = utils.initBoundedArray(Parser.PlaybookSegment, 128);
    try segments.resize(Parser.parsePlaybook(buf, segments.unusedCapacitySlice()));

    try testing.expectEqual(@intCast(usize, 1), segments.len);

    try testing.expectEqual(@intCast(usize, 10), segments.get(0).meta.TestInclude.repeats);
}

test "parse playbook fileref and envref" {
    const buf =
        \\@some/test.pi
        \\@some/.env
        \\
    ;
    var segments = utils.initBoundedArray(Parser.PlaybookSegment, 128);
    try segments.resize(Parser.parsePlaybook(buf, segments.unusedCapacitySlice()));

    try testing.expectEqual(@intCast(usize, 2), segments.len);

    try testing.expectEqual(Parser.PlaybookSegmentType.EnvInclude, segments.get(1).segment_type);
    try testing.expectEqualStrings("some/.env", segments.get(1).slice);
}

test "parse playbook single raw var" {
    const buf =
        \\MY_ENV=somevalue
        \\
    ;
    var segments = utils.initBoundedArray(Parser.PlaybookSegment, 128);
    try segments.resize(Parser.parsePlaybook(buf, segments.unusedCapacitySlice()));

    try testing.expectEqual(@intCast(usize, 1), segments.len);

    try testing.expectEqual(Parser.PlaybookSegmentType.EnvRaw, segments.get(0).segment_type);
    try testing.expectEqualStrings("MY_ENV=somevalue", segments.get(0).slice);
}

test "parse playbook raw test" {
    const buf =
        \\> GET https://my.service/api
        \\< 200
    ;
    var segments = utils.initBoundedArray(Parser.PlaybookSegment, 128);
    try segments.resize(Parser.parsePlaybook(buf, segments.unusedCapacitySlice()));

    try testing.expectEqual(@intCast(usize, 1), segments.len);

    try testing.expectEqual(Parser.PlaybookSegmentType.TestRaw, segments.get(0).segment_type);
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
    var segments = utils.initBoundedArray(Parser.PlaybookSegment, 128);
    try segments.resize(Parser.parsePlaybook(buf, segments.unusedCapacitySlice()));

    try testing.expectEqual(@intCast(usize, 2), segments.len);

    try testing.expectEqual(Parser.PlaybookSegmentType.TestRaw, segments.get(0).segment_type);
    try testing.expectEqualStrings("> GET https://my.service/api\n< 200", segments.get(0).slice);
    try testing.expectEqualStrings("> GET https://my.service/api2\n< 200\nRESPONSE=()", segments.get(1).slice);
}

test "parse super complex playbook" {
    const PlaybookSegmentType = Parser.PlaybookSegmentType;
    const PlaybookSegment = Parser.PlaybookSegment;


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

    var segments = utils.initBoundedArray(PlaybookSegment, 128);
    try segments.resize(Parser.parsePlaybook(buf_complex_playbook_example, segments.unusedCapacitySlice()));

    try testing.expectEqual(@intCast(usize, 7), segments.len);
    try testing.expectEqual(PlaybookSegmentType.EnvInclude, segments.get(0).segment_type);
    try testing.expectEqual(PlaybookSegmentType.EnvRaw, segments.get(1).segment_type);
    try testing.expectEqual(PlaybookSegmentType.TestInclude, segments.get(2).segment_type);
    try testing.expectEqual(PlaybookSegmentType.TestInclude, segments.get(3).segment_type);
    try testing.expectEqual(PlaybookSegmentType.TestRaw, segments.get(4).segment_type);
    try testing.expectEqual(PlaybookSegmentType.TestInclude, segments.get(5).segment_type);
    try testing.expectEqual(PlaybookSegmentType.TestRaw, segments.get(6).segment_type);
}

/// TEST/DEBUG
fn dumpUnresolvedBracketPairsForBuffer(buf: []const u8, brackets: []const BracketPair) void {
    for (brackets) |pair, i| {
        if (pair.resolved) continue;
        debug("{d}: [{d}-{d}, {d}]: {s}\n", .{i, pair.start, pair.end, pair.depth, buf[pair.start..pair.end+1]});
    }
}
