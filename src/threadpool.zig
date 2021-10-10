const std = @import("std");
const debug = std.debug.print;
const Mutex = std.Thread.Mutex;
const testing = std.testing;
// Functionality to run a thread pool of n Threads with a list of tasks to be executed stored as function + workload.
// Solution will then spin up n threads, each thread checks for next available entry in the list, locks while copying out the task, then unlocks for any other thread to get started.
// If list is empty, finish thread
//
// This is currently just an excercise in getting to know zig. It should most likely be replaced by something like this:
// https://zig.news/kprotty/resource-efficient-thread-pools-with-zig-3291
//
// This is a simple variant which takes a predefined common function to activate for all work-items
// Requirement: Set up from single thread, no modifications after start()
pub fn ThreadPool(comptime PayloadType: type, comptime TaskCapacity: usize, worker_function: fn (*PayloadType) void) type {
    const MAX_NUM_THREADS = 128;
    const ThreadPoolState = enum {
        NotStarted,
        Running,
        Finished
    };
    return struct {
        const Self = @This();
        num_threads: usize,
        work_mutex: Mutex = Mutex{},

        state: ThreadPoolState = ThreadPoolState.NotStarted,
        // TBD: This can be an heap-allocated list to scale to "arbitrary" amounts 
        work: [TaskCapacity]PayloadType = undefined,
        next_work_item_idx: usize = 0,
        next_free_item_idx: usize = 0,
        
        function: fn (*PayloadType) void = worker_function,

        thread_pool: [MAX_NUM_THREADS]std.Thread = undefined,

        /// Required to be populated from single thread as of now, and must be done before start.
        pub fn addWork(self: *Self, work: PayloadType) !void {
            // TODO: Lock + make circular buffer?
            // const held = self.work_mutex.acquire();
            // defer held.release();

            if(self.isCapacity()) {
                self.work[self.next_free_item_idx] = work;
                // next_work_item_idx = next_free_item_idx;
                self.next_free_item_idx += 1;
            } else {
                return error.NoMoreCapacity;
            }
        }

        /// Not thread safe, must lock outside
        fn takeWork(self: *Self) !PayloadType {
            // TODO: Lock + make circular buffer?
            // const held = self.work_mutex.acquire();
            // defer held.release();

            if(self.isWork()) {
                var item_to_return = self.next_work_item_idx;
                self.next_work_item_idx += 1;
                return self.work[item_to_return];
            } else {
                return error.NoMoreWork;
            }
        }

        fn isWork(self: *Self) bool {
            return self.next_work_item_idx < self.next_free_item_idx;
        }

        fn isCapacity(self: *Self) bool {
            return self.next_free_item_idx < TaskCapacity;
        }

        /// Thread-worker
        fn worker(self: *Self) void {
            // While work to be done
            var work: PayloadType = undefined;
            while(true) {
                // Critical section
                // Pop work
                {
                    const held = self.work_mutex.acquire();
                    defer held.release();

                    if(!self.isWork()) break;
                    work = self.takeWork() catch { break; };
                }
                // End critical section

               // Call worker_function with workload
               // TODO: Pass a struct to store results in as well? Otherwise we'll have to keep all input-data to be able to evaluate results
               self.function(&work);
            }
        }

        pub fn start(self: *Self) !void {
            // Fill up thread pool, with .worker() 
            var t_id:usize = 0;
            // debug("{s} vs {s}\n", .{@TypeOf(self.worker), @TypeOf(ThreadPool(4, MyPayload, 100, MyPayload.worker){})});
            while(t_id < self.num_threads) : (t_id += 1) {
                self.thread_pool[t_id] = try std.Thread.spawn(.{}, Self.worker, .{self});
            }
        }

        pub fn join(self: *Self) void {
            // Wait for all to finish
            var t_id:usize = 0;
            while(t_id < self.num_threads) : (t_id += 1) {
                self.thread_pool[t_id].join();
            }
        }

        pub fn startAndJoin(self: *Self) !void {
            try self.start();
            self.join();
        }

        pub fn init(wanted_num_threads: usize) Self {
            return Self{
                .num_threads = wanted_num_threads,
            };
        }
    };
}


test "threadpool basic implementation" {
    const MyPayloadResult = struct {
        total: u64 = 0,
    };
    //   
    const MyPayload = struct {
        const Self = @This();
        data: u64,
        result: *MyPayloadResult,

        pub fn worker(self: *Self) void {
            // _ = self;
            var total = self.result.total;
            total += self.data;
            total += self.data;
            self.result.total = total;
        }
    };

    var result = MyPayloadResult{};

    var pool = ThreadPool(MyPayload, 1000, MyPayload.worker).init(24);
    var tmp: usize = 0;
    var checkresult: u64 = 0;
    while(tmp < 1000) : (tmp += 1) {
        checkresult += tmp*2;
        try pool.addWork(.{
            .data = tmp,
            .result = &result,
        });
    }
    try pool.start();
    pool.join();
    try testing.expect(checkresult == result.total);
    debug("Result: {d}\n", .{result.total});
}
