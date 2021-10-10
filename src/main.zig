// TODO:
// * Clean up types wrt to BoundedArray-variants used for files, lists of files etc.
//   * Anything string-related; we can probably assume u8 for any custom functions at least
// * Factor out common functions, ensure sets of functions+tests are colocated
// * Determine design/strategy for handling .env-files
// * Implement some common, usable functions for expression-substition - e.g. base64-encode
// * Add test-files to stresstest the parser wrt to parse errors, overflows etc
// * Establish how to proper handle C-style strings wrt to curl-interop
// 
const std = @import("std");

// Outputters
// const info = std.log.info;
// const warn = std.log.warn;
// const emerg = std.log.emerg;
const debug = std.debug.print;

pub const log_level: std.log.Level = .debug;

const testing = std.testing;

const argparse = @import("argparse.zig");
const io = @import("io.zig");
const kvstore = @import("kvstore.zig");
const parser = @import("parser.zig");
const config = @import("config.zig");
const threadpool = @import("threadpool.zig");
const Console = @import("console.zig").Console;

const cURL = @cImport({
    @cInclude("curl/curl.h");
});

pub const errors = error {
    Ok,
    ParseError,
    TestFailed,
    TestsFailed,

    ParseErrorInputSection,
    ParseErrorOutputSection,
    ParseErrorHeaderEntry,
    ParseErrorExtractionEntry,
    ParseErrorInputPayload,

    NoSuchFunction,
    BufferTooSmall,
};

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    debug(format, args);
    std.process.exit(1); // TODO: Introduce several error codes?
}

pub const HttpMethod = enum {
    Get,
    Post,
    Put,
    Delete,
    pub fn string(self: HttpMethod) [*]const u8 {
        return switch(self) {
            HttpMethod.Get => "GET",
            HttpMethod.Post => "POST",
            HttpMethod.Put => "PUT",
            HttpMethod.Delete => "DELETE"
        };
    }
    pub fn create(raw: []const u8) !HttpMethod {
        if(std.mem.eql(u8, raw, "GET")) {
            return HttpMethod.Get;
        } else if(std.mem.eql(u8, raw, "POST")) {
            return HttpMethod.Post;
        } else if(std.mem.eql(u8, raw, "PUT")) {
            return HttpMethod.Put;
        } else if(std.mem.eql(u8, raw, "DELETE")) {
            return HttpMethod.Delete;
        } else {
            return error.NoSuchHttpMethod;
        }
    }
};

test "HttpMethod.create()" {
    try testing.expect((try HttpMethod.create("GET")) == HttpMethod.Get);
    try testing.expect((try HttpMethod.create("POST")) == HttpMethod.Post);
    try testing.expect((try HttpMethod.create("PUT")) == HttpMethod.Put);
    try testing.expect((try HttpMethod.create("DELETE")) == HttpMethod.Delete);
    try testing.expectError(error.NoSuchHttpMethod, HttpMethod.create("BLAH"));
    try testing.expectError(error.NoSuchHttpMethod, HttpMethod.create(""));
    try testing.expectError(error.NoSuchHttpMethod, HttpMethod.create(" GET"));
}

pub const HttpHeader = struct {
    const max_value_len = 8*1024;

    name: std.BoundedArray(u8,256),
    value: std.BoundedArray(u8,max_value_len),
    pub fn create(name: []const u8, value: []const u8) !HttpHeader {
        return HttpHeader {
            .name = std.BoundedArray(u8,256).fromSlice(std.mem.trim(u8, name, " ")) catch { return errors.ParseError; },
            .value = std.BoundedArray(u8,max_value_len).fromSlice(std.mem.trim(u8, value, " ")) catch { return errors.ParseError; },
        };
    }

    pub fn render(self: *HttpHeader, comptime capacity: usize, out: *std.BoundedArray(u8, capacity)) !void {
        try out.appendSlice(self.name.slice());
        try out.appendSlice(": ");
        try out.appendSlice(self.value.slice());
    }
};

test "HttpHeader.render" {
    var mybuf = initBoundedArray(u8, 2048);
    var header = try HttpHeader.create("Accept", "application/xml");
    
    try header.render(mybuf.buffer.len, &mybuf);
    try testing.expectEqualStrings("Accept: application/xml", mybuf.slice());
}


pub const ExtractionEntry = struct {
    name: std.BoundedArray(u8,256),
    expression: std.BoundedArray(u8,1024),
    pub fn create(name: []const u8, value: []const u8) !ExtractionEntry {
        return ExtractionEntry {
            .name = std.BoundedArray(u8,256).fromSlice(std.mem.trim(u8, name, " ")) catch { return errors.ParseError; },
            .expression = std.BoundedArray(u8,1024).fromSlice(std.mem.trim(u8, value, " ")) catch { return errors.ParseError; },
        };
    }
};

/// Att! This adds a terminating zero at current .slice().len TODO: Ensure there's space
fn boundedArrayAsCstr(comptime capacity: usize, array: *std.BoundedArray(u8, capacity)) [*]u8 {
    if(array.slice().len >= array.capacity()) unreachable;

    array.buffer[array.slice().len] = 0;
    return array.slice().ptr;
}

pub const Entry = struct {
    name: std.BoundedArray(u8,1024) = initBoundedArray(u8, 1024),
    method: HttpMethod = undefined,
    url: std.BoundedArray(u8,2048) = initBoundedArray(u8, 2048),
    headers: std.BoundedArray(HttpHeader,32) = initBoundedArray(HttpHeader, 32),
    payload: std.BoundedArray(u8,1024*1024) = initBoundedArray(u8, 1024*1024),
    expected_http_code: u64 = 0, // 0 == don't care
    expected_response_regex: std.BoundedArray(u8,1024) = initBoundedArray(u8, 1024),
    extraction_entries: std.BoundedArray(ExtractionEntry,32) = initBoundedArray(ExtractionEntry, 32),
    // TODO: Separate out the result? Might be useful especially for the multithread-handling
    repeats: usize = 1,
    result: struct {
        num_fails: usize = 0, // Will increase for each failed attempt, relates to "repeats"
        conclusion: bool = false,
        response_http_code: u64 = 0,
        response_match: bool = false,
        response_first_1mb: std.BoundedArray(u8,1024*1024) = initBoundedArray(u8, 1024*1024),
    } = .{},
};

pub const FilePathEntry = std.BoundedArray(u8, config.MAX_PATH_LEN);

pub const AppArguments = struct {
    //-v
    // TODO: need better control of verbosity:
    //       * Show finer details of tests being performed, envs being loaded, expression executed etc. AKA sapt-verbose
    //       * Show all i/o. AKA curl-verbose
    //       * Less important: High-fidelity details to help debugging during development
    verbose: bool = false,
    //-d
    show_response_data: bool = false,
    //-r
    recursive: bool = false,
    //-m allows for concurrent requests for repeated tests
    multithreaded: bool = false,
    //-i=<file>
    input_vars_file: std.BoundedArray(u8,config.MAX_PATH_LEN) = initBoundedArray(u8, config.MAX_PATH_LEN),
    //-o=<file>
    output_file: std.BoundedArray(u8,config.MAX_PATH_LEN) = initBoundedArray(u8, config.MAX_PATH_LEN),
    //-f=<file>
    playbook_file: std.BoundedArray(u8,config.MAX_PATH_LEN) = initBoundedArray(u8, config.MAX_PATH_LEN),
    //-s
    silent: bool = false,
    // ...
    files: std.BoundedArray(FilePathEntry,128) = initBoundedArray(FilePathEntry, 128),
};

fn writeToArrayListCallback(data: *c_void, size: c_uint, nmemb: c_uint, user_data: *c_void) callconv(.C) c_uint {
    var buffer = @intToPtr(*std.ArrayList(u8), @ptrToInt(user_data));
    var typed_data = @intToPtr([*]u8, @ptrToInt(data));
    buffer.appendSlice(typed_data[0 .. nmemb * size]) catch return 0;
    return nmemb * size;
}

/// Primary worker function performing the request and handling the response
/// TODO: Factor out a pure cURL-handler?
fn processEntry(entry: *Entry, args: AppArguments) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    var allocator = &arena_state.allocator;

    //////////////////////////////
    // Init / generic setup
    //////////////////////////////
    const handle = cURL.curl_easy_init() orelse return error.CURLHandleInitFailed;
    defer cURL.curl_easy_cleanup(handle);

    // TODO: Shall we get rid of heap? Can use the 1MB-buffer in the entry directly...
    var response_buffer = std.ArrayList(u8).init(allocator);
    defer response_buffer.deinit();

    ///////////////////////
    // Setup curl options
    ///////////////////////

    // Set HTTP method
    if(cURL.curl_easy_setopt(handle, cURL.CURLOPT_CUSTOMREQUEST, entry.method.string()) != cURL.CURLE_OK)
        return error.CouldNotSetRequestMethod;

    // Set URL
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_URL, boundedArrayAsCstr(entry.url.buffer.len, &entry.url)) != cURL.CURLE_OK)
        return error.CouldNotSetURL;

    // Set Payload (if given)
    if(entry.method == .Post or entry.method == .Put or entry.payload.slice().len > 0) {
        if(cURL.curl_easy_setopt(handle, cURL.CURLOPT_POSTFIELDSIZE, entry.payload.slice().len) != cURL.CURLE_OK)
            return error.CouldNotSetPostDataSize;
        if(cURL.curl_easy_setopt(handle, cURL.CURLOPT_POSTFIELDS, boundedArrayAsCstr(entry.payload.buffer.len, &entry.payload)) != cURL.CURLE_OK)
            return error.CouldNotSetPostData;
    }

    // Debug
    if(args.verbose) {
        if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_VERBOSE, @intCast(c_long, 1)) != cURL.CURLE_OK)
            return error.CouldNotSetVerbose;
    }

    // Pass headers
    var list: ?*cURL.curl_slist = null;
    defer cURL.curl_slist_free_all(list);
    
    var header_buf = initBoundedArray(u8, HttpHeader.max_value_len);
    for(entry.headers.slice()) |*header| {
        try header_buf.resize(0);
        try header.render(header_buf.buffer.len, &header_buf);
        list = cURL.curl_slist_append(list, boundedArrayAsCstr(header_buf.buffer.len, &header_buf));
    }
    
    if(cURL.curl_easy_setopt(handle, cURL.CURLOPT_HTTPHEADER, list) != cURL.CURLE_OK)
        return error.CouldNotSetHeaders;

    //////////////////////
    // Execute
    //////////////////////
    // set write function callbacks
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_WRITEFUNCTION, writeToArrayListCallback) != cURL.CURLE_OK)
        return error.CouldNotSetWriteCallback;
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_WRITEDATA, &response_buffer) != cURL.CURLE_OK)
        return error.CouldNotSetWriteCallback;


    // Perform
    if (cURL.curl_easy_perform(handle) != cURL.CURLE_OK)
        return error.FailedToPerformRequest;

    ////////////////////////
    // Handle results
    ////////////////////////
    var http_code: u64 = 0;
    if(cURL.curl_easy_getinfo(handle, cURL.CURLINFO_RESPONSE_CODE, &http_code) != cURL.CURLE_OK)
        return error.CouldNewGetResponseCode;

    entry.result.response_http_code = http_code;

    try entry.result.response_first_1mb.resize(0);
    try entry.result.response_first_1mb.appendSlice(sliceUpTo(u8, response_buffer.items, 0, entry.result.response_first_1mb.capacity()));
}

// TODO: Rename to better communicate intent, or provide a better response than bool
fn isEntrySuccessful(entry: *Entry) bool {
    if(entry.expected_response_regex.constSlice().len > 0 and std.mem.indexOf(u8, entry.result.response_first_1mb.constSlice(), entry.expected_response_regex.constSlice()) == null) {
        entry.result.response_match = false;
        return false;
    }
    entry.result.response_match = true;

    if(entry.expected_http_code != 0 and entry.expected_http_code != entry.result.response_http_code) return false;

    return true;
}

/// UTILITY: Returns a slice from <from> up to <to> or slice.len
fn sliceUpTo(comptime T: type, slice: []T, from: usize, to: usize) []T {
    return slice[from..std.math.min(slice.len, to)];
}

const ProcessStatistics = struct {
    time_total: i64 = 0,
    time_min: i64 = undefined,
    time_max: i64 = undefined,
    time_avg: i64 = undefined,
};

// Process entry and evaluate results. Returns error-type in case of either parse error, process error or evaluation error
fn processEntryMain(entry: *Entry, args: AppArguments, buf: []const u8, repeats: u32, stats: *ProcessStatistics) !void {
    try parser.parseContents(buf, entry);

    // TODO: Refactor this to better unify the different call-methods: stats, no stats (remove the possibility?), and multithreaded
    stats.time_max = 0;
    stats.time_min = std.math.maxInt(i64);
    if(args.multithreaded and repeats > 1) {
        debug("Starting multithreaded test ({d} threads working total {d} requests)\n", .{try std.Thread.getCpuCount(), repeats});

        // We start naively, by sharing data, although it's not high-performance optimal, but
        // it's a starting point from which we can improve once we've identifed all pitfalls 
        const Payload = struct {
            const Self = @This();
            // TODO: Add mutexes
            stats: *ProcessStatistics,
            entry: *Entry,
            args: *const AppArguments,

            pub fn worker(self: *Self) void {
                var entry_time_start = std.time.milliTimestamp();
                processEntry(self.entry, self.args.*) catch {};
                if(!isEntrySuccessful(self.entry)) {
                    self.entry.result.num_fails += 1;
                    self.entry.result.conclusion = false;
                } else {
                    self.entry.result.conclusion = true;
                }
                var entry_time = std.time.milliTimestamp() - entry_time_start;
                self.stats.time_max = std.math.max(entry_time, self.stats.time_max);
                self.stats.time_min = std.math.min(entry_time, self.stats.time_min);
                self.stats.time_total += entry_time;
            }
        };

        // Setup and execute pool
        // const coreCount = try std.Thread.getCpuCount();
        var pool = threadpool.ThreadPool(Payload, 1000, Payload.worker).init(try std.Thread.getCpuCount());
        var i: usize=0;
        while(i<repeats) : (i += 1) {
            try pool.addWork(Payload{
                .stats = stats,
                .entry = entry,
                .args = &args,
            });
        }

        try pool.startAndJoin(); // Can fail if unable to spawn thread
        // Evaluate results?
    } else {
        const time_total_start = std.time.milliTimestamp();

        var i: usize=0;
        while(i<repeats) : (i += 1) {
            var entry_time_start = std.time.milliTimestamp();
            try processEntry(entry, args);
            if(!isEntrySuccessful(entry)) {
                entry.result.num_fails += 1;
                entry.result.conclusion = false;
            } else {
                entry.result.conclusion = true;
            }
            var entry_time = std.time.milliTimestamp() - entry_time_start;
            stats.time_max = std.math.max(entry_time, stats.time_max);
            stats.time_min = std.math.min(entry_time, stats.time_min);
        }
        stats.time_total = std.time.milliTimestamp() - time_total_start;

    }

    stats.time_avg = @divTrunc(stats.time_total, @intCast(i64, repeats));
}

fn extractExtractionEntries(entry: Entry, store: *kvstore.KvStore) !void {
        // Extract to variables
    for(entry.extraction_entries.constSlice()) |v| {
        if(parser.expressionExtractor(entry.result.response_first_1mb.constSlice(), v.expression.constSlice())) |expression_result| {
            // Got match
            try store.add(v.name.constSlice(), expression_result.result);
        } else {
            Console.red("Could not find match for '{s}={s}'\n", .{v.name.constSlice(), v.expression.constSlice()});
            return error.UnableToExtractExtractionEntry;
        }
    }
}

/// Main do'er to do anything related to orchestrating the execution of the entry, repeats and outputting the results
/// Common to both regular flow (entries as arguments) and playbooks
fn processAndEvaluateEntryFromBuf(idx: u64, total: u64, entry_name: []const u8, entry_buf: []const u8, args: AppArguments, input_vars:*kvstore.KvStore, extracted_vars: *kvstore.KvStore, repeats: u32) !void {
    var entry: Entry = .{};
    _ = input_vars;
    entry.repeats = repeats;

    // Do
    var stats: ProcessStatistics = .{};
    processEntryMain(&entry, args, entry_buf, repeats, &stats) catch |err| {
        // TODO: Switch the errors and give helpful output
        Console.red("{d}/{d}: {s:<64}            : Process error {s}\n", .{idx, total, entry_name, err});
        return error.CouldNotProcessEntry;
    };

    var conclusion = entry.result.conclusion;
    // Evaluate results
    // var result_string = if(conclusion) "OK" else "ERROR";

    // Output neat and tidy output, respectiong args .silent, .data and .verbose
    if (conclusion) { // Success
        Console.green("{d}/{d}: {s:<64}            : OK (HTTP {d} - {s})\n", .{idx, total, entry_name, entry.result.response_http_code, httpCodeToString(entry.result.response_http_code)});

        if(repeats == 1) {
            Console.grey("  time: {}ms\n", .{stats.time_total});
        } else {
            Console.grey("  {} iterations. {} OK, {} Error\n", .{repeats, repeats - entry.result.num_fails, entry.result.num_fails});
            Console.grey("  time: {}ms/{} iterations [{}ms-{}ms] avg:{}ms\n", .{stats.time_total, repeats, stats.time_min, stats.time_max, stats.time_avg});
        }

    } else { // Errors
        Console.red("{d}/{d}: {s:<64}            : ERROR (HTTP {d} - {s})\n", .{idx, total, entry_name, entry.result.response_http_code, httpCodeToString(entry.result.response_http_code)});

        if(repeats == 1) {
            Console.grey("  {} iterations. {} OK, {} Error\n", .{repeats, repeats - entry.result.num_fails, entry.result.num_fails});
            Console.grey("  time: {}ms\n", .{stats.time_total});
        } else {
            Console.grey("  time: {}ms/{} iterations [{}ms-{}ms] avg:{}ms\n", .{stats.time_total, repeats, stats.time_min, stats.time_max, stats.time_avg});
        }

    }

    if (conclusion) {
        // No need to extract if not successful
        // TODO: Is failure to extract an failure to the test? I'd say yes.
        try extractExtractionEntries(entry, extracted_vars);

        // Print all stored variables
        if(args.verbose and extracted_vars.store.slice().len > 0) {
            debug("Values extracted from response:\n", .{});
            debug("-"**80 ++ "\n", .{});
            for(extracted_vars.store.slice()) |v| {
                debug("* {s}={s}\n", .{v.key.constSlice(), v.value.constSlice()});
            }
            debug("-"**80 ++ "\n", .{});
        }
    } else {
        // num_failed += 1;
        Console.plain("{s} {s:<64}\n", .{entry.method, entry.url.slice()});
        if(entry.result.response_http_code != entry.expected_http_code) {
            Console.red("Fault: Expected HTTP '{d} - {s}', got '{d} - {s}'\n", .{entry.expected_http_code, httpCodeToString(entry.expected_http_code), entry.result.response_http_code, httpCodeToString(entry.result.response_http_code)});
        }

        if(!entry.result.response_match) {
            Console.red("Fault: Match requirement '{s}' was not successful\n", .{entry.expected_response_regex.constSlice()});
        }
    }

    if(!conclusion or args.verbose or args.show_response_data) {
        Console.bold("Response (up to 1024KB):\n", .{});
        debug("{s}\n\n", .{sliceUpTo(u8, entry.result.response_first_1mb.slice(), 0, 1024*1024)});
    }

    if(!conclusion) return error.TestFailed;
}

fn getNumOfSegmentType(segments: []const parser.PlaybookSegment, segment_type: parser.PlaybookSegmentType) u64 {
    var result: u64 = 0;
    for(segments) |segment| {
        if(segment.segment_type == segment_type) result += 1;
    }
    return result;
}

fn processPlaybook(playbook_path: []const u8, args: AppArguments, input_vars:*kvstore.KvStore, extracted_vars: *kvstore.KvStore) !void {
    // Load playbook
    var buf = initBoundedArray(u8, 1024*1024);

    io.readFile(u8, buf.buffer.len, playbook_path, &buf) catch {
        debug("ERROR: Could not read playbook file: {s}\n", .{playbook_path});
        return error.ParseError;
    };

    var segments = initBoundedArray(parser.PlaybookSegment, 128);
    try segments.resize(parser.parsePlaybook(buf.constSlice(), segments.unusedCapacitySlice()));


    // Iterate over playbook and act according to each type
    var num_failed: u64 = 0;
    var num_processed: u64 = 0;
    var total_num_tests = getNumOfSegmentType(segments.constSlice(), .TestInclude) + getNumOfSegmentType(segments.constSlice(), .TestRaw);
    const time_start = std.time.milliTimestamp();
    // Pass through each item and process according to type
    for(segments.constSlice()) |segment| {
        try buf.resize(0);

        switch(segment.segment_type) {
            .Unknown => { unreachable; },
            .TestInclude, .TestRaw => {
                num_processed += 1;
                var name_buf: [128]u8 = undefined;
                var name_slice: []u8 = undefined;
                var repeats: u32 = 1;

                // TODO: Store either name of file, or line-ref to playbook to ID test in output
                if(segment.segment_type == .TestInclude) {
                    // TODO: how to limit max length? will 128<s pad the result?
                    name_slice = std.fmt.bufPrint(&name_buf, "{s}", .{segment.slice}) catch { unreachable; };
                    repeats = segment.meta.TestInclude.repeats;
                    // debug("Processing: {s}\n", .{segment.slice});
                    // Load from file and parse
                    io.readFile(u8, buf.buffer.len, segment.slice, &buf) catch {
                        debug("ERROR: Could not read file: {s}\n", .{segment.slice});
                        num_failed += 1;
                        continue;
                    };
                } else {
                    // debug("Processing: {s}\n", .{"inline test"});
                    // Test raw
                    name_slice = std.fmt.bufPrint(&name_buf, "Inline segment at line: {d}", .{segment.line_start}) catch { unreachable; };
                    try buf.appendSlice(segment.slice);

                }
                parser.expandVariablesAndFunctions(buf.buffer.len, &buf, extracted_vars) catch {};
                parser.expandVariablesAndFunctions(buf.buffer.len, &buf, input_vars) catch {};

                if(processAndEvaluateEntryFromBuf(num_processed, total_num_tests, name_slice, buf.constSlice(), args, input_vars, extracted_vars, repeats)) {
                    // OK
                } else |_| {
                    // debug("Got error: {s}\n", .{err});
                    num_failed += 1;
                }

            },
            .EnvInclude => {
                // Load from file and parse
                if(args.verbose) debug("Loading env-file: '{s}'\n", .{segment.slice});
                try input_vars.addFromOther((try envFileToKvStore(segment.slice)), .Fail);
            },
            .EnvRaw => {
                // Parse key=value directly
                if(args.verbose) debug("Loading in-file env at line {d}\n", .{segment.line_start});
                try input_vars.addFromBuffer(segment.slice);
            }
        }
        // debug("{d}: {s}: {s}\n", .{idx, segment.segment_type, segment.slice});
    }

    debug(
        \\------------------
        \\{d}/{d} OK
        \\------------------
        \\FINISHED - total time: {d}s
        \\
        , .{num_processed-num_failed, num_processed, @intToFloat(f64, std.time.milliTimestamp()-time_start)/1000}
    );

}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer arena.deinit();
    const aa = &arena.allocator;

    const args = try std.process.argsAlloc(aa);
    defer std.process.argsFree(aa, args);

    if(args.len == 1) {
        argparse.printHelp(false);
        std.process.exit(0);
    }

    mainInner(args[1..]) catch |e| {
        fatal("Exited due to failure ({s})\n", .{e});
    };
}

pub fn mainInner(args: [][]u8) anyerror!void {
    var buf = initBoundedArray(u8, 1024*1024);

    if (cURL.curl_global_init(cURL.CURL_GLOBAL_ALL) != cURL.CURLE_OK)
        return error.CURLGlobalInitFailed;
    defer cURL.curl_global_cleanup();

    // TODO: Filter input-set first, to get the proper number of items? Or at least count them up

    var parsed_args = argparse.parseArgs(args) catch |e| switch(e) {
        error.ShowHelp => { argparse.printHelp(true); return; },
        else => { debug("Invalid arguments.\n" ,.{}); argparse.printHelp(true); fatal("Exiting.", .{}); }
    };

    argparse.processInputFileArguments(parsed_args.files.buffer.len, &parsed_args.files) catch |e| {
        fatal("Could not process input file arguments: {s}\n", .{e});
    };

    var input_vars = kvstore.KvStore{};
    if(parsed_args.input_vars_file.constSlice().len > 0) {
        if(parsed_args.verbose) debug("Attempting to read input variables from: {s}\n", .{parsed_args.input_vars_file.constSlice()});
        // TODO: expand variables within envfiles? This to e.g. allow env-files to refer to OS ENV. Any proper use case?
        input_vars = try envFileToKvStore(parsed_args.input_vars_file.constSlice());
    }

    var num_processed: u64 = 0;
    var num_failed: u64 = 0;
    var extracted_vars: kvstore.KvStore = .{};
    if(parsed_args.playbook_file.constSlice().len > 0) {
        try processPlaybook(parsed_args.playbook_file.constSlice(), parsed_args, &input_vars, &extracted_vars);
    } else {
        const time_start = std.time.milliTimestamp();

        for (parsed_args.files.slice()) |file| {
            if(!std.mem.endsWith(u8, file.constSlice(), config.CONFIG_FILE_EXT_TEST)) continue;
            
            num_processed += 1;

            //////////////////
            // Process
            //////////////////
            io.readFile(u8, buf.buffer.len, file.constSlice(), &buf) catch {
                debug("ERROR: Could not read file: {s}\n", .{file.constSlice()});
                num_failed += 1;
                continue;
            };

            // Expand all variables
            parser.expandVariablesAndFunctions(buf.buffer.len, &buf, &extracted_vars) catch {};
            parser.expandVariablesAndFunctions(buf.buffer.len, &buf, &input_vars) catch {};

            if(processAndEvaluateEntryFromBuf(num_processed, parsed_args.files.slice().len, file.constSlice(), buf.constSlice(), parsed_args, &input_vars, &extracted_vars, 1)) {
                // OK
            } else |err| {
                debug("Got error: {s}\n", .{err});
                num_failed += 1;
            }
        }
        debug(
            \\------------------
            \\{d}/{d} OK
            \\------------------
            \\FINISHED - total time: {d}s
            \\
            , .{num_processed-num_failed, num_processed, @intToFloat(f64, std.time.milliTimestamp()-time_start)/1000}
        );

    }
}

pub fn envFileToKvStore(path: []const u8) !kvstore.KvStore {
    var tmpbuf: [1024*1024]u8 = undefined;
    var buf_len = io.readFileRaw(path, &tmpbuf) catch {
        return error.CouldNotReadFile;
    };

    return try kvstore.KvStore.fromBuffer(tmpbuf[0..buf_len]);
}

test "envFileToKvStore" {
    var store = try envFileToKvStore("testdata/env");
    try testing.expect(store.count() == 2);
    try testing.expectEqualStrings("value", store.get("key").?);
    try testing.expectEqualStrings("dabba", store.get("abba").?);
}

// Convenience-function to initiate a bounded-array without inital size of 0, removing the error-case brough by .init(size)
pub fn initBoundedArray(comptime T: type, comptime capacity: usize) std.BoundedArray(T,capacity) {
    return std.BoundedArray(T, capacity){.buffer=undefined};
}

fn httpCodeToString(code: u64) []const u8 {
    return switch(code) {
        100 => "Continue",
        101 => "Switching protocols",
        102 => "Processing",
        103 => "Early Hints",

        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        203 => "Non-Authoritative Information",
        204 => "No Content",
        205 => "Reset Content",
        206 => "Partial Content",
        207 => "Multi-Status",
        208 => "Already Reported",
        226 => "IM Used",

        300 => "Multiple Choices",
        301 => "Moved Permanently",
        302 => "Found (Previously \"Moved Temporarily\")",
        303 => "See Other",
        304 => "Not Modified",
        305 => "Use Proxy",
        306 => "Switch Proxy",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",

        400 => "Bad Request",
        401 => "Unauthorized",
        402 => "Payment Required",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        407 => "Proxy Authentication Required",
        408 => "Request Timeout",
        409 => "Conflict",
        410 => "Gone",
        411 => "Length Required",
        412 => "Precondition Failed",
        413 => "Payload Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        416 => "Range Not Satisfiable",
        417 => "Expectation Failed",
        418 => "I'm a Teapot",
        421 => "Misdirected Request",
        422 => "Unprocessable Entity",
        423 => "Locked",
        424 => "Failed Dependency",
        425 => "Too Early",
        426 => "Upgrade Required",
        428 => "Precondition Required",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        451 => "Unavailable For Legal Reasons",

        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        505 => "HTTP Version Not Supported",
        506 => "Variant Also Negotiates",
        507 => "Insufficient Storage",
        508 => "Loop Detected",
        510 => "Not Extended",
        511 => "Network Authentication Required",
        else => "", // TBD: fail, return empty, or e.g. "UNKNOWN HTTP CODE"?
    };
}