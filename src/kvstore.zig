const std = @import("std");
const testing = std.testing;

const io = @import("io.zig");

// Convenience-function to initiate a bounded-array without inital size of 0, removing the error-case brough by .init(size)
fn initBoundedArray(comptime T: type, comptime capacity: usize) std.BoundedArray(T, capacity) {
    return std.BoundedArray(T, capacity){ .buffer = undefined };
}

// TODO: Can make generic, especially with regards to capacity
// pub fn KvStore(comptime KeyType: type, comptime )
// Att! Highly inefficient
// Possible parameters: max key size, max value size, max num variables
// Current characteristics: ordered, write-once-pr-key store - you can't update existing entries. TODO: rename accordingly
// Name suggestion: OrderedWoKvStore?
pub const KvStore = struct {
    pub const KvStoreEntry = struct {
        key: std.BoundedArray(u8, 128) = initBoundedArray(u8, 128),
        value: std.BoundedArray(u8, 8 * 1024) = initBoundedArray(u8, 8 * 1024),
        pub fn create(key: []const u8, value: []const u8) !KvStoreEntry {
            return KvStoreEntry{
                .key = try std.BoundedArray(u8, 128).fromSlice(key),
                .value = try std.BoundedArray(u8, 8 * 1024).fromSlice(value),
            };
        }
    };

    store: std.BoundedArray(KvStoreEntry, 32) = initBoundedArray(KvStoreEntry, 32),

    pub fn add(self: *KvStore, key: []const u8, value: []const u8) !void {
        // TODO: insert sorted, so we can binary search in get()
        if (try self.getIndexFor(key)) |i| {
            try self.store.insert(i, try KvStoreEntry.create(key, value));
        } else {
            // Got null -- append
            return self.store.append(try KvStoreEntry.create(key, value));
        }
    }

    // Find point to insert new key to keep list sorted, or null if it must be appended to end
    pub fn getIndexFor(self: *KvStore, key: []const u8) !?usize {
        // Will find point to insert new key to keep list sorted
        if (self.count() == 0) return null;

        // TODO: can binary search, current solution will be expensive for later entries in large list
        for (self.store.slice()) |entry, i| {
            switch (std.mem.order(u8, entry.key.constSlice(), key)) {
                .gt => {
                    return i;
                },
                .lt => {}, // keep going
                .eq => {
                    return error.KeyAlreadyUsed;
                },
            }
        }

        return null; // This means end, and thus an append must be done
    }

    pub fn get(self: *KvStore, key: []const u8) ?[]const u8 {
        // TODO: once we've inserted sorted we can binary search
        for (self.store.slice()) |entry| {
            if (std.mem.eql(u8, entry.key.constSlice(), key)) {
                return entry.value.constSlice();
            }
        }

        return null;
    }

    pub fn count(self: *KvStore) usize {
        return self.store.slice().len;
    }

    pub fn slice(self: KvStore) []KvStoreEntry {
        return self.store.constSlice();
    }

    pub fn fromBuffer(buf: []const u8) !KvStore {
        var store = KvStore{};
        var line_it = std.mem.split(u8, buf, io.getLineEnding(buf));
        while (line_it.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.indexOf(u8, line, "=")) |eqpos| {
                try store.add(line[0..eqpos], line[eqpos + 1 ..]);
            } else {
                return error.InvalidEntry;
            }
        }
        return store;
    }

    pub fn addFromBuffer(self: *KvStore, buf: []const u8) !void {
        var line_it = std.mem.split(u8, buf, io.getLineEnding(buf));
        while (line_it.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.indexOf(u8, line, "=")) |eqpos| {
                try self.add(line[0..eqpos], line[eqpos + 1 ..]);
            } else {
                return error.InvalidEntry;
            }
        }
    }

    pub const CollisionStrategy = enum {
        KeepFirst,
        Fail
    };

    pub fn addFromOther(self: *KvStore, other: KvStore, collision_handling : CollisionStrategy) !void {
        for(other.store.slice()) |entry| {
            self.add(entry.key, entry.value) catch |e| switch(e) {
                error.KeyAlreadyUsed => switch(collision_handling) {
                    .KeepFirst => {},
                    .Fail => return e,
                },
                else => return e,
            };
        }
    }
};

test "KvStore" {
    var store = KvStore{};
    try testing.expect(store.count() == 0);
    try store.add("key", "value");
    try testing.expect(store.count() == 1);
    try testing.expectEqualStrings("value", store.get("key").?);
}

test "KvStore shall stay ordered" {
    var store = KvStore{};
    try testing.expect((try store.getIndexFor("bkey")) == null);
    try store.add("bkey", "value");
    try testing.expect((try store.getIndexFor("akey")).? == 0);
    try testing.expect((try store.getIndexFor("ckey")) == null);
    try testing.expectError(error.KeyAlreadyUsed, store.getIndexFor("bkey"));

    // insert early entry. Add shall fail, and checking for the key shall also fail
    try testing.expect((try store.getIndexFor("akey")).? == 0);
    try store.add("akey", "value");
    try testing.expectError(error.KeyAlreadyUsed, store.add("akey", "value"));
    try testing.expect((try store.getIndexFor("ckey")) == null);
}

test "KvFromBuffer" {
    {
        var store = try KvStore.fromBuffer(
            \\
        );
        try testing.expect(store.count() == 0);
    }

    {
        var store = try KvStore.fromBuffer(
            \\key=value
        );
        try testing.expect(store.count() == 1);
        try testing.expectEqualStrings("value", store.get("key").?);
    }

    {
        var store = try KvStore.fromBuffer(
            \\key=value
            \\abba=babba
        );
        try testing.expect(store.count() == 2);
        try testing.expectEqualStrings("babba", store.get("abba").?);
    }

    {
        try testing.expectError(error.InvalidEntry, KvStore.fromBuffer(
            \\keyvalue
        ));
    }
}