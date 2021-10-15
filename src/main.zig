// TODO:
// * Clean up types wrt to BoundedArray-variants used for files, lists of files etc.
//   * Anything string-related; we can probably assume u8 for any custom functions at least
// * Determine design/strategy for handling .env-files
// * Establish how to proper handle C-style strings wrt to curl-interop
// 
const std = @import("std");
const fs = std.fs;

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
const utils = @import("utils.zig");
const httpclient = @import("httpclient.zig");
const pretty = @import("pretty.zig");

const Console = @import("console.zig").Console;

const types = @import("types.zig");
const HttpMethod = types.HttpMethod;
const HttpHeader = types.HttpHeader;
const ExtractionEntry = types.ExtractionEntry;

const initBoundedArray = utils.initBoundedArray;

pub const errors = error {
    Ok,
    ParseError,
    TestFailed,
    TestsFailed,

    // TODO: Make parse errors specific by parser.zig?
    ParseErrorInputSection,
    ParseErrorOutputSection,
    ParseErrorHeaderEntry,
    ParseErrorExtractionEntry,
    ParseErrorInputPayload,
    ParseErrorInputSectionNoSuchMethod,
    ParseErrorInputSectionUrlTooLong,

    NoSuchFunction,
    BufferTooSmall,
};

const ExitCode = enum(u8) {
    Ok = 0,
    ProcessError = 1,
    TestsFailed = 2,
};

pub fn exit(code: ExitCode) noreturn {
    std.process.exit(@enumToInt(code));
}

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    debug(format, args);
    exit(.ProcessError);
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
    repeats: usize = 1,
};

// TODO: Split what is return-data from the processEntry vs what's aggregated results outside?
pub const EntryResult = struct {
    num_fails: usize = 0, // Will increase for each failed attempt, relates to "repeats"
    conclusion: bool = false,
    response_content_type: std.BoundedArray(u8,HttpHeader.MAX_VALUE_LEN) = initBoundedArray(u8, HttpHeader.MAX_VALUE_LEN),
    response_http_code: u64 = 0,
    response_match: bool = false,
    // TODO: Fetch response-length in case it's >1MB?
    response_first_1mb: std.BoundedArray(u8,1024*1024) = initBoundedArray(u8, 1024*1024),
};

const ProcessStatistics = struct {
    time_total: i64 = 0,
    time_min: i64 = undefined,
    time_max: i64 = undefined,
    time_avg: i64 = undefined,
};

const TestContext = struct {
    entry: Entry = .{},
    result: EntryResult = .{}
};

const ExecutionStats = struct {
    num_tests: u64 = 0,
    num_success: u64 = 0,
    num_fail: u64 = 0,
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
    show_pretty_response_data: bool = false,
    //TODO: --pretty - try to print the response-data in a formatted way based on Content-Type
    //-v=curl, -v=debug, -v=data  -- -v=data == -d, 
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


fn isEntrySuccessful(entry: *Entry, result: *EntryResult) bool {
    if(entry.expected_response_regex.constSlice().len > 0 and std.mem.indexOf(u8, result.response_first_1mb.constSlice(), entry.expected_response_regex.constSlice()) == null) {
        result.response_match = false;
        return false;
    }
    result.response_match = true;

    if(entry.expected_http_code != 0 and entry.expected_http_code != result.response_http_code) return false;

    return true;
}

// Process entry and evaluate results. Returns error-type in case of either parse error, process error or evaluation error
fn processEntryMain(test_context: *TestContext, args: AppArguments, buf: []const u8, repeats: u32, stats: *ProcessStatistics, line_idx_offset: usize) !void {
    var entry: *Entry = &test_context.entry;
    var result: *EntryResult = &test_context.result;

    try parser.parseContents(buf, entry, line_idx_offset);

    // TODO: Refactor this to better unify the different call-methods/variants
    stats.time_max = 0;
    stats.time_min = std.math.maxInt(i64);

    if(args.multithreaded and repeats > 1) {
        if(args.verbose) debug("Starting multithreaded test ({d} threads working total {d} requests)\n", .{try std.Thread.getCpuCount(), repeats});

        // We start naively, by sharing data, although it's not high-performance optimal, but
        // it's a starting point from which we can improve once we've identifed all pitfalls 
        const Payload = struct {
            const Self = @This();
            // TODO: Add mutexes
            stats: *ProcessStatistics,
            entry: *Entry,
            result: *EntryResult,
            args: *const AppArguments,

            pub fn worker(self: *Self) void {
                var entry_time_start = std.time.milliTimestamp();
                if(httpclient.processEntry(self.entry, self.args.*, self.result)) {
                    if(!isEntrySuccessful(self.entry, self.result)) {
                        self.result.num_fails += 1;
                        self.result.conclusion = false;
                    } else {
                        self.result.conclusion = true;
                    }
                } else |_| {
                    // Error
                    self.result.num_fails += 1;
                    self.result.conclusion = false;
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
                .result = result,
            });
        }

        try pool.startAndJoin(); // Can fail if unable to spawn thread, but then we are in trouble anyways
        // Evaluate results?
    } else {
        if(args.verbose) debug("Starting singlethreaded test ({d} requests)\n", .{repeats});
        const time_total_start = std.time.milliTimestamp();

        var i: usize=0;
        while(i<repeats) : (i += 1) {
            var entry_time_start = std.time.milliTimestamp();
            if(httpclient.processEntry(entry, args, result)) {
                // debug("Content-Type: {s}\n", .{result.response_content_type.slice()});
                if(!isEntrySuccessful(entry, result)) {
                    result.num_fails += 1;
                    result.conclusion = false;
                } else {
                    result.conclusion = true;
                }
            } else |_| {
                // Error
                result.num_fails += 1;
                result.conclusion = false;
            }
            var entry_time = std.time.milliTimestamp() - entry_time_start;
            stats.time_max = std.math.max(entry_time, stats.time_max);
            stats.time_min = std.math.min(entry_time, stats.time_min);
        }
        stats.time_total = std.time.milliTimestamp() - time_total_start;

    }

    stats.time_avg = @divTrunc(stats.time_total, @intCast(i64, repeats));
}

fn extractExtractionEntries(entry: Entry, result: EntryResult, store: *kvstore.KvStore) !void {
        // Extract to variables
    for(entry.extraction_entries.constSlice()) |v| {
        if(parser.expressionExtractor(result.response_first_1mb.constSlice(), v.expression.constSlice())) |expression_result| {
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
fn processAndEvaluateEntryFromBuf(test_context: *TestContext, idx: u64, total: u64, entry_name: []const u8, entry_buf: []const u8, args: AppArguments, input_vars:*kvstore.KvStore, extracted_vars: *kvstore.KvStore, repeats: u32, line_idx_offset: usize) !void {
    test_context.* = .{}; // Reset
    _ = input_vars;
    test_context.entry.repeats = repeats;

    // Do
    var stats: ProcessStatistics = .{};
    if(args.verbose) debug("Processing entry: {s}\n", .{entry_name});
    
    processEntryMain(test_context, args, entry_buf, repeats, &stats, line_idx_offset) catch |err| {
        // TODO: Switch the errors and give helpful output
        Console.red("{d}/{d}: {s:<64}            : Process error {s}\n", .{idx, total, entry_name, err});
        return error.CouldNotProcessEntry;
    };

    var conclusion = test_context.result.conclusion;
    // Evaluate results

    // Output neat and tidy output, respectiong args .silent, .data and .verbose
    if (conclusion) { // Success
        Console.green("{d}/{d}: {s:<64}            : OK (HTTP {d} - {s})\n", .{idx, total, entry_name, test_context.result.response_http_code, httpclient.httpCodeToString(test_context.result.response_http_code)});
    } else { // Errors
        Console.red("{d}/{d}: {s:<64}            : ERROR (HTTP {d} - {s})\n", .{idx, total, entry_name, test_context.result.response_http_code, httpclient.httpCodeToString(test_context.result.response_http_code)});
    }

    // Stats
    if(repeats == 1) {
        Console.grey("  time: {}ms\n", .{stats.time_total});
    } else {
        Console.grey("  {} iterations. {} OK, {} Error\n", .{repeats, repeats - test_context.result.num_fails, test_context.result.num_fails});
        Console.grey("  time: {}ms/{} iterations [{}ms-{}ms] avg:{}ms\n", .{stats.time_total, repeats, stats.time_min, stats.time_max, stats.time_avg});
    }

    if (conclusion) {
        // No need to extract if not successful
        // TODO: Is failure to extract an failure to the test? I'd say yes.
        try extractExtractionEntries(test_context.entry, test_context.result, extracted_vars);

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
        Console.plain("{s} {s:<64}\n", .{test_context.entry.method, test_context.entry.url.slice()});
        if(test_context.result.response_http_code != test_context.entry.expected_http_code) {
            Console.red("Fault: Expected HTTP '{d} - {s}', got '{d} - {s}'\n", .{test_context.entry.expected_http_code, httpclient.httpCodeToString(test_context.entry.expected_http_code), test_context.result.response_http_code, httpclient.httpCodeToString(test_context.result.response_http_code)});
        }

        if(!test_context.result.response_match) {
            Console.red("Fault: Match requirement '{s}' was not successful\n", .{test_context.entry.expected_response_regex.constSlice()});
        }
    }

    if(!conclusion or args.verbose or args.show_response_data) {
        Console.bold("Response (up to 1024KB):\n", .{});
        // TODO: pretty-print based on response Content-Type
        if(!args.show_pretty_response_data) {
            debug("{s}\n\n", .{utils.sliceUpTo(u8, test_context.result.response_first_1mb.slice(), 0, 1024*1024)});
        } else {
            try pretty.getPrettyPrinterByContentType(test_context.result.response_content_type.slice())(std.io.getStdOut().writer(), test_context.result.response_first_1mb.slice());
        }
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

fn processPlaybook(test_context: *TestContext, playbook_path: []const u8, args: AppArguments, input_vars:*kvstore.KvStore, extracted_vars: *kvstore.KvStore) !ExecutionStats {
    // Load playbook
    // var scrap: [4*1024]u8 = undefined;
    var buf_playbook = initBoundedArray(u8, 1024*1024); // Att: this must be kept as it is used to look up data from for the segments
    var buf_test = initBoundedArray(u8, 1024*1024);

    io.readFile(u8, buf_playbook.buffer.len, playbook_path, &buf_playbook) catch {
        Console.red("ERROR: Could not read playbook file: {s}\n", .{playbook_path});
        return error.CouldNotReadFile;
    };

    var segments = initBoundedArray(parser.PlaybookSegment, 128);
    try segments.resize(parser.parsePlaybook(buf_playbook.constSlice(), segments.unusedCapacitySlice()));

    // Playbooks shall resolve file-includes relative to self
    var original_cwd = fs.cwd();
    var playbook_basedir = try original_cwd.openDir(io.getParent(playbook_path), .{});

    // Iterate over playbook and act according to each type
    var num_failed: u64 = 0;
    var num_processed: u64 = 0;
    var total_num_tests = getNumOfSegmentType(segments.constSlice(), .TestInclude) + getNumOfSegmentType(segments.constSlice(), .TestRaw);
    const time_start = std.time.milliTimestamp();
    // Pass through each item and process according to type
    for(segments.constSlice()) |segment| {
        try buf_test.resize(0);
        if(args.verbose) debug("Processing segment type: {s}, line: {d}\n", .{segment.segment_type, segment.line_start});

        switch(segment.segment_type) {
            .Unknown => { unreachable; },
            .TestInclude, .TestRaw => {
                // We got a test.
                // For file-based tests: read the file to a buffer
                // For in-playbook tests: copy the contents to buffer
                // - then from that point on: unified processing
                num_processed += 1;
                var name_buf: [128]u8 = undefined;
                var name_slice: []u8 = undefined;
                var repeats: u32 = 1;

                if(segment.segment_type == .TestInclude) {
                    // TODO: how to limit max length? will 128<s pad the result?
                    name_slice = try std.fmt.bufPrint(&name_buf, "{s}", .{utils.constSliceUpTo(u8, segment.slice, 0, name_buf.len)});
                    repeats = segment.meta.TestInclude.repeats;
                    if(args.verbose) debug("Processing: {s}\n", .{segment.slice});
                    // Load from file and parse
                    io.readFileRel(u8, buf_test.buffer.len, playbook_basedir, segment.slice, &buf_test) catch {
                        parser.parseErrorArg("Could not read file", .{}, segment.line_start, 0, buf_test.constSlice(), segment.slice);
                        num_failed += 1;
                        continue;
                    };
                } else {
                    // debug("Processing: {s}\n", .{"inline test"});
                    // Test raw
                    name_slice = try std.fmt.bufPrint(&name_buf, "Inline segment starting at line: {d}", .{segment.line_start});
                    try buf_test.appendSlice(segment.slice);
                }

                // Expand variables
                parser.expandVariablesAndFunctions(buf_test.buffer.len, &buf_test, extracted_vars) catch {};
                parser.expandVariablesAndFunctions(buf_test.buffer.len, &buf_test, input_vars) catch {};

                // Execute the test
                if(processAndEvaluateEntryFromBuf(test_context, num_processed, total_num_tests, name_slice, buf_test.constSlice(), args, input_vars, extracted_vars, repeats, segment.line_start)) {
                    // OK
                } else |_| {
                    num_failed += 1;
                }

            },
            .EnvInclude => {
                // Load from file and parse
                if(args.verbose) debug("Loading env-file: '{s}'\n", .{segment.slice});
                try input_vars.addFromOther((try envFileToKvStore(playbook_basedir, segment.slice)), .Fail);
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

    return ExecutionStats{
        .num_tests = num_processed,
        .num_success = num_processed-num_failed,
        .num_fail = num_failed,
    };
}

// Regular path for tests passed as arguments
fn processTestlist(test_context: *TestContext, args: *AppArguments, input_vars:*kvstore.KvStore, extracted_vars: *kvstore.KvStore) !ExecutionStats {
    var buf = initBoundedArray(u8, 1024*1024);
    var num_processed: u64 = 0;
    var num_failed: u64 = 0;
    const time_start = std.time.milliTimestamp();

    for (args.files.slice()) |file| {
        if(!std.mem.endsWith(u8, file.constSlice(), config.CONFIG_FILE_EXT_TEST)) continue;
        
        num_processed += 1;

        //////////////////
        // Process
        //////////////////
        io.readFile(u8, buf.buffer.len, file.constSlice(), &buf) catch {
            Console.red("ERROR: Could not read file: {s}\n", .{file.constSlice()});
            num_failed += 1;
            continue;
        };

        // Expand all variables
        parser.expandVariablesAndFunctions(buf.buffer.len, &buf, extracted_vars) catch {};
        parser.expandVariablesAndFunctions(buf.buffer.len, &buf, input_vars) catch {};

        if(processAndEvaluateEntryFromBuf(test_context, num_processed, args.files.slice().len, file.constSlice(), buf.constSlice(), args.*, input_vars, extracted_vars, 1, 0)) {
            // OK
        } else |_| {
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

    return ExecutionStats{
        .num_tests = num_processed,
        .num_success = num_processed-num_failed,
        .num_fail = num_failed,
    };
}

pub fn mainInner(allocator: *std.mem.Allocator, args: [][]u8) anyerror!ExecutionStats {
    try httpclient.init();
    defer httpclient.deinit();

    // Scrap-buffer to use throughout tests
    var test_context = try allocator.create(TestContext);

    var parsed_args = argparse.parseArgs(args) catch |e| switch(e) {
        error.ShowHelp => {
            argparse.printHelp(true);
            return ExecutionStats{};
        },
        else => {
            debug("Invalid arguments.", .{});
            argparse.printHelp(true);
            fatal("Exiting.", .{});
        }
    };
    
    if(parsed_args.verbose) Console.grey("Processing input file arguments\n", .{});
    argparse.processInputFileArguments(parsed_args.files.buffer.len, &parsed_args.files) catch |e| {
        fatal("Could not process input file arguments: {s}\n", .{e});
    };

    var input_vars = kvstore.KvStore{};
    if(parsed_args.input_vars_file.constSlice().len > 0) {
        if(parsed_args.verbose) debug("Attempting to read input variables from: {s}\n", .{parsed_args.input_vars_file.constSlice()});
        // TODO: expand variables within envfiles? This to e.g. allow env-files to refer to OS ENV. Any proper use case?
        input_vars = try envFileToKvStore(fs.cwd(), parsed_args.input_vars_file.constSlice());
    }

    var extracted_vars: kvstore.KvStore = .{};
    var stats: ExecutionStats = .{};
    if(parsed_args.playbook_file.constSlice().len > 0) {
        // Process playbook
        if(parsed_args.verbose) debug("Got playbook: {s}\n", .{parsed_args.playbook_file.constSlice()});
        stats = try processPlaybook(test_context, parsed_args.playbook_file.constSlice(), parsed_args, &input_vars, &extracted_vars);
    } else {
        // Process regular list of entries
        stats = try processTestlist(test_context, &parsed_args, &input_vars, &extracted_vars);
    }

    return stats;
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

    var stats = mainInner(aa, args[1..]) catch |e| {
        fatal("Exited due to failure: {s}\n", .{e});
    };

    if(stats.num_fail > 0) {
        debug("Not all tests were successful: {d} of {d} failed\n", .{stats.num_fail, stats.num_tests});
        exit(.TestsFailed);
    }

    exit(.Ok);
}


pub fn envFileToKvStore(dir: fs.Dir, path: []const u8) !kvstore.KvStore {
    var tmpbuf: [1024*1024]u8 = undefined;
    var buf_len = io.readFileRawRel(dir, path, &tmpbuf) catch {
        return error.CouldNotReadFile;
    };

    return try kvstore.KvStore.fromBuffer(tmpbuf[0..buf_len]);
}

test "envFileToKvStore" {
    var store = try envFileToKvStore(fs.cwd(), "testdata/env");
    try testing.expect(store.count() == 2);
    try testing.expectEqualStrings("value", store.get("key").?);
    try testing.expectEqualStrings("dabba", store.get("abba").?);
}
