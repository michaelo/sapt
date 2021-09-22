const std = @import("std");
const fs = std.fs;
const debug = std.debug.print;
const testing = std.testing;

const errors = error {
    Ok,
    ParseError,
    TestsFailed
};

const HttpMethod = enum {
    Get,
    Post,
    Put,
    Delete
};

const cURL = @cImport({
    @cInclude("curl/curl.h");
});

fn writeToArrayListCallback(data: *c_void, size: c_uint, nmemb: c_uint, user_data: *c_void) callconv(.C) c_uint {
    var buffer = @intToPtr(*std.ArrayList(u8), @ptrToInt(user_data));
    var typed_data = @intToPtr([*]u8, @ptrToInt(data));
    buffer.appendSlice(typed_data[0 .. nmemb * size]) catch return 0;
    return nmemb * size;
}

// TODO: Take Entry and build request accordingly
pub fn processEntry(entry: *Entry) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    var allocator = &arena_state.allocator;

    // global curl init, or fail
    if (cURL.curl_global_init(cURL.CURL_GLOBAL_ALL) != cURL.CURLE_OK)
        return error.CURLGlobalInitFailed;
    defer cURL.curl_global_cleanup();

    // curl easy handle init, or fail
    const handle = cURL.curl_easy_init() orelse return error.CURLHandleInitFailed;
    defer cURL.curl_easy_cleanup(handle);

    // TODO: Can get rid of heap
    var response_buffer = std.ArrayList(u8).init(allocator);
    defer response_buffer.deinit();

    // setup curl options
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_URL, entry.url.slice().ptr) != cURL.CURLE_OK)
        return error.CouldNotSetURL;

    // set write function callbacks
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_WRITEFUNCTION, writeToArrayListCallback) != cURL.CURLE_OK)
        return error.CouldNotSetWriteCallback;
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_WRITEDATA, &response_buffer) != cURL.CURLE_OK)
        return error.CouldNotSetWriteCallback;

    // perform
    if (cURL.curl_easy_perform(handle) != cURL.CURLE_OK)
        return error.FailedToPerformRequest;

    var http_code: u64 = 0;
    _ = cURL.curl_easy_getinfo(handle, cURL.CURLINFO_RESPONSE_CODE, &http_code);
    // debug("Got code: {d} for url {s}\n", .{http_code, url});
    // try testing.expect(expected_http_code == http_code);
    entry.result.response_http_code = http_code;

    // TODO: Replace str-match with proper regexp handling
    entry.result.response_match = std.mem.indexOf(u8, response_buffer.items, entry.expected_response_regex.slice()) != null;
    // TODO: Log response if given parameter? 
}

pub fn evaluateEntryResult(entry: *Entry) bool {
    return entry.expected_http_code == entry.result.response_http_code;
}

pub fn main() anyerror!void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = &general_purpose_allocator.allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var buf = initBoundedArray(u8, 1024*1024);

    for (args[1..]) |arg, i| {
        // std.debug.print("{}: {s}\n", .{ i, arg });
        try readFile(u8, buf.buffer.len, arg, &buf);
        // debug(
        //     \\Processing: {s}
        //     \\Contents:
        //     \\{s}
        //     \\
        //     , .{arg, buf.slice()});

        var entry = Entry.create();
        try parseContents(buf.slice(), &entry);
        try entry.url.append(0); // TODO: create a function that takes a slice and copies it to a sentinel-terminated c-str
        // debug("About to check URL: {s}\n", .{entry.url.slice()});
        // const sentinel_ptr = @ptrCast([*:0]const u8, &entry.url.buffer);
        // try request(std.mem.sliceTo(sentinel_ptr,0), entry.expected_http_code, null);
        try processEntry(&entry);
        debug("{d}/{d} {s:<64}: {s} {s:<64}: {d}\n", .{i+1, args.len-1, arg, entry.method, entry.url.slice(), evaluateEntryResult(&entry)});
        // std.mem.sliceTo(&buf.buffer, 0)
        // TODO: Arg parse handling
        // if not a flag, assume it's a folder or file, and parse/process accordingly
    }
}

pub fn readFileRaw(path: []const u8, target_buf: []u8) !usize {
    // Reads contents and store in target_buf
    var file = try fs.cwd().openFile(path, .{.read=true});
    defer file.close();

    return try file.readAll(target_buf[0..]);
}

pub fn readFile(comptime T:type, comptime S:usize, path: []const u8, target_buf: *std.BoundedArray(T, S)) !void {
    // Reads contents and store in target_buf
    var file = try fs.cwd().openFile(path, .{.read=true});
    defer file.close();

    const size = try file.getEndPos();
    try target_buf.resize(std.math.min(size, target_buf.capacity()));
    _ = try file.readAll(target_buf.slice()[0..]);
}

test "readFile" {
    var buf = initBoundedArray(u8, 1024*1024);
    try testing.expect(buf.slice().len == 0);
    try readFile(u8, buf.buffer.len, "testdata/01-warnme/01-warnme-stats.pi", &buf);
    try testing.expect(buf.slice().len > 0);
}

test "readFileRaw" {
    var buf = initBoundedArray(u8, 1024*1024);
    try testing.expect(buf.slice().len == 0);
    try buf.resize(try readFileRaw("testdata/01-warnme/01-warnme-stats.pi", buf.buffer[0..]));
    try testing.expect(buf.slice().len > 0);
}

const HttpHeader = struct {
    name: std.BoundedArray(u8,256),
    value: std.BoundedArray(u8,1024),
    pub fn create(name: []const u8, value: []const u8) !HttpHeader {
        return HttpHeader {
            .name = std.BoundedArray(u8,256).fromSlice(std.mem.trim(u8, name, " ")) catch { return errors.ParseError; },
            .value = std.BoundedArray(u8,1024).fromSlice(std.mem.trim(u8, value, " ")) catch { return errors.ParseError; },
        };
    }
};

// TODO: Test if we can use e.g. initBoundedArray(u8, 1024) for default-init to get rid of .create()
const Entry = struct {
    name: std.BoundedArray(u8,1024),
    method: HttpMethod,
    url: std.BoundedArray(u8,2048),
    headers: std.BoundedArray(HttpHeader,32), // TODO: Make BoundedArray of HttpHeader?
    payload: std.BoundedArray(u8,1024*1024),
    expected_http_code: u64, // 0 == don't care
    expected_response_regex: std.BoundedArray(u8,1024),
    result: struct {
        response_http_code: u64 = 0,
        response_match: bool = false,
    },

    pub fn create() Entry {
        return Entry {
            .name = initBoundedArray(u8, 1024),
            .method = undefined,
            .url =  initBoundedArray(u8, 2048),
            .headers = initBoundedArray(HttpHeader, 32), // [_]std.BoundedArray(u8, 256){initBoundedArray(u8, 256)}**32,
            .payload = initBoundedArray(u8, 1024*1024),
            .expected_http_code = 0,
            .expected_response_regex = initBoundedArray(u8, 1024),
            .result = .{},
        };
    }
};

// fn run_entry(entry: *Entry) !void {
//     // 
// }

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

fn parseContents(data: []const u8, result: *Entry) errors!void {
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
            }
        }
    }
}

// Convenience-function to initiate a bounded-array without inital size of 0, removing the error-case brough by .init(size)
fn initBoundedArray(comptime T: type, comptime capacity: usize) std.BoundedArray(T,capacity) {
    return (std.BoundedArray(T, capacity)){.buffer=undefined};
}

test "string exploration" {
    const str1 = "test";
    var buf = initBoundedArray(u8, 64);

    try testing.expect(buf.buffer.len == 64);
    try testing.expect(str1.len == 4);
    try testing.expect(buf.slice().len == 0);
    try buf.insertSlice(0, str1);
    try testing.expect(buf.slice().len == 4);
}


test "parseContents" {
    var entry = Entry.create();

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


test "Casting to sentinel" {
    var mystr = "hei";
    var buf = initBoundedArray(u8, 128);
    try buf.insertSlice(0, "hei");
    try buf.append(0);
    debug("type: {s}\n", .{@TypeOf(mystr)});
    debug("type: {s}\n", .{@TypeOf(buf.slice())});


    debug("type: {s}\n", .{@TypeOf(std.mem.sliceTo(&buf.buffer, 0))});
    const sentinel_ptr = @ptrCast([*:0]u8, &buf.buffer);
    debug("type: {s}\n", .{@TypeOf(sentinel_ptr)});

    debug("value: {s}\n", .{buf.slice()});
    debug("value: {s}\n", .{std.mem.sliceTo(sentinel_ptr, 0)});
}

test "string find" {
    var mystr = "Woop di doo";
    try testing.expect(null == std.mem.indexOf(u8, mystr, "dim"));
    try testing.expect(5 == std.mem.indexOf(u8, mystr, "di").?);
}