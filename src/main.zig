// TODO:
// * Clean up types wrt to BoundedArray-variants used for files, lists of files etc.
//   * Anything string-related; we can probably assume u8 for any custom functions at least
// * Revise all errors and error-propagation
// * Factor out common functions, ensure sets of functions+tests are colocated
// * Determine design/strategy for handling .env-files
// * Implement support for env-variables in variable-substitutions
// * Implement some common, usable functions for expression-substition - e.g. base64-encode
// * Integrate regexp-parser and implement it for response-verification and variable-extraction
// * Add test-files to stresstest the parser wrt to parse errors, overflows etc
// * Establish how to proper handle C-style strings wrt to curl-interop
// * Implement basic playbook-support?
// 
const std = @import("std");
const fs = std.fs;
const debug = std.debug.print;
const testing = std.testing;

const parser = @import("parser.zig");
const io = @import("io.zig");
const kvstore = @import("kvstore.zig");


const cURL = @cImport({
    @cInclude("curl/curl.h");
});

const GLOBAL_DEBUG = false;
const CONFIG_FILE_END = ".pi";

pub const errors = error {
    Ok,
    ParseError,
    TestsFailed
};

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
        // TODO: Return slice to out for direct use?
        // if(out.buffer.len < self.name.slice().len + 2 + self.value.slice().len+1) unreachable;

        try out.appendSlice(self.name.slice());
        try out.appendSlice(": ");
        try out.appendSlice(self.value.slice());

        // std.mem.copy(u8, out[0..], self.name.slice());
        // std.mem.copy(u8, out[self.name.slice().len..], ": ");
        // std.mem.copy(u8, out[self.name.slice().len+2..], self.value.slice());
        // out[self.name.slice().len + 2 + self.value.slice().len] = 0;
    }
};

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

const FilePathEntry = std.BoundedArray(u8, 1024);

const AppArguments = struct {
    //-v
    verbose: bool = false,
    //-d
    show_response_data: bool = false,
    //-r
    recursive: bool = false,
    //-o=<file>
    output_file: std.BoundedArray(u8,1024) = initBoundedArray(u8, 1024),
    //-f=<file>
    playbook_file: std.BoundedArray(u8,1024) = initBoundedArray(u8, 1024),
    //-s
    silent: bool = false,
    // ...
    files: std.BoundedArray(FilePathEntry,128) = initBoundedArray(FilePathEntry, 128),
};

fn printHelp() void {
    debug(
        \\
        \\sapt vX.Y.Z - Simple API Tester
        \\
        \\Example:
        \\
        \\sapt -d myfolderoffiles
        \\sapt -d myfolderoffiles/specific_test.pi
        \\
        \\Arguments
        \\  -h           Show this help
        \\  -v           Verbose
        \\  -r           Recursive
        \\  -s           Silent
        \\  -d           Show response data
        \\  -o=file      Redirect all output to file
        \\  -p=playbook  Read tests to perform from playbook-file
        \\
        , .{}
    );
}

fn parseArgs(args: [][]const u8) !AppArguments {
    var result: AppArguments = .{};

    for(args) |arg| {
        // Handle flags (-f, -s, ...)
        // Handle arguments with values (-o=...)
        // Handle rest (file/folder-arguments)
        // TODO: Revise to have a flat list of explicit checks, but split at = for such entries when comparing
        if(arg[0] == '-') {
            switch(arg.len) {
                0...1 => {
                    return error.UnknownArgument;
                },
                2 => {
                    switch(arg[1]) {
                        'h' => { return error.ShowHelp; },
                        'v' => { result.verbose = true; },
                        'r' => { result.recursive = true; },
                        's' => { result.silent = true; },
                        'd' => { result.show_response_data = true; },
                        else => { return error.UnknownArgument; }
                    }
                },
                else => {
                    // Parse key=value-types
                    var eq_pos = std.mem.indexOf(u8, arg, "=") orelse return error.InvalidArgumentFormat;

                    var key = arg[1..eq_pos];
                    var value = arg[eq_pos+1..];

                    if(std.mem.eql(u8, key, "o")) {
                        try result.output_file.appendSlice(value);
                    } else if(std.mem.eql(u8, key, "f")) {
                        try result.playbook_file.appendSlice(value);
                    }
                }

            }
        } else {
            // Is (assumed) file/folder
            // TODO: Shall we here expand folders?
            //       Alternatively, we can process this separately, add all entries to result.files and finally sort it by name
            result.files.append(FilePathEntry.fromSlice(arg) catch {
                return error.TooLongFilename;
            }) catch {
                return error.TooManyFiles;
            };
        }
    }

    return result;
}


fn processInputFileArguments(comptime max_files: usize, files: *std.BoundedArray(FilePathEntry,max_files)) !void {
    // Fail on files not matching expected name-pattern
    // Expand folders
    // Verify that files exists and are readable
    var cwd = fs.cwd();
    const readFlags = std.fs.File.OpenFlags {.read=true};
    {
        var i:usize = 0;
        var file: *FilePathEntry = undefined;
        while(i < files.slice().len) : ( i+=1 ) {
            file = &files.get(i);
            // debug("Processing: {s}\n", .{file.slice()}); # TODO: 
            // Verify that file/folder exists, otherwise fail
            cwd.access(file.constSlice(), readFlags) catch {
                debug("Can not access '{s}'\n", .{file.slice()});
                return error.NoSuchFileOrFolder;
            };

            // Try to open as dir
            var dir = cwd.openDir(file.constSlice(), .{.iterate=true}) catch |e| switch(e) {
                // Not a dir, that's OK
                error.NotDir => continue,
                else => return error.UnknownError,
            };
            defer dir.close();

            var d_it = dir.iterate();
            while (try d_it.next()) |a_path| {
                var stat = try (try dir.openFile(a_path.name, readFlags)).stat();
                switch(stat.kind) {
                    .File => {
                        // TODO: Ignore .env and non-.pi files here?
                        // TODO: If we shall support .env-files pr folder/suite, then we will perhaps need to keep track of "suites" internally as well?

                        var item = initBoundedArray(u8, 1024);
                        try item.appendSlice(file.constSlice());
                        try item.appendSlice("/");
                        try item.appendSlice(a_path.name);
                        // Add to files
                        try files.append(item);
                    },
                    .Directory => {
                        debug("Found subdir: {s}\n", .{a_path.name});
                        // If recursive: process
                    },
                    else => {}
                }
            }
        }
    }

    // Remove all folders
    for(files.slice()) |file, i| {
        _ = cwd.openDir(file.constSlice(), .{.iterate=true}) catch {
            // Not a dir, leave alone
            continue;
        };
        
        // Dir, remove
        _ = files.swapRemove(i);
    }

    // Sort the remainding entries
    std.sort.sort(FilePathEntry, files.slice(), {}, struct {
            fn func(context: void, a: FilePathEntry, b: FilePathEntry) bool {
                _ = context;
                return std.mem.lessThan(u8, a.constSlice(), b.constSlice());
            }
        }.func);

}

test "parseArgs" {
    const default_args: AppArguments = .{};

    {
        var myargs = [_][]const u8{};
        var parsed_args = try parseArgs(myargs[0..]);
        try testing.expect(parsed_args.verbose == default_args.verbose);
    }

    {
        var myargs = [_][]const u8{"-v"};
        var parsed_args = try parseArgs(myargs[0..]);
        try testing.expect(parsed_args.verbose);
    }

    {
        var myargs = [_][]const u8{"-r"};
        var parsed_args = try parseArgs(myargs[0..]);
        try testing.expect(parsed_args.recursive);
    }

    {
        var myargs = [_][]const u8{"-s"};
        var parsed_args = try parseArgs(myargs[0..]);
        try testing.expect(parsed_args.silent);
    }

    {
        var myargs = [_][]const u8{"somefile"};
        var parsed_args = try parseArgs(myargs[0..]);
        try testing.expect(parsed_args.files.slice().len == 1);
        try testing.expectEqualStrings("somefile", parsed_args.files.get(0).slice());
    }

    {
        var myargs = [_][]const u8{"-o=myoutfile"};
        var parsed_args = try parseArgs(myargs[0..]);
        try testing.expectEqualStrings("myoutfile", parsed_args.output_file.slice());
    }

    {
        var myargs = [_][]const u8{"-f=myplaybook"};
        var parsed_args = try parseArgs(myargs[0..]);
        try testing.expectEqualStrings("myplaybook", parsed_args.playbook_file.slice());
    }
}

test "processInputFileArguments" {
    var files: std.BoundedArray(FilePathEntry,128) = initBoundedArray(FilePathEntry, 128);
    try files.append(try FilePathEntry.fromSlice("testdata/01-warnme"));

    try processInputFileArguments(128, &files);

    // TODO: Verify all elements are parsed and in proper order
    // Cases:
    //   * If file, no need to expand
    //   * If folder and no -r, expand contents only one leve
    //   * If folder and -r, expand end recurse
}

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
    if(GLOBAL_DEBUG or args.verbose) {
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
    entry.result.response_match = std.mem.indexOf(u8, response_buffer.items, entry.expected_response_regex.slice()) != null;
    try entry.result.response_first_1mb.resize(0);
    try entry.result.response_first_1mb.appendSlice(sliceUpTo(u8, response_buffer.items, 0, entry.result.response_first_1mb.capacity()));
}

fn evaluateEntryResult(entry: *Entry) bool {
    return entry.expected_http_code == 0 or entry.expected_http_code == entry.result.response_http_code;
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
            debug("WARNING: Could not find match for '{s}={s}'\n", .{v.name.constSlice(), v.expression.constSlice()});
        }
    }

}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = &arena.allocator;
    const args = try std.process.argsAlloc(aa);
    defer std.process.argsFree(aa, args);

    var buf = initBoundedArray(u8, 1024*1024);

    if (cURL.curl_global_init(cURL.CURL_GLOBAL_ALL) != cURL.CURLE_OK)
        return error.CURLGlobalInitFailed;
    defer cURL.curl_global_cleanup();

    var num_processed: u64 = 0;
    var num_failed: u64 = 0;
    // TODO: Filter input-set first, to get the proper number of items? Or at least count them up

    debug(
        \\
        \\API-tester by Michael Odden
        \\------------------
        \\
        , .{}
    );

    var parsed_args = parseArgs(args[1..]) catch {
        printHelp();
        return error.MissingArgs;
    };

    try processInputFileArguments(parsed_args.files.buffer.len, &parsed_args.files);

    var extracted_vars: kvstore.KvStore = .{};
    const time_start = std.time.milliTimestamp();
    for (parsed_args.files.slice()) |file, i| {

        if(!std.mem.endsWith(u8, file.constSlice(), CONFIG_FILE_END)) continue;
        
        num_processed += 1;

        //////////////////
        // Process
        //////////////////
        var entry = Entry{};

        debug("{d}: {s:<64}:", .{i+1, file.constSlice()});

        io.readFile(u8, buf.buffer.len, file.constSlice(), &buf) catch {
            debug("ERROR: Could not read file: {s}\n", .{file.constSlice()});
            num_failed += 1;
            continue;
        };

        // Expand all variables
        try parser.expandVariablesAndFunctions(buf.buffer.len, &buf, extracted_vars.store.slice());

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
            if(parsed_args.verbose) for(extracted_vars.store.slice()) |v| {
                debug("kv: {s}={s}\n", .{v.key.constSlice(), v.value.constSlice()});
            };

        //   debug("{s} (HTTP {d})\n", .{result_string, entry.result.response_http_code});
        } else {
            num_failed += 1;
            debug("{s} {s:<64}\n", .{entry.method, entry.url.slice()});
            if(entry.result.response_http_code != entry.expected_http_code) {
                debug("Expected HTTP {d}, got {d}\n", .{entry.expected_http_code, entry.result.response_http_code});
            }

            if(!entry.result.response_match) {
                debug("Match requirement '{s}' was not successful\n", .{entry.expected_response_regex});
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

// Convenience-function to initiate a bounded-array without inital size of 0, removing the error-case brough by .init(size)
pub fn initBoundedArray(comptime T: type, comptime capacity: usize) std.BoundedArray(T,capacity) {
    return std.BoundedArray(T, capacity){.buffer=undefined};
}

test "HttpHeader.render" {
    // var mybuf : [128:0]u8 = [_:0]u8{65}**128;
    var mybuf = initBoundedArray(u8, 2048);

    var header = try HttpHeader.create("Accept", "application/xml");
    
    // debug("line: '{s}'\n", .{header.cstr(&mybuf)});
    try header.render(mybuf.buffer.len, &mybuf);
    try testing.expectEqualStrings("Accept: application/xml", mybuf.slice());
}


