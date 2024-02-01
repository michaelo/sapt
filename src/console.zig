const std = @import("std");
pub const Color = std.io.tty.Color;

/// Basic output-wrapper with console-escape-codes for supported platforms.
/// Convenience-oriented with regards to enabling different levels of output
/// API: <stream>Print(), <stream>Colored(), with <stream> being std, debug, error or verbose.
pub const Console = struct {
    const Self = @This();

    pub const ColorConfig = enum { on, off, auto };

    // Writers
    debug_writer: ?std.fs.File.Writer = null,
    std_writer: ?std.fs.File.Writer = null,
    error_writer: ?std.fs.File.Writer = null,
    verbose_writer: ?std.fs.File.Writer = null,

    ttyconf: std.io.tty.Config,

    /// Returns a Console which suppresses all output
    pub fn initNull() Self {
        return Self{
            .ttyconf = Console.colorConfig(.off),
        };
    }

    /// Main constructor. Takes optional writers. null == suppress.
    pub fn init(args: struct { std_writer: ?std.fs.File.Writer, error_writer: ?std.fs.File.Writer, verbose_writer: ?std.fs.File.Writer, debug_writer: ?std.fs.File.Writer, colors: ColorConfig }) Self {
        return Self{
            .debug_writer = args.debug_writer,
            .std_writer = args.std_writer,
            .error_writer = args.error_writer,
            .verbose_writer = args.verbose_writer,
            .ttyconf = Console.colorConfig(args.colors),
        };
    }

    /// Basic constructor providing same writer for all output-types
    pub fn initSimple(writer: ?std.fs.File.Writer) Self {
        return Self{
            .debug_writer = writer,
            .std_writer = writer,
            .error_writer = writer,
            .verbose_writer = writer,
            .ttyconf = std.io.tty.detectConfig(std.io.getStdErr()),
        };
    }

    fn colorConfig(value: ColorConfig) std.io.tty.Config {
        return switch (value) {
            .on => .escape_codes,
            .off => .no_color,
            .auto => std.io.tty.detectConfig(std.io.getStdErr()),
        };
    }

    /// Core output-function, utilized by all others.
    fn out(self: *const Self, maybe_writer: ?std.fs.File.Writer, maybe_color: ?Color, comptime fmt: []const u8, args: anytype) void {
        if (maybe_writer == null) return;
        const writer = maybe_writer.?;
        if (maybe_color) |color| {
            self.ttyconf.setColor(writer, color) catch {};
        }
        writer.print(fmt, args) catch {};
        if (maybe_color != null) {
            self.ttyconf.setColor(writer, .reset) catch {};
        }
    }

    //////////////////////////////////////////////////////
    // Print-functions
    //////////////////////////////////////////////////////

    pub fn stdPrint(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        self.out(self.std_writer, null, fmt, args);
    }

    pub fn stdColored(self: *const Self, color: Color, comptime fmt: []const u8, args: anytype) void {
        self.out(self.std_writer, color, fmt, args);
    }

    pub fn errorPrint(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        self.errorColored(.red, "ERROR: ", .{});
        self.out(self.error_writer, null, fmt, args);
    }

    pub fn errorPrintNoPrefix(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        self.out(self.error_writer, null, fmt, args);
    }

    pub fn errorColored(self: *const Self, color: Color, comptime fmt: []const u8, args: anytype) void {
        self.out(self.error_writer, color, fmt, args);
    }

    // TBD: What's the use case for "debug"?
    pub fn debugPrint(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        self.out(self.debug_writer, null, fmt, args);
    }

    pub fn debugColored(self: *const Self, color: Color, comptime fmt: []const u8, args: anytype) void {
        self.out(self.debug_writer, color, fmt, args);
    }

    pub fn verbosePrint(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        self.out(self.verbose_writer, null, fmt, args);
    }

    pub fn verboseColored(self: *const Self, color: Color, comptime fmt: []const u8, args: anytype) void {
        self.out(self.verbose_writer, color, fmt, args);
    }
};

test "Console" {
    const stdout = std.io.getStdOut().writer();
    const c = Console.initSimple(stdout);
    c.stdPrint("\n", .{});

    c.errorPrint("Something very wrong\n", .{});
    c.stdPrint("Regular output\n", .{});
    c.debugPrint("Debug output\n", .{});
    c.verbosePrint("Verbose output\n", .{});
}
