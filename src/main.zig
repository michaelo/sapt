// TODO:
// * Clean up types wrt to BoundedArray-variants used for files, lists of files etc.
//   * Anything string-related; we can probably assume u8 for any custom functions at least
// * Revise all errors and error-propagation
// * Factor out common functions, ensure sets of functions+tests are colocated
// * Determine design/strategy for handling .env-files
// * Implement support for env-variables in variable-substitutions
// * Implement some common, usable functions for expression-substition - e.g. base64-encode
// * Add test-files to stresstest the parser wrt to parse errors, overflows etc
// * Establish how to proper handle C-style strings wrt to curl-interop
// * Implement basic playbook-support?
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


const cURL = @cImport({
    @cInclude("curl/curl.h");
});

pub const errors = error {
    Ok,
    ParseError,
    TestsFailed
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
    result: struct {
        response_http_code: u64 = 0,
        response_match: bool = false,
        response_first_1mb: std.BoundedArray(u8,1024*1024) = initBoundedArray(u8, 1024*1024),
    } = .{},
};

pub const FilePathEntry = std.BoundedArray(u8, config.MAX_PATH_LEN);

pub const AppArguments = struct {
    //-v
    verbose: bool = false,
    //-d
    show_response_data: bool = false,
    //-r
    recursive: bool = false,
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
fn processEntry(entry: *Entry, args: AppArguments) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    var allocator = &arena_state.allocator;

    //////////////////////////////
    // Init / generic setup
    //////////////////////////////
    const handle = cURL.curl_easy_init() orelse return error.CURLHandleInitFailed;
    defer cURL.curl_easy_cleanup(handle);

    // TODO: Shall we get rid of heap?
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

    // TODO: Replace str-match with proper regexp handling
    try entry.result.response_first_1mb.resize(0);
    try entry.result.response_first_1mb.appendSlice(sliceUpTo(u8, response_buffer.items, 0, entry.result.response_first_1mb.capacity()));
}

fn evaluateEntryResult(entry: *Entry) bool {
    if(entry.expected_response_regex.constSlice().len > 0 and std.mem.indexOf(u8, entry.result.response_first_1mb.constSlice(), entry.expected_response_regex.constSlice()) == null) {
        entry.result.response_match = false;
        return false;
    }
    entry.result.response_match = true;

    if(entry.expected_http_code != 0 and entry.expected_http_code != entry.result.response_http_code) return false;

    return true;
}

/// Returns a slice from <from> up to <to> or slice.len
fn sliceUpTo(comptime T: type, slice: []T, from: usize, to: usize) []T {
    return slice[from..std.math.min(slice.len, to)];
}

fn processEntryMain(entry: *Entry, args: AppArguments, buf: []const u8, name: []const u8) !void {
    _ = name;
    // try entry.name.insertSlice(0, name);
    try parser.parseContents(buf, entry); // TODO: catch and gracefully fail, allowing further cases to be run? 
    try processEntry(entry, args); // TODO: catch and gracefully fail, allowing further cases to be run? 
}

fn extractExtractionEntries(entry: Entry, store: *kvstore.KvStore) !void {
        // Extract to variables
    for(entry.extraction_entries.constSlice()) |v| {
        if(parser.expressionExtractor(entry.result.response_first_1mb.constSlice(), v.expression.constSlice())) |expression_result| {
            // Got match
            try store.add(v.name.constSlice(), expression_result.result);
        } else {
            // TODO: Should be error?
            debug("Could not find match for '{s}={s}'\n", .{v.name.constSlice(), v.expression.constSlice()});
        }
    }

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

    var num_processed: u64 = 0;
    var num_failed: u64 = 0;
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


    var extracted_vars: kvstore.KvStore = .{};
    const time_start = std.time.milliTimestamp();
    for (parsed_args.files.slice()) |file| {

        if(!std.mem.endsWith(u8, file.constSlice(), config.CONFIG_FILE_EXT_TEST)) continue;
        
        num_processed += 1;

        //////////////////
        // Process
        //////////////////
        var entry = Entry{};

        debug("{d}: {s:<64}:", .{num_processed, file.constSlice()});

        io.readFile(u8, buf.buffer.len, file.constSlice(), &buf) catch {
            debug("ERROR: Could not read file: {s}\n", .{file.constSlice()});
            num_failed += 1;
            continue;
        };

        // Expand all variables
        parser.expandVariablesAndFunctions(buf.buffer.len, &buf, &extracted_vars) catch {};
        parser.expandVariablesAndFunctions(buf.buffer.len, &buf, &input_vars) catch {};


        // Process
        processEntryMain(&entry, parsed_args, buf.constSlice(), file.constSlice()) catch |e| {
            // TODO: Switch on e and print more helpful error messages. Also: revise and provide better errors in inner functions 
            debug("ERROR: Got error: {s}\n", .{e});
            num_failed += 1;
            continue;
        };


        //////////////////
        // Evaluate results
        //////////////////

        var conclusion = evaluateEntryResult(&entry);
        var result_string = if(conclusion) "OK" else "ERROR";
        debug("{s} (HTTP {d})\n", .{result_string, entry.result.response_http_code});
        
        // Expanded output - by default if error
        if (conclusion) {
            // No need to extract if not successful
            try extractExtractionEntries(entry, &extracted_vars);

            // Print all stored variables
            if(parsed_args.verbose and extracted_vars.store.slice().len > 0) {
                debug("Values extracted from response:\n", .{});
                debug("-"**80 ++ "\n", .{});
                for(extracted_vars.store.slice()) |v| {
                    debug("* {s}={s}\n", .{v.key.constSlice(), v.value.constSlice()});
                }
                debug("-"**80 ++ "\n", .{});
            }
        } else {
            num_failed += 1;
            debug("{s} {s:<64}\n", .{entry.method, entry.url.slice()});
            if(entry.result.response_http_code != entry.expected_http_code) {
                debug("Expected HTTP {d}, got {d}\n", .{entry.expected_http_code, entry.result.response_http_code});
            }

            if(!entry.result.response_match) {
                debug("Match requirement '{s}' was not successful\n", .{entry.expected_response_regex.constSlice()});
            }
        }

        if(!conclusion or parsed_args.verbose or parsed_args.show_response_data) {
            debug("Response (up to 1024KB):\n{s}\n\n", .{sliceUpTo(u8, entry.result.response_first_1mb.slice(), 0, 1024*1024)});
        }
    }
    const time_end = std.time.milliTimestamp();
    debug(
        \\------------------
        \\{d}/{d} OK
        \\------------------
        \\FINISHED - total time: {d}s
        \\
        , .{num_processed-num_failed, num_processed, @intToFloat(f64, time_end-time_start)/1000}
    );
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
