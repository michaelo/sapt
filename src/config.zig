const std = @import("std");
const builtin = @import("builtin");

pub const APP_NAME = "sapt";
pub const APP_VERSION = getVersion();
pub const APP_CREDITS = "Michael Odden <me@michaelodden.com>";
pub const FILE_EXT_ENV = ".env";
pub const FILE_EXT_TEST = ".pi";
pub const FILE_EXT_PLAYBOOK = ".book";
pub const MAX_PATH_LEN = 1024;

pub const MAX_PAYLOAD_SIZE = 1024 * 1024;
pub const MAX_URL_LEN = 2048;
pub const MAX_ENV_FILE_SIZE = 1024 * 1024;
pub const MAX_TEST_FILE_SIZE = 1024 * 1024;
pub const MAX_PLAYBOOK_FILE_SIZE = 1024 * 1024;

fn getVersion() []const u8 {
    if (builtin.mode != .Debug) {
        return @embedFile("../VERSION");
    } else {
        return @embedFile("../VERSION") ++ "-UNRELEASED";
    }
}
