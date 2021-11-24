// Import all modules to be automatically tested
test "link" {
    _ = @import("argparse.zig");
    _ = @import("config.zig");
    _ = @import("console.zig");
    _ = @import("httpclient.zig");
    _ = @import("io.zig");
    _ = @import("kvstore.zig");
    _ = @import("main.zig");
    _ = @import("parser.zig");
    _ = @import("pretty.zig");
    _ = @import("threadpool.zig");
    _ = @import("types.zig");
    _ = @import("utils.zig");
}