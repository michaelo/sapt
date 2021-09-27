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

pub fn httpMethodToStr(method: HttpMethod) [*]const u8 {
    return switch(method) {
        HttpMethod.Get => "GET",
        HttpMethod.Post => "POST",
        HttpMethod.Put => "PUT",
        HttpMethod.Delete => "DELETE"
    };
}

pub const HttpHeader = struct {
    name: std.BoundedArray(u8,256),
    value: std.BoundedArray(u8,1024),
    pub fn create(name: []const u8, value: []const u8) !HttpHeader {
        return HttpHeader {
            .name = std.BoundedArray(u8,256).fromSlice(std.mem.trim(u8, name, " ")) catch { return errors.ParseError; },
            .value = std.BoundedArray(u8,1024).fromSlice(std.mem.trim(u8, value, " ")) catch { return errors.ParseError; },
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

/// Att! This adds a terminating zero at current .slice().len
fn boundedArrayAsCstr(comptime capacity: usize, array: *std.BoundedArray(u8, capacity)) [*]u8 {
    if(array.slice().len >= array.capacity()) unreachable;

    array.buffer[array.slice().len] = 0;
    return array.slice().ptr;
}

// TODO: Test if we can use e.g. initBoundedArray(u8, 1024) for default-init to get rid of .create()
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
    } = .{},
};

fn writeToArrayListCallback(data: *c_void, size: c_uint, nmemb: c_uint, user_data: *c_void) callconv(.C) c_uint {
    var buffer = @intToPtr(*std.ArrayList(u8), @ptrToInt(user_data));
    var typed_data = @intToPtr([*]u8, @ptrToInt(data));
    buffer.appendSlice(typed_data[0 .. nmemb * size]) catch return 0;
    return nmemb * size;
}

/// Primary worker function performing the request and handling the response
fn processEntry(entry: *Entry) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    var allocator = &arena_state.allocator;

    //////////////////////////////
    // Init / generic setup
    //////////////////////////////

    // TODO: Not necessary to do global_init pr request/test?
    if (cURL.curl_global_init(cURL.CURL_GLOBAL_ALL) != cURL.CURLE_OK)
        return error.CURLGlobalInitFailed;
    defer cURL.curl_global_cleanup();

    const handle = cURL.curl_easy_init() orelse return error.CURLHandleInitFailed;
    defer cURL.curl_easy_cleanup(handle);

    // TODO: Shall we get rid off heap?
    var response_buffer = std.ArrayList(u8).init(allocator);
    defer response_buffer.deinit();

    ///////////////////////
    // Setup curl options
    ///////////////////////

    // Set HTTP method
    _ = cURL.curl_easy_setopt(handle, cURL.CURLOPT_CUSTOMREQUEST, httpMethodToStr(entry.method));

    // Set URL
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_URL, boundedArrayAsCstr(entry.url.buffer.len, &entry.url)) != cURL.CURLE_OK)
        return error.CouldNotSetURL;

    // Set Payload (if given)
    if(entry.method == .Post or entry.method == .Put or entry.payload.slice().len > 0) {
        _ = cURL.curl_easy_setopt(handle, cURL.CURLOPT_POSTFIELDSIZE, entry.payload.slice().len);
        _ = cURL.curl_easy_setopt(handle, cURL.CURLOPT_POSTFIELDS, boundedArrayAsCstr(entry.payload.buffer.len, &entry.payload));
    }

    // // Debug
    const on:c_long = 1;
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_VERBOSE, on) != cURL.CURLE_OK)
        return error.CouldNotSetVerbose;

    // Pass headers
    var list: ?*cURL.curl_slist = null;
    defer cURL.curl_slist_free_all(list);
    
    // TODO: Iterate over entry and add headers
    var header_buf = initBoundedArray(u8, 2048);
    for(entry.headers.slice()) |*header| {
        try header_buf.resize(0);
        try header.render(header_buf.buffer.len, &header_buf);
        list = cURL.curl_slist_append(list, boundedArrayAsCstr(header_buf.buffer.len, &header_buf));
    }
    // list = cURL.curl_slist_append(list, "Content-Type: text/xml");
    // list = cURL.curl_slist_append(list, "Accept: text/xml");
    
    _ = cURL.curl_easy_setopt(handle, cURL.CURLOPT_HTTPHEADER, list);

    //////////////////////
    // Execute
    //////////////////////
    // set write function callbacks
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_WRITEFUNCTION, writeToArrayListCallback) != cURL.CURLE_OK)
        return error.CouldNotSetWriteCallback;
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_WRITEDATA, &response_buffer) != cURL.CURLE_OK)
        return error.CouldNotSetWriteCallback;


    // perform
    if (cURL.curl_easy_perform(handle) != cURL.CURLE_OK)
        return error.FailedToPerformRequest;

    ////////////////////////
    // Handle results
    ////////////////////////
    var http_code: u64 = 0;
    _ = cURL.curl_easy_getinfo(handle, cURL.CURLINFO_RESPONSE_CODE, &http_code);

    entry.result.response_http_code = http_code;

    // TODO: Replace str-match with proper regexp handling
    entry.result.response_match = std.mem.indexOf(u8, response_buffer.items, entry.expected_response_regex.slice()) != null;
    // TODO: Log response if given parameter? 
}

fn evaluateEntryResult(entry: *Entry) bool {
    return entry.expected_http_code == 0 or entry.expected_http_code == entry.result.response_http_code;
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

        var entry = Entry{};
        try entry.name.insertSlice(0, arg);
        try parser.parseContents(buf.slice(), &entry);
        try processEntry(&entry);
        debug("{d}/{d} {s:<64}: {s} {s:<64}: {d} ({d})\n", .{i+1, args.len-1, entry.name.slice(), entry.method, entry.url.slice(), evaluateEntryResult(&entry), entry.result.response_http_code});
        // std.mem.sliceTo(&buf.buffer, 0)
        // TODO: Arg parse handling
        // if not a flag, assume it's a folder or file, and parse/process accordingly
    }
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


