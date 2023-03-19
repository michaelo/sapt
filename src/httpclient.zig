const std = @import("std");
const print = std.debug.print;

const cURL = @cImport({
    @cInclude("curl/curl.h");
});

pub const HttpMethod = enum {
    CONNECT,
    DELETE,
    GET,
    HEAD,
    OPTIONS,
    PATCH,
    POST,
    PUT,
    TRACE,

    pub fn string(self: HttpMethod) [:0]const u8 {
        return @tagName(self);
    }
    pub fn create(raw: []const u8) !HttpMethod {
        return std.meta.stringToEnum(HttpMethod, raw) orelse error.NoSuchHttpMethod;
    }
};

pub const RequestResponseType = enum { Error, Ok };

pub const RequestResponse = struct {
    response_type: RequestResponseType,
    headers: ?std.ArrayList(u8),
    body: ?std.ArrayList(u8),
    http_code: usize,
    time: i64,

    pub fn deinit(self: @This()) void {
        if (self.body) |v| v.deinit();
        if (self.headers) |v| v.deinit();
    }

    pub fn getHeader(self: @This(), comptime header: []const u8) ![]const u8 {
        var key = header ++ ":";
        if (self.headers) |aheaders| {
            if (std.ascii.indexOfIgnoreCase(aheaders.items, key)) |idx| {
                // Parse until eol. Not standards-compliant right now as headers are really allowed to span multiple lines.
                if (std.mem.indexOfPos(u8, aheaders.items, idx, "\r\n")) |eol| {
                    return std.mem.trim(u8, aheaders.items[idx + key.len .. eol], " \t");
                } else {
                    return error.InvalidHdeader;
                }
            } else {
                return error.HeaderNotFound;
            }
        } else {
            return error.HeadersNotCaptured;
        }
    }

    pub fn contentType(self: @This()) ![]const u8 {
        return self.getHeader("Content-Type");
    }
};

fn writeToArrayListCallback(data: *anyopaque, size: c_uint, nmemb: c_uint, user_data: *anyopaque) callconv(.C) c_uint {
    var buffer = @intToPtr(*std.ArrayList(u8), @ptrToInt(user_data));
    var typed_data = @intToPtr([*]u8, @ptrToInt(data));
    buffer.appendSlice(typed_data[0 .. nmemb * size]) catch return 0;
    return nmemb * size;
}

pub const RequestParams = struct {
    headers: ?[][:0]const u8 = null,
    follow_redirect: bool = true,
    insecure: bool = false,
    store_headers: bool = true,
    store_body: bool = true,
    verbose: bool = false,
    payload: ?[:0]const u8 = null,
};

/// Main API
pub fn request(allocator: std.mem.Allocator, method: HttpMethod, url: [:0]const u8, comptime params: RequestParams) !RequestResponse {
    if (is_inited) return error.NotInited;

    //////////////////////////////
    // Init / generic setup
    //////////////////////////////
    const handle = cURL.curl_easy_init() orelse return error.CURLHandleInitFailed;
    defer cURL.curl_easy_cleanup(handle);

    var body_payload: ?std.ArrayList(u8) = null;
    var headers_payload: ?std.ArrayList(u8) = null;

    if (params.store_body) {
        body_payload = std.ArrayList(u8).init(allocator);
        errdefer body_payload.?.deinit();

        if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_WRITEDATA, &body_payload) != cURL.CURLE_OK) {
            return error.CouldNotSetWriteCallback;
        }
    }

    if (params.store_headers) {
        headers_payload = std.ArrayList(u8).init(allocator);
        errdefer headers_payload.?.deinit();

        if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_HEADERDATA, &headers_payload) != cURL.CURLE_OK) {
            return error.CouldNotSetWriteCallback;
        }
    }

    // Initiate
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_CUSTOMREQUEST, HttpMethod.string(method).ptr) != cURL.CURLE_OK) {
        return error.CouldNotSetRequestMethod;
    }

    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_URL, url.ptr) != cURL.CURLE_OK) {
        return error.CouldNotSetURL;
    }

    // insecure?
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_SSL_VERIFYPEER, @intCast(c_long, @boolToInt(params.insecure))) != cURL.CURLE_OK) {
        return error.CouldNotSetSslVerifyPeer;
    }

    // TODO: Now headers will currently be appended for all requests. Need to clean headers when redirected...
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_FOLLOWLOCATION, @intCast(c_long, @boolToInt(params.follow_redirect))) != cURL.CURLE_OK) {
        return error.CouldNotSetFollow;
    }

    // Verbosity
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_VERBOSE, @intCast(c_long, @boolToInt(params.verbose))) != cURL.CURLE_OK) {
        return error.CouldNotSetVerbose;
    }

    // Pass headers
    var list: ?*cURL.curl_slist = null;
    defer cURL.curl_slist_free_all(list);

    if (params.headers) |headers| {
        for (headers) |header| {
            list = cURL.curl_slist_append(list, header.ptr);
        }
        if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_HTTPHEADER, list) != cURL.CURLE_OK) {
            return error.CouldNotSetHeaders;
        }
    }

    // Payload
    if(params.payload) |payload| {
        if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_POSTFIELDSIZE, payload.len) != cURL.CURLE_OK)
            return error.CouldNotSetPostDataSize;
        if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_POSTFIELDS, payload.ptr) != cURL.CURLE_OK)
            return error.CouldNotSetPostData;
    }

    // Configure response handling
    if (params.store_body or params.store_headers) {
        if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_WRITEFUNCTION, writeToArrayListCallback) != cURL.CURLE_OK) {
            return error.CouldNotSetWriteCallback;
        }
    }

    // Execute
    var time_start = std.time.milliTimestamp();
    if (cURL.curl_easy_perform(handle) != cURL.CURLE_OK) {
        return error.FailedToPerformRequest;
    }
    var time = std.time.milliTimestamp() - time_start;

    ////////////////////////
    // Handle results
    ////////////////////////
    // Retrieve response code
    // Evaluate OK-ish/error-ish and return
    var http_code: u64 = 0;
    if (cURL.curl_easy_getinfo(handle, cURL.CURLINFO_RESPONSE_CODE, &http_code) != cURL.CURLE_OK)
        return error.CouldNotGetResponseCode;

    if (http_code == 0) return error.Woops;

    return RequestResponse{
        .response_type = if (http_code < 400) .Ok else .Error,
        .http_code = http_code,
        .headers = headers_payload,
        .body = body_payload,
        .time = time,
    };
}

test "httpclient.request" {
    var result = try request(std.testing.allocator, .GET, "https://raw.githubusercontent.com/michaelo/_prosit_itest/main/README.md", .{});
    defer result.deinit();

    switch (result.response_type) {
        .Error => {
            print("Got error\n", .{});
        },
        .Ok => {
            print("Got OK\n", .{});
        },
    }
    // print("Content-Type: {s}\n", .{try result.contentType()});
    print("headers:\n{s}\n", .{result.headers.?.items});
    print("body:\n{s}\n", .{result.body.?.items});
}

var is_inited: bool = false;

pub fn init() !void {
    if (is_inited) return error.AlreadyInit;
    if (cURL.curl_global_init(cURL.CURL_GLOBAL_ALL) != cURL.CURLE_OK)
        return error.CURLGlobalInitFailed;

    is_inited = false;
}

pub fn deinit() void {
    if (!is_inited) return;
    cURL.curl_global_cleanup();
    is_inited = false;
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
        else => "",
    };
}
