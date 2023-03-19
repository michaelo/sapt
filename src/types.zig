/// Common type definitions that's applicable cross-concern
const std = @import("std");
const testing = std.testing;
const utils = @import("utils.zig");
const config = @import("config.zig");
const httpclient = @import("httpclient.zig");
const initBoundedArray = utils.initBoundedArray;

/// The main definition of a test to perform
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

/// Container for the results after executing an Entry
pub const EntryResult = struct {
    num_fails: usize = 0, // Will increase for each failed attempt, relates to "repeats"
    conclusion: bool = false,
    response_content_type: std.BoundedArray(u8, HttpHeader.MAX_VALUE_LEN) = initBoundedArray(u8, HttpHeader.MAX_VALUE_LEN),
    response_http_code: u64 = 0,
    response_match: bool = false,
    response_first_1mb: std.BoundedArray(u8, 1024 * 1024) = initBoundedArray(u8, 1024 * 1024),
    response_headers_first_1mb: std.BoundedArray(u8, 1024 * 1024) = initBoundedArray(u8, 1024 * 1024),
};

pub const TestContext = struct { entry: Entry = .{}, result: EntryResult = .{} };

pub const HttpMethod = httpclient.HttpMethod;

pub const HttpHeader = struct {
    pub const MAX_VALUE_LEN = 8 * 1024;

    name: std.BoundedArray(u8, 256),
    value: std.BoundedArray(u8, MAX_VALUE_LEN),
    pub fn create(name: []const u8, value: []const u8) !HttpHeader {
        return HttpHeader{
            .name = std.BoundedArray(u8, 256).fromSlice(std.mem.trim(u8, name, " ")) catch {
                return error.ParseError;
            },
            .value = std.BoundedArray(u8, MAX_VALUE_LEN).fromSlice(std.mem.trim(u8, value, " ")) catch {
                return error.ParseError;
            },
        };
    }

    pub fn render(self: *HttpHeader, comptime capacity: usize, out: *std.BoundedArray(u8, capacity)) !void {
        try out.appendSlice(self.name.slice());
        try out.appendSlice(": ");
        try out.appendSlice(self.value.slice());
    }
};

test "HttpHeader.render" {
    var mybuf = initBoundedArray(u8, 128);
    var header = try HttpHeader.create("Accept", "application/xml");

    try header.render(128, &mybuf);
    try testing.expectEqualStrings("Accept: application/xml", mybuf.slice());
}

pub const ExtractionEntry = struct {
    name: std.BoundedArray(u8, 256),
    expression: std.BoundedArray(u8, 1024),
    pub fn create(name: []const u8, value: []const u8) !ExtractionEntry {
        return ExtractionEntry{
            .name = std.BoundedArray(u8, 256).fromSlice(std.mem.trim(u8, name, " ")) catch {
                return error.ParseError;
            },
            .expression = std.BoundedArray(u8, 1024).fromSlice(std.mem.trim(u8, value, " ")) catch {
                return error.ParseError;
            },
        };
    }
};
