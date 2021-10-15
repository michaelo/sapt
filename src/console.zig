/// Basic writer supporting console-escape-codes for supported platforms
const std = @import("std");

pub const Console = struct {

    pub fn reset() void {
        const stdout = std.io.getStdOut().writer();
        var ttyconf = std.debug.detectTTYConfig();

        ttyconf.setColor(stdout, .Reset);
    }

    pub fn plain(comptime fmt:[]const u8, args: anytype) void {
        const stdout = std.io.getStdOut().writer();
        var ttyconf = std.debug.detectTTYConfig();

        ttyconf.setColor(stdout, .Reset);
        stdout.print(fmt, args) catch {};
        ttyconf.setColor(stdout, .Reset);
    }

    pub fn grey(comptime fmt:[]const u8, args: anytype) void {
        const stdout = std.io.getStdOut().writer();
        var ttyconf = std.debug.detectTTYConfig();

        ttyconf.setColor(stdout, .Dim);
        stdout.print(fmt, args) catch {};
        ttyconf.setColor(stdout, .Reset);
    }

    pub fn red(comptime fmt:[]const u8, args: anytype) void {
        const stdout = std.io.getStdOut().writer();
        var ttyconf = std.debug.detectTTYConfig();

        ttyconf.setColor(stdout, .Red);
        stdout.print(fmt, args) catch {};
        ttyconf.setColor(stdout, .Reset);
    }

    pub fn green(comptime fmt:[]const u8, args: anytype) void {
        const stdout = std.io.getStdOut().writer();
        var ttyconf = std.debug.detectTTYConfig();

        ttyconf.setColor(stdout, .Green);
        stdout.print(fmt, args) catch {};
        ttyconf.setColor(stdout, .Reset);
    }

    pub fn bold(comptime fmt:[]const u8, args: anytype) void {
        const stdout = std.io.getStdOut().writer();
        var ttyconf = std.debug.detectTTYConfig();

        ttyconf.setColor(stdout, .Bold);
        stdout.print(fmt, args) catch {};
        ttyconf.setColor(stdout, .Reset);
    }

    // TODO: Add wrapper for error() and debug()?

    pub fn nl() void {
        const stdout = std.io.getStdOut().writer();
        // var ttyconf = std.debug.detectTTYConfig();

        stdout.writeAll("\n");
    }
};

test "Console" {
    const c = Console;
    c.plain("Console.plain()\n", .{});
    c.grey("Console.grey()\n", .{});
    c.red("Console.red()\n", .{});
    c.green("Console.green()\n", .{});
    c.bold("Console.bold()\n", .{});
}
