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
const Console = @import("console.zig").Console;
const httpclient = @import("httpclient.zig");
const io = @import("io.zig");
const kvstore = @import("kvstore.zig");
const Parser = @import("parser.zig").Parser;
const pretty = @import("pretty.zig");
const threadpool = @import("threadpool.zig");
const types = @import("types.zig");
const utils = @import("utils.zig");

const Entry = types.Entry;
const EntryResult = types.EntryResult;
const TestContext = types.TestContext;
const HttpMethod = httpclient.HttpMethod;
const HttpHeader = types.HttpHeader;
const ExtractionEntry = types.ExtractionEntry;
const AppArguments = argparse.AppArguments;

const expressionExtractor = @import("parser_expressions.zig").expressionExtractor;

// To be replacable, e.g. for tests. TODO: Make argument to AppContext
// const HttpClientFunc = @TypeOf(&httpclient.request);

const initBoundedArray = utils.initBoundedArray;

pub const errors = error{
    Ok,
    ParseError,
    TestFailed,
    TestsFailed,
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
    std.debug.print(format, args);
    exit(.ProcessError);
}

const ProcessStatistics = struct {
    time_total: i64 = 0,
    time_min: i64 = undefined,
    time_max: i64 = undefined,
    time_avg: i64 = undefined,
};

const ExecutionStats = struct {
    num_tests: u64 = 0,
    num_success: u64 = 0,
    num_fail: u64 = 0,
};

/// Main CLI entry point. Mainly responsible for wrapping mainInner()
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer arena.deinit();
    const aa = arena.allocator();

    const args = try std.process.argsAlloc(aa);
    defer std.process.argsFree(aa, args);

    if (args.len == 1) {
        argparse.printHelp(false);
        std.process.exit(0);
    }

    var stats = mainInner(aa, args[1..]) catch |e| {
        fatal("Exited due to failure: {s}\n", .{@errorName(e)});
    };

    if (stats.num_fail > 0) {
        exit(.TestsFailed);
    }

    exit(.Ok);
}

/// Main functional starting point - move to AppContext?
pub fn mainInner(allocator: std.mem.Allocator, args: [][]const u8) anyerror!ExecutionStats {
    try httpclient.init();
    defer httpclient.deinit();

    // Shared variable-buffer between .env-files and -D-arguments
    var input_vars = kvstore.KvStore{};
    // Parse arguments / show help
    var parsed_args = argparse.parseArgs(args, &input_vars) catch |e| switch (e) {
        error.OkExit => {
            return ExecutionStats{};
        },
        else => {
            std.debug.print("Invalid arguments.\n", .{});
            argparse.printHelp(true);
            fatal("Exiting.\n", .{});
        },
    };

    // Scrap-buffer to use throughout tests
    var test_ctx = try allocator.create(TestContext);
    defer allocator.destroy(test_ctx);

    // "Global" definitions to be used by main parts of application
    var stdout = std.io.getStdOut().writer();
    var stderr = std.io.getStdErr().writer();

    const console = Console.init(.{
        .std_writer = if (!parsed_args.silent) stdout else null,
        .debug_writer = stdout,
        .verbose_writer = if (!parsed_args.verbose) null else stdout,
        .error_writer = if (!parsed_args.silent) stderr else null,
        .colors = parsed_args.colors,
    });

    var app_ctx = try AppContext.create(allocator, console);
    defer app_ctx.destroy();

    // Expand files e.g. if folders are passed
    console.verbosePrint("Processing input file arguments\n", .{});

    argparse.processInputFileArguments(128, &parsed_args.files) catch |e| {
        fatal("Could not process input file arguments: {s}\n", .{@errorName(e)});
    };

    if (parsed_args.input_vars_file.constSlice().len > 0) {
        console.verbosePrint("Attempting to read input variables from: {s}\n", .{parsed_args.input_vars_file.constSlice()});
        input_vars = try app_ctx.envFileToKvStore(fs.cwd(), parsed_args.input_vars_file.constSlice());
    }

    var extracted_vars = kvstore.KvStore{};
    var stats = ExecutionStats{};
    if (parsed_args.playbook_file.constSlice().len > 0) {
        // Process playbook
        console.verbosePrint("Got playbook: {s}\n", .{parsed_args.playbook_file.constSlice()});
        stats = try app_ctx.processPlaybookFile(parsed_args.playbook_file.constSlice(), &parsed_args, &input_vars, &extracted_vars);
    } else {
        // Process regular list of entries
        stats = try app_ctx.processTestlist(&parsed_args, &input_vars, &extracted_vars);
    }

    if (stats.num_fail > 0) {
        console.errorPrint("Not all tests were successful: {d} of {d} failed\n", .{ stats.num_fail, stats.num_tests });
    }

    return stats;
}

/// Main structure of the application
pub const AppContext = struct {
    console: Console,
    parser: Parser,
    test_ctx: *TestContext,
    allocator: std.mem.Allocator,

    /// Att! Allocates memory for both self and .test_ctx. Can be freed with .destroy().
    pub fn create(allocator: std.mem.Allocator, console: Console) !*AppContext {
        // Scrap-buffer to use throughout tests
        var test_ctx = try allocator.create(TestContext);

        // Construct self
        var self = try allocator.create(AppContext);

        self.* = AppContext{
            .allocator = allocator,
            .console = console,
            .parser = Parser{ .console = &console },
            .test_ctx = test_ctx,
            // .httpClientRequest = httpclient.request,
        };

        return self;
    }

    /// Free any allocated resources owned by this, including self.
    pub fn destroy(app_ctx: *AppContext) void {
        app_ctx.allocator.destroy(app_ctx.test_ctx);
        app_ctx.allocator.destroy(app_ctx);
    }

    // Process entry and evaluate results. Returns error-type in case of either parse error, process error or evaluation error
    pub fn processEntryMain(app_ctx: *AppContext, args: *AppArguments, buf: []const u8, repeats: u32, stats: *ProcessStatistics, line_idx_offset: usize) !void {
        const console = app_ctx.console;
        var entry: *Entry = &app_ctx.test_ctx.entry;
        var result: *EntryResult = &app_ctx.test_ctx.result;

        try app_ctx.parser.parseContents(buf, entry, line_idx_offset);

        // TODO: Refactor this to better unify the different call-methods/variants
        stats.time_max = 0;
        stats.time_min = std.math.maxInt(i64);

        if (args.multithreaded and repeats > 1) {
            console.verbosePrint("Starting multithreaded test ({d} threads working total {d} requests)\n", .{ try std.Thread.getCpuCount(), repeats });

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
                    if (processEntry(self.entry, .{ .ssl_insecure = self.args.ssl_insecure, .verbose = self.args.verbose_curl }, self.result)) {
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
                    .args = args,
                    .result = result,
                });
            }

            try pool.startAndJoin(); // Can fail if unable to spawn thread, but then we are in trouble anyways
            // Evaluate results?
        } else {
            console.verbosePrint("Starting singlethreaded test ({d} requests)\n", .{repeats});
            const time_total_start = std.time.milliTimestamp();

            var i: usize = 0;
            while (i < repeats) : (i += 1) {
                var entry_time_start = std.time.milliTimestamp();
                if (processEntry(entry, .{ .ssl_insecure = args.ssl_insecure, .verbose = args.verbose_curl }, result)) {
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

    fn extractExtractionEntries(app_ctx: *AppContext, entry: Entry, result: EntryResult, store: *kvstore.KvStore) !void {
        // Extract to variables
        for (entry.extraction_entries.constSlice()) |v| {
            if (expressionExtractor(result.response_first_1mb.constSlice(), v.expression.constSlice())) |expression_result| {
                // Got match in response body
                try store.add(v.name.constSlice(), expression_result.result);
            } else if (expressionExtractor(result.response_headers_first_1mb.constSlice(), v.expression.constSlice())) |expression_result| {
                // Got match in response headers
                try store.add(v.name.constSlice(), expression_result.result);
            } else {
                app_ctx.console.errorPrint("Could not find match for '{s}={s}'\n", .{ v.name.constSlice(), v.expression.constSlice() });
                return error.UnableToExtractExtractionEntry;
            }
        }
    }

    /// Main do'er to do anything related to orchestrating the execution of the entry, repeats and outputting the results
    /// Common to both regular flow (entries as arguments) and playbooks
    fn processAndEvaluateEntryFromBuf(app_ctx: *AppContext, idx: u64, total: u64, entry_name: []const u8, entry_buf: []const u8, args: *AppArguments, input_vars: *kvstore.KvStore, extracted_vars: *kvstore.KvStore, repeats: u32, line_idx_offset: usize) !void {
        const console = app_ctx.console;
        // reset
        app_ctx.test_ctx.* = .{};
        _ = input_vars;
        app_ctx.test_ctx.entry.repeats = repeats;

        // Do
        var stats: ProcessStatistics = .{};
        console.verbosePrint("Processing entry: {s}\n", .{entry_name});

        processEntryMain(app_ctx, args, entry_buf, repeats, &stats, line_idx_offset) catch |err| {
            // TODO: Switch the errors and give helpful output
            console.errorPrint("{d}/{d}: {s:<64}            : Process error {s}\n", .{ idx, total, entry_name, @errorName(err) });
            return error.CouldNotProcessEntry;
        };
        var test_ctx = app_ctx.test_ctx;
        var conclusion = test_ctx.result.conclusion;

        //////////////////////////
        // Evaluate results
        //////////////////////////

        // Output neat and tidy output, respectiong args .silent, .data and .verbose
        if (conclusion) { // Success
            console.stdPrint("{d}/{d}: {s:<64}            : OK (HTTP {d} - {s})\n", .{ idx, total, entry_name, test_ctx.result.response_http_code, httpclient.httpCodeToString(test_ctx.result.response_http_code) });
        } else { // Errors
            console.errorPrint("{d}/{d}: {s:<64}            : ERROR (HTTP {d} - {s})\n", .{ idx, total, entry_name, test_ctx.result.response_http_code, httpclient.httpCodeToString(test_ctx.result.response_http_code) });
        }

        // Print stats
        if (repeats == 1) {
            console.stdColored(.Dim, "  time: {}ms\n", .{stats.time_total});
        } else {
            console.stdColored(.Dim, "  {} iterations. {} OK, {} Error\n", .{ repeats, repeats - test_ctx.result.num_fails, test_ctx.result.num_fails });
            console.stdColored(.Dim, "  time: {}ms/{} iterations [{}ms-{}ms] avg:{}ms\n", .{ stats.time_total, repeats, stats.time_min, stats.time_max, stats.time_avg });
        }

        // Check if test as a total is considered successfull (http code match + optional pattern match requirement)
        if (conclusion) {
            // No need to extract if not successful
            // Failure to extract is a failure to the test
            try app_ctx.extractExtractionEntries(test_ctx.entry, test_ctx.result, extracted_vars);

            // Print all stored variables
            if (args.verbose and extracted_vars.store.slice().len > 0) {
                console.verbosePrint("Values extracted from response:\n", .{});
                console.verbosePrint("-" ** 80 ++ "\n", .{});
                for (extracted_vars.store.slice()) |v| {
                    console.verbosePrint("* {s}={s}\n", .{ v.key.constSlice(), v.value.constSlice() });
                }
                console.verbosePrint("-" ** 80 ++ "\n", .{});
            }
        } else {
            console.stdPrint("{s} {s:<64}\n", .{ @tagName(test_ctx.entry.method), test_ctx.entry.url.slice() });
            if (test_ctx.result.response_http_code != test_ctx.entry.expected_http_code) {
                console.errorPrint("Expected HTTP '{d} - {s}', got '{d} - {s}'\n", .{ test_ctx.entry.expected_http_code, httpclient.httpCodeToString(test_ctx.entry.expected_http_code), test_ctx.result.response_http_code, httpclient.httpCodeToString(test_ctx.result.response_http_code) });
            }

            if (!test_ctx.result.response_match and test_ctx.entry.expected_response_substring.constSlice().len > 0) {
                console.errorPrint("Match requirement '{s}' was not successful\n", .{test_ctx.entry.expected_response_substring.constSlice()});
            }
        }

        // Check for conditions to print response data
        // If not --silent, it will by default print response upon failed tests
        // To show response for successful tests: --show-response
        // TBD: What if we want overrall results, but no data upon failed tests?
        if ((!conclusion and !args.silent) or args.show_response_data) {
            // Headers
            if (test_ctx.result.response_headers_first_1mb.slice().len > 0) {
                console.stdColored(.Bold, "Incoming headers (up to 1024KB):\n", .{});
                console.stdPrint("{s}\n\n", .{std.mem.trimRight(u8, utils.sliceUpTo(u8, test_ctx.result.response_headers_first_1mb.slice(), 0, 1024 * 1024), "\r\n")});
            }

            // Body
            if (test_ctx.result.response_first_1mb.slice().len > 0) {
                console.stdColored(.Bold, "Response (up to 1024KB):\n", .{});
                if (!args.show_pretty_response_data) {
                    console.debugPrint("{s}\n\n", .{utils.sliceUpTo(u8, test_ctx.result.response_first_1mb.slice(), 0, 1024 * 1024)});
                } else if (console.debug_writer) |debug_writer| {
                    try pretty.getPrettyPrinterByContentType(test_ctx.result.response_content_type.slice())(debug_writer, test_ctx.result.response_first_1mb.slice());
                }
                console.stdPrint("\n", .{});
            }
        }

        if (!conclusion) return error.TestFailed;
    }

    fn getNumOfSegmentType(segments: []const Parser.PlaybookSegment, segment_type: Parser.PlaybookSegmentType) u64 {
        var result: u64 = 0;
        for (segments) |segment| {
            if (segment.segment_type == segment_type) result += 1;
        }
        return result;
    }

    fn processPlaybookFile(app_ctx: *AppContext, playbook_path: []const u8, args: *AppArguments, input_vars: *kvstore.KvStore, extracted_vars: *kvstore.KvStore) !ExecutionStats {
        var buf_playbook = initBoundedArray(u8, config.MAX_PLAYBOOK_FILE_SIZE); // Att: this must be kept as it is used to look up data from for the segments

        io.readFile(config.MAX_PLAYBOOK_FILE_SIZE, playbook_path, &buf_playbook) catch {
            app_ctx.console.errorPrint("Could not read playbook file: {s}\n", .{playbook_path});
            return error.CouldNotReadFile;
        };

        // Playbooks shall resolve file-includes relative to self
        var playbook_parent_path = io.getParent(playbook_path);

        return app_ctx.processPlaybookBuf(&buf_playbook, playbook_parent_path, args, input_vars, extracted_vars);
    }

    fn processPlaybookBuf(app_ctx: *AppContext, buf_playbook: *std.BoundedArray(u8, config.MAX_PLAYBOOK_FILE_SIZE), playbook_basedir: []const u8, args: *AppArguments, input_vars: *kvstore.KvStore, extracted_vars: *kvstore.KvStore) !ExecutionStats {
        const console = app_ctx.console;
        var parser = app_ctx.parser;
        // Load playbook
        var buf_scrap = initBoundedArray(u8, 16 * 1024);
        var buf_test = initBoundedArray(u8, config.MAX_TEST_FILE_SIZE);

        var segments = initBoundedArray(Parser.PlaybookSegment, 128);
        try segments.resize(Parser.parsePlaybook(buf_playbook.constSlice(), segments.unusedCapacitySlice()));

        // Iterate over playbook and act according to each type
        var num_failed: u64 = 0;
        var num_processed: u64 = 0;
        var total_num_tests = getNumOfSegmentType(segments.constSlice(), .TestInclude) + getNumOfSegmentType(segments.constSlice(), .TestRaw);
        var variables_sets = [_]*kvstore.KvStore{ input_vars, extracted_vars };
        const time_start = std.time.milliTimestamp();
        // Pass through each item and process according to type
        for (segments.constSlice()) |segment| {
            try buf_test.resize(0);
            console.verbosePrint("Processing segment type: {s}, line: {d}\n", .{ @tagName(segment.segment_type), segment.line_start });

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

                    if (segment.segment_type == .TestInclude){ 
                        name_slice = try std.fmt.bufPrint(&name_buf, "{s}", .{utils.constSliceUpTo(u8, segment.slice, 0, name_buf.len)});
                        repeats = segment.meta.TestInclude.repeats;
                        console.verbosePrint("Processing: {s}\n", .{segment.slice});
                        var full_path = try io.getRealPath(playbook_basedir, segment.slice, buf_scrap.unusedCapacitySlice());
                        // Load from file and parse
                        io.readFile(config.MAX_TEST_FILE_SIZE, full_path, &buf_test) catch |e| {
                            parser.parseErrorArg("Could not read file ({s})", .{@errorName(e)}, segment.line_start, 0, buf_test.constSlice(), segment.slice);
                            num_failed += 1;
                            continue;
                        };
                    } else {
                        // Test raw
                        name_slice = try std.fmt.bufPrint(&name_buf, "Inline segment starting at line: {d}", .{segment.line_start});
                        try buf_test.appendSlice(segment.slice);
                    }

                    // Expand variables
                    Parser.expandVariablesAndFunctions(config.MAX_TEST_FILE_SIZE, &buf_test, variables_sets[0..]) catch {};

                    // Execute the test
                    if (app_ctx.processAndEvaluateEntryFromBuf(num_processed, total_num_tests, name_slice, buf_test.constSlice(), args, input_vars, extracted_vars, repeats, segment.line_start)) {
                        // OK
                    } else |_| {
                        num_failed += 1;

                        if (args.early_quit) {
                            console.errorPrint("Early-quit is active, so aborting further steps\n", .{});
                            break;
                        }
                    }
                },
                .EnvInclude => {
                    // Load from file and parse
                    console.verbosePrint("Loading env-file: '{s}'\n", .{segment.slice});
                    var full_path = try io.getRealPath(playbook_basedir, segment.slice, buf_scrap.unusedCapacitySlice());

                    try input_vars.addFromOther((try app_ctx.envFileToKvStore(fs.cwd(), full_path)), .Fail);
                },
                .EnvRaw => {
                    // Parse key=value directly
                    console.verbosePrint("Loading in-file env at line {d}\n", .{segment.line_start});
                    try buf_scrap.resize(0);
                    try buf_scrap.appendSlice(segment.slice);

                    // Expand functions
                    Parser.expandVariablesAndFunctions(16 * 1024, &buf_scrap, null) catch {};

                    try input_vars.addFromBuffer(buf_scrap.constSlice(), .KeepFirst);
                },
            }
        }

        console.stdPrint(
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

    // Regular path for tests passed as arguments
    fn processTestlist(app_ctx: *AppContext, args: *AppArguments, input_vars: *kvstore.KvStore, extracted_vars: *kvstore.KvStore) !ExecutionStats {
        const console = app_ctx.console;
        var buf_testfile = initBoundedArray(u8, config.MAX_TEST_FILE_SIZE);
        var num_processed: u64 = 0;
        var num_failed: u64 = 0;
        const time_start = std.time.milliTimestamp();

        // Used to check if we enter a folder
        var folder_local_vars: kvstore.KvStore = undefined;
        var current_folder: []const u8 = undefined;
        var variables_sets = [_]*kvstore.KvStore{ &folder_local_vars, input_vars, extracted_vars };

        // Get num of .pi-files in args.files
        var total_num_tests: u64 = 0;
        for (args.files.constSlice()) |file| {
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
                console.verbosePrint("Loading .env: {s}\n", .{file.constSlice()});
                try folder_local_vars.addFromOther(try app_ctx.envFileToKvStore(fs.cwd(), file.constSlice()), .KeepFirst);
            }
            if (!std.mem.endsWith(u8, file.constSlice(), config.FILE_EXT_TEST)) continue;

            num_processed += 1;

            //////////////////
            // Process
            //////////////////
            io.readFile(config.MAX_TEST_FILE_SIZE, file.constSlice(), &buf_testfile) catch {
                console.errorPrint("Could not read file: {s}\n", .{file.constSlice()});
                num_failed += 1;
                continue;
            };

            // Expand all variables
            Parser.expandVariablesAndFunctions(config.MAX_TEST_FILE_SIZE, &buf_testfile, variables_sets[0..]) catch {};

            if (app_ctx.processAndEvaluateEntryFromBuf(num_processed, total_num_tests, file.constSlice(), buf_testfile.constSlice(), args, input_vars, extracted_vars, 1, 0)) {
                // OK
            } else |_| {
                num_failed += 1;

                if (args.early_quit) {
                    console.errorPrint("Early-quit is active, so aborting further tests\n", .{});
                    break;
                }
            }

            if (args.delay > 0) {
                console.verbosePrint("Delaying next test with {}ms\n", .{args.delay});
                std.time.sleep(args.delay * 1000000);
            }
        }
        console.stdPrint(
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

    pub fn envFileToKvStore(app_ctx: *AppContext, dir: fs.Dir, path: []const u8) !kvstore.KvStore {
        var tmpbuf = initBoundedArray(u8, config.MAX_ENV_FILE_SIZE);

        io.readFileRel(config.MAX_ENV_FILE_SIZE, dir, path, &tmpbuf) catch {
            app_ctx.console.errorPrint("Could not read .env-file: {s}\n", .{path});
            return error.CouldNotReadFile;
        };

        // Expand functions
        try Parser.expandVariablesAndFunctions(config.MAX_ENV_FILE_SIZE, &tmpbuf, null);

        return try kvstore.KvStore.fromBuffer(tmpbuf.constSlice());
    }
};

// Standalone functions

fn isEntrySuccessful(entry: *Entry, result: *EntryResult) bool {
    if (entry.expected_response_substring.constSlice().len > 0 and std.mem.indexOf(u8, result.response_first_1mb.constSlice(), entry.expected_response_substring.constSlice()) == null) {
        result.response_match = false;
        return false;
    }
    result.response_match = true;

    if (entry.expected_http_code != 0 and entry.expected_http_code != result.response_http_code) return false;

    return true;
}

// Wrapper of httpclient.process
pub const ProcessArgs = struct {
    ssl_insecure: bool = false,
    verbose: bool = false,
};
pub fn processEntry(entry: *types.Entry, args: ProcessArgs, result: *types.EntryResult) !void {
    // TODO: extract allocator?
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer arena.deinit();
    const aa = arena.allocator();
    // _ = args;

    var response = try httpclient.request(aa, entry.method, entry.url.buffer[0..entry.url.buffer.len:0], .{
        .insecure = args.ssl_insecure,
        .verbose = args.verbose
    });
    defer response.deinit();

    result.response_http_code = response.http_code;

    try result.response_content_type.resize(0);
    try result.response_content_type.appendSlice(try response.contentType());

    try result.response_first_1mb.resize(0);
    try result.response_headers_first_1mb.resize(0);

    switch(response.response_type) {
        .Ok => {
            
        },
        .Error => {

        }
    }
}

test "envFileToKvStore" {
    var app_ctx = try AppContext.create(std.testing.allocator, Console.initNull());
    defer app_ctx.destroy();

    var store = try app_ctx.envFileToKvStore(fs.cwd(), "testdata/env");
    try testing.expect(store.count() == 2);
    try testing.expectEqualStrings("value", store.get("key").?);
    try testing.expectEqualStrings("dabba", store.get("abba").?);
}

// test "extracted variables shall be expanded in next test" {
//     var allocator = std.testing.allocator;
//     var buf_test1 = try allocator.create(std.BoundedArray(u8, config.MAX_TEST_FILE_SIZE));
//     defer allocator.destroy(buf_test1);
//     buf_test1.* = try std.BoundedArray(u8, config.MAX_TEST_FILE_SIZE).fromSlice(
//         \\> GET https://some.url/api/step1
//         \\< 0
//         \\MYVAR=token:"()"
//     [0..]);

//     var buf_test2 = try allocator.create(std.BoundedArray(u8, config.MAX_TEST_FILE_SIZE));
//     defer allocator.destroy(buf_test2);
//     buf_test2.* = try std.BoundedArray(u8, config.MAX_TEST_FILE_SIZE).fromSlice(
//         \\> GET https://some.url/api/step2
//         \\--
//         \\MYVAR={{MYVAR}}
//         \\< 0
//     [0..]);

//     var app_ctx = try AppContext.create(std.testing.allocator, Console.initNull());
//     defer app_ctx.destroy();

//     var args = AppArguments{};
//     var input_vars = kvstore.KvStore{};
//     var extracted_vars = kvstore.KvStore{};
//     var variables_sets = [_]*kvstore.KvStore{ &input_vars, &extracted_vars };

//     // Mock httpclient, this can be generalized for multiple tests
//     const HttpClientOverrides = struct {
//         pub fn step1(alloc: std.mem.Allocator, _: HttpMethod, _: [:0]const u8, comptime _: httpclient.RequestParams) !httpclient.RequestResponse {
//             return .{
//                 .response_type = .Ok,
//                 .headers = null,
//                 .body = std.ArrayList(u8).fromOwnedSlice(alloc, "token:\"123123\""),
//                 .http_code = 200,
//                 .time = 0
//             };
//         }
//     };

//     // Handle step 1
//     app_ctx.httpClientRequest = HttpClientOverrides.step1;
//     Parser.expandVariablesAndFunctions(buf_test1.buffer.len, buf_test1, variables_sets[0..]) catch {};
//     try app_ctx.processAndEvaluateEntryFromBuf(1, 2, "step1"[0..], buf_test1.constSlice(), &args, &input_vars, &extracted_vars, 1, 0);
//     try testing.expect(extracted_vars.slice().len == 1);

//     // Handle step 2
//     Parser.expandVariablesAndFunctions(buf_test2.buffer.len, buf_test2, variables_sets[0..]) catch {};
//     try testing.expect(std.mem.indexOf(u8, buf_test2.constSlice(), "{{MYVAR}}") == null);
//     try testing.expect(std.mem.indexOf(u8, buf_test2.constSlice(), "MYVAR={{MYVAR}}") == null);
//     try testing.expect(std.mem.indexOf(u8, buf_test2.constSlice(), "MYVAR=123123") != null);
// }
