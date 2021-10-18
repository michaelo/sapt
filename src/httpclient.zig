const std = @import("std");
const main = @import("main.zig");
const types = @import("types.zig");
const utils = @import("utils.zig");

const cURL = @cImport({
    @cInclude("curl/curl.h");
});

fn writeToArrayListCallback(data: *c_void, size: c_uint, nmemb: c_uint, user_data: *c_void) callconv(.C) c_uint {
    var buffer = @intToPtr(*std.ArrayList(u8), @ptrToInt(user_data));
    var typed_data = @intToPtr([*]u8, @ptrToInt(data));
    buffer.appendSlice(typed_data[0 .. nmemb * size]) catch return 0;
    return nmemb * size;
}

pub fn init() !void {
    if (cURL.curl_global_init(cURL.CURL_GLOBAL_ALL) != cURL.CURLE_OK)
        return error.CURLGlobalInitFailed;
}

pub fn deinit() void {
    cURL.curl_global_cleanup();
}

/// Primary worker function performing the request and handling the response
pub fn processEntry(entry: *main.Entry, args: main.AppArguments, result: *main.EntryResult) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

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
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_CUSTOMREQUEST, entry.method.string()) != cURL.CURLE_OK)
        return error.CouldNotSetRequestMethod;

    // Set URL
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_URL, utils.boundedArrayAsCstr(entry.url.buffer.len, &entry.url)) != cURL.CURLE_OK)
        return error.CouldNotSetURL;

    // Set Payload (if given)
    if (entry.method == .Post or entry.method == .Put or entry.payload.slice().len > 0) {
        if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_POSTFIELDSIZE, entry.payload.slice().len) != cURL.CURLE_OK)
            return error.CouldNotSetPostDataSize;
        if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_POSTFIELDS, utils.boundedArrayAsCstr(entry.payload.buffer.len, &entry.payload)) != cURL.CURLE_OK)
            return error.CouldNotSetPostData;
    }

    // Debug
    if (args.verbose_curl) {
        if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_VERBOSE, @intCast(c_long, 1)) != cURL.CURLE_OK)
            return error.CouldNotSetVerbose;
    }

    // Pass headers
    var list: ?*cURL.curl_slist = null;
    defer cURL.curl_slist_free_all(list);

    var header_buf = utils.initBoundedArray(u8, types.HttpHeader.MAX_VALUE_LEN);
    for (entry.headers.slice()) |*header| {
        try header_buf.resize(0);
        try header.render(header_buf.buffer.len, &header_buf);
        list = cURL.curl_slist_append(list, utils.boundedArrayAsCstr(header_buf.buffer.len, &header_buf));
    }

    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_HTTPHEADER, list) != cURL.CURLE_OK)
        return error.CouldNotSetHeaders;

    //////////////////////
    // Execute
    //////////////////////
    // set write function callbacks
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_WRITEFUNCTION, writeToArrayListCallback) != cURL.CURLE_OK)
        return error.CouldNotSetWriteCallback;
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_WRITEDATA, &response_buffer) != cURL.CURLE_OK)
        return error.CouldNotSetWriteCallback;

    // TODO: Timer start
    // Perform
    if (cURL.curl_easy_perform(handle) != cURL.CURLE_OK)
        return error.FailedToPerformRequest;
    // TODO: Timer end

    ////////////////////////
    // Handle results
    ////////////////////////
    var http_code: u64 = 0;
    if (cURL.curl_easy_getinfo(handle, cURL.CURLINFO_RESPONSE_CODE, &http_code) != cURL.CURLE_OK)
        return error.CouldNewGetResponseCode;

    result.response_http_code = http_code;

    var content_type_ptr: [*c]u8 = null;
    if (cURL.curl_easy_getinfo(handle, cURL.CURLINFO_CONTENT_TYPE, &content_type_ptr) != cURL.CURLE_OK)
        return error.CouldNewGetResponseContentType;

    // Get Content-Type
    // TODO: Check of pointer being NULL in case no Content-Type specified?
    if (content_type_ptr != null) {
        var content_type_slice = try std.fmt.bufPrint(&result.response_content_type.buffer, "{s}", .{content_type_ptr});
        try result.response_content_type.resize(content_type_slice.len);
    }

    try result.response_first_1mb.resize(0);
    try result.response_first_1mb.appendSlice(utils.sliceUpTo(u8, response_buffer.items, 0, result.response_first_1mb.capacity()));
}

pub fn httpCodeToString(code: u64) []const u8 {
    return switch (code) {
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
