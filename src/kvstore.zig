const std = @import("std");
const debug = std.debug.print;
const testing = std.testing;

// Convenience-function to initiate a bounded-array without inital size of 0, removing the error-case brough by .init(size)
fn initBoundedArray(comptime T: type, comptime capacity: usize) std.BoundedArray(T,capacity) {
    return std.BoundedArray(T, capacity){.buffer=undefined};
}

pub const KvStoreEntry = struct {
    key: std.BoundedArray(u8, 128) = initBoundedArray(u8, 128),
    value: std.BoundedArray(u8, 8*1024) = initBoundedArray(u8, 8*1024),
    pub fn create(key: []const u8, value: []const u8) !KvStoreEntry {
        return KvStoreEntry{
            .key = try std.BoundedArray(u8, 128).fromSlice(key),
            .value = try std.BoundedArray(u8, 8*1024).fromSlice(value),
        };
    }
};

// TODO: Can make generic, especially with regards to capacity
// pub fn KvStore(comptime KeyType: type, comptime )
// Highly inefficient
pub const KvStore = struct {
    store: std.BoundedArray(KvStoreEntry, 32) = initBoundedArray(KvStoreEntry, 32),
    pub fn add(self: *KvStore, key: []const u8, value: []const u8) !void {
        // TODO: insert sorted, so we can binary search in get()
        if(self.get(key) == null) {
            try self.store.append(try KvStoreEntry.create(key, value));
        } else {
            // error - key already exists. TODO: Override?
            return error.KeyAlreadyUsed;
        }
    }

    pub fn get(self: *KvStore, key: []const u8) ?[]const u8 {
        // TODO: once we've inserted sorted we can binary search
        for(self.store.slice()) |entry| {
            if(std.mem.eql(u8, entry.key.constSlice(), key)) {
                return entry.value.constSlice();
            }
        }

        return null;
    }

    pub fn count(self: *KvStore) usize {
        return self.store.slice().len;
    }
};


test "KvStore" {
    var store = KvStore{};
    try testing.expect(store.count() == 0);
    try store.add("key", "value");
    try testing.expect(store.count() == 1);
    try testing.expectEqualStrings("value", store.get("key").?);
}