// Import all modules to be automatically tested
// TODO: This can probably be generated compile-time
test "link" {
    _ = @import("main.zig");
    _ = @import("parser.zig");
    _ = @import("kvstore.zig");
    _ = @import("io.zig");
    _ = @import("console.zig");
    _ = @import("argparse.zig");
}