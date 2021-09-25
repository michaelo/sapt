const std = @import("std");
const main = @import("main.zig");
const fs = std.fs;
const testing = std.testing;

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
    var buf = main.initBoundedArray(u8, 1024*1024);
    try testing.expect(buf.slice().len == 0);
    try readFile(u8, buf.buffer.len, "testdata/01-warnme/01-warnme-stats.pi", &buf);
    try testing.expect(buf.slice().len > 0);
}

test "readFileRaw" {
    var buf = main.initBoundedArray(u8, 1024*1024);
    try testing.expect(buf.slice().len == 0);
    try buf.resize(try readFileRaw("testdata/01-warnme/01-warnme-stats.pi", buf.buffer[0..]));
    try testing.expect(buf.slice().len > 0);
}
