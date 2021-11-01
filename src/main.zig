/// Main file for application.

// std lib imports
const std = @import("std");
const fs = std.fs;
const testing = std.testing;

const debug = std.debug.print;
pub const log_level: std.log.Level = .debug;

// application-specific imports
const argparse = @import("argparse.zig");
const config = @import("config.zig");
const httpclient = @import("httpclient.zig");
const io = @import("io.zig");
const kvstore = @import("kvstore.zig");
const parser = @import("parser.zig");
const pretty = @import("pretty.zig");
const threadpool = @import("threadpool.zig");
const types = @import("types.zig");
const utils = @import("utils.zig");

const Console = @import("console.zig").Console;

const HttpMethod = types.HttpMethod;
const HttpHeader = types.HttpHeader;
const ExtractionEntry = types.ExtractionEntry;
const AppArguments = argparse.AppArguments;

// To be replacable, e.g. for tests
pub var httpClientProcessEntry: fn (*Entry, httpclient.ProcessArgs, *EntryResult) anyerror!void = undefined;

const initBoundedArray = utils.initBoundedArray;

pub const errors = error{
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
    Console.plain(format, args);
    exit(.ProcessError);
}

pub const Entry = struct {
    name: std.BoundedArray(u8, 1024) = initBoundedArray(u8, 1024),
    method: HttpMethod = undefined,
    url: std.BoundedArray(u8, config.MAX_URL_LEN) = initBoundedArray(u8, config.MAX_URL_LEN),
    headers: std.BoundedArray(HttpHeader, 32) = initBoundedArray(HttpHeader, 32),
    payload: std.BoundedArray(u8, config.MAX_PAYLOAD_SIZE) = initBoundedArray(u8, config.MAX_PAYLOAD_SIZE),
    expected_http_code: u64 = 0, // 0 == don't care
    expected_response_substring: std.BoundedArray(u8, 1024) = initBoundedArray(u8, 1024),
    extraction_entries: std.BoundedArray(ExtractionEntry, 32) = initBoundedArray(ExtractionEntry, 32),
    repeats: usize = 1,
};

// TODO: Split what is return-data from the processEntry vs what's aggregated results outside?
pub const EntryResult = struct {
    num_fails: usize = 0, // Will increase for each failed attempt, relates to "repeats"
    conclusion: bool = false,
    response_content_type: std.BoundedArray(u8, HttpHeader.MAX_VALUE_LEN) = initBoundedArray(u8, HttpHeader.MAX_VALUE_LEN),
    response_http_code: u64 = 0,
    response_match: bool = false,
    // TODO: Fetch response-length in case it's >1MB?
    response_first_1mb: std.BoundedArray(u8, 1024 * 1024) = initBoundedArray(u8, 1024 * 1024),
};

const ProcessStatistics = struct {
    time_total: i64 = 0,
    time_min: i64 = undefined,
    time_max: i64 = undefined,
    time_avg: i64 = undefined,
};

const TestContext = struct { entry: Entry = .{}, result: EntryResult = .{} };

const ExecutionStats = struct {
    num_tests: u64 = 0,
    num_success: u64 = 0,
    num_fail: u64 = 0,
};


fn isEntrySuccessful(entry: *Entry, result: *EntryResult) bool {
    if (entry.expected_response_substring.constSlice().len > 0 and std.mem.indexOf(u8, result.response_first_1mb.constSlice(), entry.expected_response_substring.constSlice()) == null) {
        result.response_match = false;
        return false;
    }
    result.response_match = true;

    if (entry.expected_http_code != 0 and entry.expected_http_code != result.response_http_code) return false;

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

    

    if (args.multithreaded and repeats > 1) {
        Console.printIf(args.verbose, null, "Starting multithreaded test ({d} threads working total {d} requests)\n", .{ try std.Thread.getCpuCount(), repeats });

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
                if (httpClientProcessEntry(self.entry, .{.ssl_insecure = self.args.ssl_insecure, .verbose = self.args.verbose_curl}, self.result)) {
                    if (!isEntrySuccessful(self.entry, self.result)) {
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
        var i: usize = 0;
        while (i < repeats) : (i += 1) {
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
        Console.printIf(args.verbose, null, "Starting singlethreaded test ({d} requests)\n", .{repeats});
        const time_total_start = std.time.milliTimestamp();

        var i: usize = 0;
        while (i < repeats) : (i += 1) {
            var entry_time_start = std.time.milliTimestamp();
            if (httpClientProcessEntry(entry, .{.ssl_insecure = args.ssl_insecure, .verbose = args.verbose_curl}, result)) {
                if (!isEntrySuccessful(entry, result)) {
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
    for (entry.extraction_entries.constSlice()) |v| {
        if (parser.expressionExtractor(result.response_first_1mb.constSlice(), v.expression.constSlice())) |expression_result| {
            // Got match
            try store.add(v.name.constSlice(), expression_result.result);
        } else {
            Console.red("Could not find match for '{s}={s}'\n", .{ v.name.constSlice(), v.expression.constSlice() });
            return error.UnableToExtractExtractionEntry;
        }
    }
}

/// Main do'er to do anything related to orchestrating the execution of the entry, repeats and outputting the results
/// Common to both regular flow (entries as arguments) and playbooks
fn processAndEvaluateEntryFromBuf(test_context: *TestContext, idx: u64, total: u64, entry_name: []const u8, entry_buf: []const u8, args: AppArguments, input_vars: *kvstore.KvStore, extracted_vars: *kvstore.KvStore, repeats: u32, line_idx_offset: usize) !void {
    test_context.* = .{}; // Reset
    _ = input_vars;
    test_context.entry.repeats = repeats;

    // Do
    var stats: ProcessStatistics = .{};
    Console.printIf(args.verbose, null, "Processing entry: {s}\n", .{entry_name});

    processEntryMain(test_context, args, entry_buf, repeats, &stats, line_idx_offset) catch |err| {
        // TODO: Switch the errors and give helpful output
        Console.red("{d}/{d}: {s:<64}            : Process error {s}\n", .{ idx, total, entry_name, err });
        return error.CouldNotProcessEntry;
    };

    var conclusion = test_context.result.conclusion;
   
    //////////////////////////
    // Evaluate results
    //////////////////////////

    // Output neat and tidy output, respectiong args .silent, .data and .verbose
    if (conclusion) { // Success
        Console.green("{d}/{d}: {s:<64}            : OK (HTTP {d} - {s})\n", .{ idx, total, entry_name, test_context.result.response_http_code, httpclient.httpCodeToString(test_context.result.response_http_code) });
    } else { // Errors
        Console.red("{d}/{d}: {s:<64}            : ERROR (HTTP {d} - {s})\n", .{ idx, total, entry_name, test_context.result.response_http_code, httpclient.httpCodeToString(test_context.result.response_http_code) });
    }

    // Print stats
    if (repeats == 1) {
        Console.grey("  time: {}ms\n", .{stats.time_total});
    } else {
        Console.grey("  {} iterations. {} OK, {} Error\n", .{ repeats, repeats - test_context.result.num_fails, test_context.result.num_fails });
        Console.grey("  time: {}ms/{} iterations [{}ms-{}ms] avg:{}ms\n", .{ stats.time_total, repeats, stats.time_min, stats.time_max, stats.time_avg });
    }

    if (conclusion) {
        // No need to extract if not successful
        // Failure to extract is a failure to the test
        try extractExtractionEntries(test_context.entry, test_context.result, extracted_vars);

        // Print all stored variables
        if (args.verbose and extracted_vars.store.slice().len > 0) {
            Console.plain("Values extracted from response:\n", .{});
            Console.plain("-" ** 80 ++ "\n", .{});
            for (extracted_vars.store.slice()) |v| {
                Console.plain("* {s}={s}\n", .{ v.key.constSlice(), v.value.constSlice() });
            }
            Console.plain("-" ** 80 ++ "\n", .{});
        }
    } else {
        Console.plain("{s} {s:<64}\n", .{ test_context.entry.method, test_context.entry.url.slice() });
        if (test_context.result.response_http_code != test_context.entry.expected_http_code) {
            Console.red("Fault: Expected HTTP '{d} - {s}', got '{d} - {s}'\n", .{ test_context.entry.expected_http_code, httpclient.httpCodeToString(test_context.entry.expected_http_code), test_context.result.response_http_code, httpclient.httpCodeToString(test_context.result.response_http_code) });
        }

        if (!test_context.result.response_match) {
            Console.red("Fault: Match requirement '{s}' was not successful\n", .{test_context.entry.expected_response_substring.constSlice()});
        }
    }

    if (!conclusion or args.verbose or args.show_response_data) {
        Console.bold("Response (up to 1024KB):\n", .{});
        if (!args.show_pretty_response_data) {
            Console.plain("{s}\n\n", .{utils.sliceUpTo(u8, test_context.result.response_first_1mb.slice(), 0, 1024 * 1024)});
        } else {
            try pretty.getPrettyPrinterByContentType(test_context.result.response_content_type.slice())(std.io.getStdOut().writer(), test_context.result.response_first_1mb.slice());
        }
    }

    if (!conclusion) return error.TestFailed;
}

fn getNumOfSegmentType(segments: []const parser.PlaybookSegment, segment_type: parser.PlaybookSegmentType) u64 {
    var result: u64 = 0;
    for (segments) |segment| {
        if (segment.segment_type == segment_type) result += 1;
    }
    return result;
}

fn processPlaybookFile(test_context: *TestContext, playbook_path: []const u8, args: AppArguments, input_vars: *kvstore.KvStore, extracted_vars: *kvstore.KvStore) !ExecutionStats {
    var buf_playbook = initBoundedArray(u8, config.MAX_PLAYBOOK_FILE_SIZE); // Att: this must be kept as it is used to look up data from for the segments

    io.readFile(buf_playbook.buffer.len, playbook_path, &buf_playbook) catch {
        Console.red("ERROR: Could not read playbook file: {s}\n", .{playbook_path});
        return error.CouldNotReadFile;
    };

    // Playbooks shall resolve file-includes relative to self
    var playbook_parent_path = io.getParent(playbook_path);
    
    return processPlaybookBuf(test_context, &buf_playbook, playbook_parent_path, args, input_vars, extracted_vars);
}


fn processPlaybookBuf(test_context: *TestContext, buf_playbook: *std.BoundedArray(u8, config.MAX_PLAYBOOK_FILE_SIZE), playbook_basedir: []const u8, args: AppArguments, input_vars: *kvstore.KvStore, extracted_vars: *kvstore.KvStore) !ExecutionStats {
    // Load playbook
    var buf_scrap = initBoundedArray(u8,16*1024);
    var buf_test = initBoundedArray(u8, config.MAX_TEST_FILE_SIZE);

    var segments = initBoundedArray(parser.PlaybookSegment, 128);
    try segments.resize(parser.parsePlaybook(buf_playbook.constSlice(), segments.unusedCapacitySlice()));


    // Iterate over playbook and act according to each type
    var num_failed: u64 = 0;
    var num_processed: u64 = 0;
    var total_num_tests = getNumOfSegmentType(segments.constSlice(), .TestInclude) + getNumOfSegmentType(segments.constSlice(), .TestRaw);
    var variables_sets = [_]*kvstore.KvStore{input_vars, extracted_vars};
    const time_start = std.time.milliTimestamp();
    // Pass through each item and process according to type
    for (segments.constSlice()) |segment| {
        try buf_test.resize(0);
        Console.printIf(args.verbose, null, "Processing segment type: {s}, line: {d}\n", .{ segment.segment_type, segment.line_start });

        switch (segment.segment_type) {
            .Unknown => {
                unreachable;
            },
            .TestInclude, .TestRaw => {
                // We got a test.
                // For file-based tests: read the file to a buffer
                // For in-playbook tests: copy the contents to buffer
                // - then from that point on: unified processing
                num_processed += 1;
                var name_buf: [128]u8 = undefined;
                var name_slice: []u8 = undefined;
                var repeats: u32 = 1;

                if (segment.segment_type == .TestInclude) {
                    name_slice = try std.fmt.bufPrint(&name_buf, "{s}", .{utils.constSliceUpTo(u8, segment.slice, 0, name_buf.len)});
                    repeats = segment.meta.TestInclude.repeats;
                    Console.printIf(args.verbose, null, "Processing: {s}\n", .{segment.slice});
                    var full_path = try io.getRealPath(playbook_basedir, segment.slice, buf_scrap.unusedCapacitySlice());
                    // Load from file and parse
                    io.readFile(buf_test.buffer.len, full_path, &buf_test) catch |e| {
                        parser.parseErrorArg("Could not read file ({s})", .{e}, segment.line_start, 0, buf_test.constSlice(), segment.slice);
                        num_failed += 1;
                        continue;
                    };
                } else {
                    // Test raw
                    name_slice = try std.fmt.bufPrint(&name_buf, "Inline segment starting at line: {d}", .{segment.line_start});
                    try buf_test.appendSlice(segment.slice);
                }

                // Expand variables
                parser.expandVariablesAndFunctions(buf_test.buffer.len, &buf_test, variables_sets[0..]) catch {};

                // Execute the test
                if (processAndEvaluateEntryFromBuf(test_context, num_processed, total_num_tests, name_slice, buf_test.constSlice(), args, input_vars, extracted_vars, repeats, segment.line_start)) {
                    // OK
                } else |_| {
                    num_failed += 1;

                    if(args.early_quit) {
                        Console.red("Early-quit is active, so aborting further steps\n", .{});
                        break;
                    }
                }
            },
            .EnvInclude => {
                // Load from file and parse
                Console.printIf(args.verbose, null, "Loading env-file: '{s}'\n", .{segment.slice});
                var full_path = try io.getRealPath(playbook_basedir, segment.slice, buf_scrap.unusedCapacitySlice());

                try input_vars.addFromOther((try envFileToKvStore(fs.cwd(), full_path)), .Fail);
            },
            .EnvRaw => {
                // Parse key=value directly
                Console.printIf(args.verbose, null, "Loading in-file env at line {d}\n", .{segment.line_start});
                try buf_scrap.resize(0);
                try buf_scrap.appendSlice(segment.slice);

                // Expand functions
                parser.expandVariablesAndFunctions(buf_scrap.buffer.len, &buf_scrap, null) catch {};

                try input_vars.addFromBuffer(buf_scrap.constSlice(), .Fail);
            },
        }
    }

    Console.plain(
        \\------------------
        \\{d}/{d} OK
        \\------------------
        \\FINISHED - total time: {d}s
        \\
    , .{ num_processed - num_failed, total_num_tests, @intToFloat(f64, std.time.milliTimestamp() - time_start) / 1000 });

    return ExecutionStats{
        .num_tests = num_processed,
        .num_success = num_processed - num_failed,
        .num_fail = num_failed,
    };
}

test "extracted variables shall be expanded in next test" {
    var buf_test1 = try std.testing.allocator.create(std.BoundedArray(u8, config.MAX_TEST_FILE_SIZE));
    defer std.testing.allocator.destroy(buf_test1);
    buf_test1.* = try std.BoundedArray(u8, config.MAX_TEST_FILE_SIZE).fromSlice(
        \\> GET https://some.url/api/step1
        \\< 0
        \\MYVAR=token:"()"
        [0..]
    );

    var buf_test2 = try std.testing.allocator.create(std.BoundedArray(u8, config.MAX_TEST_FILE_SIZE));
    defer std.testing.allocator.destroy(buf_test2);
    buf_test2.* = try std.BoundedArray(u8, config.MAX_TEST_FILE_SIZE).fromSlice(
        \\> GET https://some.url/api/step2
        \\--
        \\MYVAR={{MYVAR}}
        \\< 0
        [0..]
    );

    var context = TestContext{};
    var args = AppArguments{};
    var input_vars = kvstore.KvStore{};
    var extracted_vars = kvstore.KvStore{};
    var variables_sets = [_]*kvstore.KvStore{&input_vars, &extracted_vars};

    // Mock httpclient, this can be generalized for multiple tests
    const HttpClientOverrides = struct {
        pub fn step1(_: *Entry, _: httpclient.ProcessArgs, result: *EntryResult) !void {
            try result.response_first_1mb.resize(0);
            try result.response_first_1mb.appendSlice(
                \\token:"123123"
                [0..]
            );
        }
    };

    // Handle step 1
    var oldProcess = httpClientProcessEntry;
    httpClientProcessEntry = HttpClientOverrides.step1;
    parser.expandVariablesAndFunctions(buf_test1.buffer.len, buf_test1, variables_sets[0..]) catch {};
    try processAndEvaluateEntryFromBuf(&context, 1, 2, "step1"[0..], buf_test1.constSlice(), args, &input_vars, &extracted_vars, 1, 0);
    try testing.expect(extracted_vars.slice().len == 1);
    
    // Handle step 2
    parser.expandVariablesAndFunctions(buf_test2.buffer.len, buf_test2, variables_sets[0..]) catch {};
    try testing.expect(std.mem.indexOf(u8, buf_test2.constSlice(), "{{MYVAR}}") == null);
    try testing.expect(std.mem.indexOf(u8, buf_test2.constSlice(), "MYVAR={{MYVAR}}") == null);
    try testing.expect(std.mem.indexOf(u8, buf_test2.constSlice(), "MYVAR=123123") != null);
    
    httpClientProcessEntry = oldProcess;
}

// Regular path for tests passed as arguments
fn processTestlist(test_context: *TestContext, args: *AppArguments, input_vars: *kvstore.KvStore, extracted_vars: *kvstore.KvStore) !ExecutionStats {
    var buf_testfile = initBoundedArray(u8, config.MAX_TEST_FILE_SIZE);
    var num_processed: u64 = 0;
    var num_failed: u64 = 0;
    const time_start = std.time.milliTimestamp();

    // Used to check if we enter a folder
    var folder_local_vars: kvstore.KvStore = undefined;
    var current_folder: []const u8 = undefined;
    var variables_sets = [_]*kvstore.KvStore{&folder_local_vars, input_vars, extracted_vars};

    // Get num of .pi-files in args.files
    var total_num_tests: u64 = 0;
    for(args.files.constSlice()) |file| {
        if (std.mem.endsWith(u8, file.constSlice(), config.FILE_EXT_TEST)) {
            total_num_tests += 1;
        }
    }

    for (args.files.slice()) |file| {
        // If new folder: clear folder_local_vars
        if (!std.mem.eql(u8, current_folder, io.getParent(file.constSlice()))) {
            folder_local_vars = kvstore.KvStore{};
            current_folder = io.getParent(file.constSlice());
        }

        // .env: load
        if (std.mem.endsWith(u8, file.constSlice(), config.FILE_EXT_ENV)) {
            Console.grey("Loading .env: {s}\n", .{file.constSlice()});
            try folder_local_vars.addFromOther(try envFileToKvStore(fs.cwd(), file.constSlice()), .KeepFirst);
        }
        if (!std.mem.endsWith(u8, file.constSlice(), config.FILE_EXT_TEST)) continue;

        num_processed += 1;

        //////////////////
        // Process
        //////////////////
        io.readFile(buf_testfile.buffer.len, file.constSlice(), &buf_testfile) catch {
            Console.red("ERROR: Could not read file: {s}\n", .{file.constSlice()});
            num_failed += 1;
            continue;
        };

        // Expand all variables
        parser.expandVariablesAndFunctions(buf_testfile.buffer.len, &buf_testfile,  variables_sets[0..]) catch {};

        if (processAndEvaluateEntryFromBuf(test_context, num_processed, total_num_tests, file.constSlice(), buf_testfile.constSlice(), args.*, input_vars, extracted_vars, 1, 0)) {
            // OK
        } else |_| {
            num_failed += 1;

            if(args.early_quit) {
                Console.red("Early-quit is active, so aborting further tests\n", .{});
                break;
            }
        }

        if(args.delay > 0) {
            Console.grey("Delaying next test with {}ms\n", .{args.delay});
            std.time.sleep(args.delay*1000000);
        }
    }
    Console.plain(
        \\------------------
        \\{d}/{d} OK
        \\------------------
        \\FINISHED - total time: {d}s
        \\
    , .{ num_processed - num_failed, total_num_tests, @intToFloat(f64, std.time.milliTimestamp() - time_start) / 1000 });

    return ExecutionStats{
        .num_tests = num_processed,
        .num_success = num_processed - num_failed,
        .num_fail = num_failed,
    };
}

/// Main functional starting point
pub fn mainInner(allocator: *std.mem.Allocator, args: [][]const u8) anyerror!ExecutionStats {
    try httpclient.init();
    defer httpclient.deinit();

    // Scrap-buffer to use throughout tests
    var test_context = try allocator.create(TestContext);
    defer allocator.destroy(test_context);

    // Shared variable-buffer between .env-files and -D-arguments
    var input_vars = kvstore.KvStore{};
    // Parse arguments / show help
    var parsed_args = argparse.parseArgs(args, &input_vars) catch |e| switch (e) {
        error.OkExit => {
            return ExecutionStats{};
        },
        else => {
            Console.plain("Invalid arguments.\n", .{});
            argparse.printHelp(true);
            fatal("Exiting.", .{});
        },
    };

    // Expand files e.g. if folders are passed
    Console.printIf(parsed_args.verbose, .Dim, "Processing input file arguments\n", .{});

    argparse.processInputFileArguments(parsed_args.files.buffer.len, &parsed_args.files) catch |e| {
        fatal("Could not process input file arguments: {s}\n", .{e});
    };

    
    if (parsed_args.input_vars_file.constSlice().len > 0) {
        Console.printIf(parsed_args.verbose, null, "Attempting to read input variables from: {s}\n", .{parsed_args.input_vars_file.constSlice()});
        input_vars = try envFileToKvStore(fs.cwd(), parsed_args.input_vars_file.constSlice());
    }

    var extracted_vars: kvstore.KvStore = .{};
    var stats: ExecutionStats = .{};
    if (parsed_args.playbook_file.constSlice().len > 0) {
        // Process playbook
        Console.printIf(parsed_args.verbose, null, "Got playbook: {s}\n", .{parsed_args.playbook_file.constSlice()});
        stats = try processPlaybookFile(test_context, parsed_args.playbook_file.constSlice(), parsed_args, &input_vars, &extracted_vars);
    } else {
        // Process regular list of entries
        stats = try processTestlist(test_context, &parsed_args, &input_vars, &extracted_vars);
    }

    return stats;
}

/// Main CLI entry point. Mainly responsible for wrapping mainInner()
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer arena.deinit();
    const aa = &arena.allocator;

    const args = try std.process.argsAlloc(aa);
    defer std.process.argsFree(aa, args);

    if (args.len == 1) {
        argparse.printHelp(false);
        std.process.exit(0);
    }
    
    // Set up default handler to process requests
    httpClientProcessEntry = httpclient.processEntry;

    var stats = mainInner(aa, args[1..]) catch |e| {
        fatal("Exited due to failure: {s}\n", .{e});
    };

    if (stats.num_fail > 0) {
        Console.plain("Not all tests were successful: {d} of {d} failed\n", .{ stats.num_fail, stats.num_tests });
        exit(.TestsFailed);
    }

    exit(.Ok);
}

pub fn envFileToKvStore(dir: fs.Dir, path: []const u8) !kvstore.KvStore {
    var tmpbuf = initBoundedArray(u8, config.MAX_ENV_FILE_SIZE);

    io.readFileRel(tmpbuf.buffer.len, dir, path, &tmpbuf) catch {
        Console.red("ERROR: Could not read .env-file: {s}\n", .{path});
        return error.CouldNotReadFile;
    };

    // Expand functions
    try parser.expandVariablesAndFunctions(tmpbuf.buffer.len, &tmpbuf, null);

    return try kvstore.KvStore.fromBuffer(tmpbuf.constSlice());
}

test "envFileToKvStore" {
    var store = try envFileToKvStore(fs.cwd(), "testdata/env");
    try testing.expect(store.count() == 2);
    try testing.expectEqualStrings("value", store.get("key").?);
    try testing.expectEqualStrings("dabba", store.get("abba").?);
}
