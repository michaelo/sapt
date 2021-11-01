const std = @import("std");
const testing = std.testing;
const utils = @import("utils.zig");
const initBoundedArray = utils.initBoundedArray;

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

    pub fn string(self: HttpMethod) [*]const u8 {
        return std.meta.tagName(self).ptr;
    }
    pub fn create(raw: []const u8) !HttpMethod {
        return std.meta.stringToEnum(HttpMethod, raw) orelse error.NoSuchHttpMethod;
    }
};

test "HttpMethod.create()" {
    try testing.expect((try HttpMethod.create("OPTIONS")) == HttpMethod.OPTIONS);
    try testing.expect((try HttpMethod.create("HEAD")) == HttpMethod.HEAD);
    try testing.expect((try HttpMethod.create("CONNECT")) == HttpMethod.CONNECT);
    try testing.expect((try HttpMethod.create("TRACE")) == HttpMethod.TRACE);
    try testing.expect((try HttpMethod.create("GET")) == HttpMethod.GET);
    try testing.expect((try HttpMethod.create("POST")) == HttpMethod.POST);
    try testing.expect((try HttpMethod.create("PUT")) == HttpMethod.PUT);
    try testing.expect((try HttpMethod.create("PATCH")) == HttpMethod.PATCH);
    try testing.expect((try HttpMethod.create("DELETE")) == HttpMethod.DELETE);
    try testing.expectError(error.NoSuchHttpMethod, HttpMethod.create("BLAH"));
    try testing.expectError(error.NoSuchHttpMethod, HttpMethod.create(""));
    try testing.expectError(error.NoSuchHttpMethod, HttpMethod.create(" GET"));
}

pub const HttpHeader = struct {
    pub const MAX_VALUE_LEN = 8*1024;

    name: std.BoundedArray(u8,256),
    value: std.BoundedArray(u8,MAX_VALUE_LEN),
    pub fn create(name: []const u8, value: []const u8) !HttpHeader {
        return HttpHeader {
            .name = std.BoundedArray(u8,256).fromSlice(std.mem.trim(u8, name, " ")) catch { return error.ParseError; },
            .value = std.BoundedArray(u8,MAX_VALUE_LEN).fromSlice(std.mem.trim(u8, value, " ")) catch { return error.ParseError; },
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
            .name = std.BoundedArray(u8,256).fromSlice(std.mem.trim(u8, name, " ")) catch { return error.ParseError; },
            .expression = std.BoundedArray(u8,1024).fromSlice(std.mem.trim(u8, value, " ")) catch { return error.ParseError; },
        };
    }
};