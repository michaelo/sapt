const std = @import("std");
const debug = std.debug.print;
const Mutex = std.Thread.Mutex;
// Functionality to run a thread pool of n Threads with a list of tasks to be executed stored as function + workload.
// Solution will then spin up n threads, each thread checks for next available entry in the list, locks while copying out the task, then unlocks for any other thread to get started.
// If list is empty, finish thread
//
// This is currently just an excercise in getting to know zig. It should most likely be replaced by something like this:
// https://zig.news/kprotty/resource-efficient-thread-pools-with-zig-3291
//
// This is a simple variant which takes a predefined common function to activate for all work-items
pub fn ThreadPool(_num_threads: usize, comptime PayloadType: type, comptime TaskCapacity: usize, worker_function: fn (*PayloadType) void) type {
    const MAX_NUM_THREADS = 128;
    const ThreadPoolState = enum {
        NotStarted,
        Running,
        Finished
    };
    return struct {
        const Self = @This();
        const num_threads = _num_threads;

        state: ThreadPoolState = ThreadPoolState.NotStarted,
        work: [TaskCapacity]PayloadType = undefined,
        next_work_item_idx: usize = 0,
        next_free_item_idx: usize = 0,
        
        function: fn (*PayloadType) void = worker_function,

        thread_pool: [MAX_NUM_THREADS]std.Thread = undefined,

        pub fn addWork(self: *Self, work: PayloadType) !void {
            // TODO: Lock + make circular buffer
            if(self.isCapacity()) {
                self.work[self.next_free_item_idx] = work;
                // next_work_item_idx = next_free_item_idx;
                self.next_free_item_idx += 1;
            } else {
                return error.NoMoreCapacity;
            }
        }

        fn takeWork(self: *Self) !PayloadType {
            // TOdO: Lock + make circular buffer
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
            while(true) {
                // Critical section
                // Pop work
                if(!self.isWork()) break;
                var work = self.takeWork() catch { break; };
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
            while(t_id < num_threads) : (t_id += 1) {
                self.thread_pool[t_id] = try std.Thread.spawn(.{}, Self.worker, .{self});
            }
        }

        pub fn join(self: *Self) void {
            // Wait for all to finish
            var t_id:usize = 0;
            while(t_id < num_threads) : (t_id += 1) {
                self.thread_pool[t_id].join();
            }

        }

        pub fn init() Self {
            return Self{

            };
        }
    };
}

//   
const MyPayload = struct {
    data: u64,
    result: u64 = undefined,

    pub fn worker(self: *MyPayload) void {
        // _ = self;
        self.result = self.data * 2;
        debug("result: {d}\n", .{self.result});
    }
};


test "threadpool basic implementation" {
    var pool = ThreadPool(4, MyPayload, 100, MyPayload.worker).init();
    var tmp: usize = 0;
    while(tmp < 100) : (tmp += 1) {
        try pool.addWork(.{
            .data = tmp,
        });
    }
    try pool.start();
    pool.join();
}