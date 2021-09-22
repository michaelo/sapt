const std = @import("std");
const fs = std.fs;
const debug = std.debug.print;
const testing = std.testing;

const parser = @import("parser.zig");
const io = @import("io.zig");

const cURL = @cImport({
    @cInclude("curl/curl.h");
});


pub const errors = error {
    Ok,
    ParseError,
    TestsFailed
};

pub const HttpMethod = enum {
    Get,
    Post,
    Put,
    Delete
};

pub const HttpHeader = struct {
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
pub const Entry = struct {
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
        try io.readFile(u8, buf.buffer.len, arg, &buf);

        var entry = Entry.create();
        try entry.name.insertSlice(0, arg);
        try parser.parseContents(buf.slice(), &entry);
        try entry.url.append(0); // TODO: create a function that takes a slice and copies it to a sentinel-terminated c-str where we need it for interop.
        // debug("About to check URL: {s}\n", .{entry.url.slice()});
        // const sentinel_ptr = @ptrCast([*:0]const u8, &entry.url.buffer);
        // try request(std.mem.sliceTo(sentinel_ptr,0), entry.expected_http_code, null);
        try processEntry(&entry);
        debug("{d}/{d} {s:<64}: {s} {s:<64}: {d}\n", .{i+1, args.len-1, entry.name.slice(), entry.method, entry.url.slice(), evaluateEntryResult(&entry)});
        // std.mem.sliceTo(&buf.buffer, 0)
        // TODO: Arg parse handling
        // if not a flag, assume it's a folder or file, and parse/process accordingly
    }
}

// Convenience-function to initiate a bounded-array without inital size of 0, removing the error-case brough by .init(size)
fn initBoundedArray(comptime T: type, comptime capacity: usize) std.BoundedArray(T,capacity) {
    return (std.BoundedArray(T, capacity)){.buffer=undefined};
}

