const std = @import("std");
const fs = std.fs;
const testing = std.testing;

/// Reads contents from path, relative to cwd, and store in target_buf
pub fn readFileRaw(path: []const u8, target_buf: []u8) !usize {
    return try readFileRawRel(fs.cwd(), path, target_buf);
}

/// Reads contents from path, relative to dir, and store in target_buf
pub fn readFileRawRel(dir: std.fs.Dir, path: []const u8, target_buf: []u8) !usize {
    var file = try dir.openFile(path, .{ .read = true });
    defer file.close();

    return try file.readAll(target_buf[0..]);
}

test "readFileRaw" {
    var buf = try std.BoundedArray(u8, 1024 * 1024).init(0);
    try testing.expect(buf.slice().len == 0);
    try buf.resize(try readFileRaw("testdata/01-warnme/01-warnme-status-ok.pi", buf.buffer[0..]));
    try testing.expect(buf.slice().len > 0);
}

/// Reads contents from path, relative to cwd, and store in target_buf
pub fn readFile(comptime T: type, comptime S: usize, path: []const u8, target_buf: *std.BoundedArray(T, S)) !void {
    return try readFileRel(T, S, fs.cwd(), path, target_buf);
}

/// Reads contents from path, relative to dir, and store in target_buf
pub fn readFileRel(comptime T: type, comptime S: usize, dir: std.fs.Dir, path: []const u8, target_buf: *std.BoundedArray(T, S)) !void {
    var file = try dir.openFile(path, .{ .read = true });
    defer file.close();

    const size = try file.getEndPos();
    try target_buf.resize(std.math.min(size, target_buf.capacity()));
    _ = try file.readAll(target_buf.slice()[0..]);
}

test "readFile" {
    var buf = try std.BoundedArray(u8, 1024 * 1024).init(0);
    try testing.expect(buf.slice().len == 0);
    try readFile(u8, buf.buffer.len, "testdata/01-warnme/01-warnme-status-ok.pi", &buf);
    try testing.expect(buf.slice().len > 0);
}

/// Autosense buffer for type of line ending: Check buf for \r\n, and if found: return \r\n, otherwise \n
pub fn getLineEnding(buf: []const u8) []const u8 {
    if (std.mem.indexOf(u8, buf, "\r\n") != null) return "\r\n";
    return "\n";
}

/// Returns the slice which is without the last path-segment
pub fn getParent(fileOrDir: []const u8) []const u8 {
    std.debug.assert(fileOrDir.len > 0);
    var i: usize = fileOrDir.len-2;
    while(i > 0) : (i -= 1) {
        if(fileOrDir[i] == '/' or fileOrDir[i] == '\\') {
            break;
        }
    }
    return fileOrDir[0..i];
}

test "getParent" {
    try testing.expectEqualStrings("", getParent("myfile"));
    try testing.expectEqualStrings("folder", getParent("folder/file"));
}