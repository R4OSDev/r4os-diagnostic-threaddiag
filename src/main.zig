const r4os = @import("r4os");

var global_sys: ?r4os.r4sys.Context = null;
var shared_counter: u64 = 0;
var exit_worker_arg: usize = 0;
var timeout_release: bool = false;

const dynamic_arg = "/DYNAMICTASKS";
const dynamic_concurrency: usize = 160;
const dynamic_churn_cycles: u32 = 10_000;
const inventory_restart_limit: u32 = 16;
const inventory_would_block_retry_limit: u32 = 64;
const baseline_stable_samples: u32 = 8;
const baseline_stable_sample_limit: u32 = 4096;
const global_memory_block_growth_limit: u64 = 16;
const global_memory_byte_growth_limit: u64 = 4 * 1024 * 1024;
var dynamic_release: bool = false;
var dynamic_started: [dynamic_concurrency]bool = .{false} ** dynamic_concurrency;
var dynamic_progress: [dynamic_concurrency]u32 = .{0} ** dynamic_concurrency;

const DynamicBaseline = struct {
    task_count: u32,
    main_task_id: u32,
    fpu_state_bytes: u32,
    fpu_task_state_count: u32,
    fpu_task_init_count: u64,
    fpu_task_state_bytes: u64,
    memory_active_blocks: u64,
    memory_error_blocks: u64,
    memory_physical_bytes: u64,
    memory_reserved_bytes: u64,
    memory_committed_bytes: u64,
    memory_free_physical_bytes: u64,
    memory_app_stack_blocks: u64,
    memory_r4x_owner_blocks: u64,
    memory_overflow: u32,
    instance_reserved_bytes: u64,
    instance_committed_bytes: u64,
    instance_resident_bytes: u64,
    instance_stack_reserved_bytes: u64,
    instance_stack_committed_bytes: u64,
};

pub fn r4_app_main(app: *r4os.App) i32 {
    var sys = app.system();
    const resources = app.resources();
    global_sys = sys;

    sys.println("THREADD");
    if (!resources.available()) return fail(&sys, "THREADD resource facade missing");
    if (argsEqual(app.args(), dynamic_arg)) {
        const devices = app.devices() orelse return fail(&sys, "THREADD dynamic R4DEV facade missing");
        return dynamicTaskProfile(&sys, &devices);
    }

    const main_id = sys.threadCurrent();
    if (main_id == 0) return fail(&sys, "THREADD main id missing");
    var main_info: r4os.abi.ProgramThreadInfo = .{};
    if (sys.threadStatus(main_id, &main_info) != r4os.abi.thread_ok) return fail(&sys, "THREADD main status failed");
    if ((main_info.flags & r4os.abi.thread_flag_main) == 0) return fail(&sys, "THREADD main flag missing");
    sys.println("THREADD phase=main");

    var self_exit: i32 = 0;
    if (sys.threadJoin(main_id, 0, &self_exit) != r4os.abi.thread_error_self_join) return fail(&sys, "THREADD self join accepted");
    var invalid_id: u32 = 0;
    if (sys.threadCreateRaw(workerMain, 1, 0, 1, &invalid_id) != r4os.abi.thread_error_unsupported) return fail(&sys, "THREADD invalid flags accepted");

    var worker = switch (resources.createThread(workerMain, 7, 0)) {
        .handle => |handle| handle,
        .failure => return fail(&sys, "THREADD worker create failed"),
    };
    const worker_id = worker.handle.thread_id;
    const worker_info = switch (worker.status()) {
        .value => |info| info,
        .failure => return fail(&sys, "THREADD worker status failed"),
    };
    if ((worker_info.flags & r4os.abi.thread_flag_joinable) == 0 or worker_info.stack_reserved_bytes == 0) return fail(&sys, "THREADD worker contract failed");
    switch (worker.join(r4os.time_contract.timeoutForever())) {
        .exited => |code| if (code != 47) return fail(&sys, "THREADD worker exit mismatch"),
        else => return fail(&sys, "THREADD worker join failed"),
    }
    if (worker.valid() or @as(*volatile u64, &shared_counter).* != 21) return fail(&sys, "THREADD worker lifecycle mismatch");
    switch (worker.join(r4os.time_contract.timeoutPoll())) {
        .failure => |raw| if (raw != r4os.abi.err_closed) return fail(&sys, "THREADD double join status mismatch"),
        else => return fail(&sys, "THREADD double join accepted"),
    }
    sys.println("THREADD phase=worker");

    var exit_worker = switch (resources.createThread(workerExitMain, 33, 128 * 1024)) {
        .handle => |handle| handle,
        .failure => return fail(&sys, "THREADD exit worker create failed"),
    };
    const exit_id = exit_worker.handle.thread_id;
    switch (exit_worker.join(r4os.time_contract.timeoutForever())) {
        .exited => |code| if (code != 93) return fail(&sys, "THREADD explicit exit mismatch"),
        else => return fail(&sys, "THREADD exit worker join failed"),
    }
    if (@as(*volatile usize, &exit_worker_arg).* != 33) return fail(&sys, "THREADD explicit exit arg mismatch");
    sys.println("THREADD phase=exit");

    @as(*volatile bool, &timeout_release).* = false;
    var timeout_worker = switch (resources.createThread(timeoutWorkerMain, 0, 0)) {
        .handle => |handle| handle,
        .failure => return fail(&sys, "THREADD timeout worker create failed"),
    };
    switch (timeout_worker.join(r4os.time_contract.timeoutPoll())) {
        .timed_out => {},
        else => return fail(&sys, "THREADD poll timeout missing"),
    }
    if (!timeout_worker.valid()) return fail(&sys, "THREADD timeout consumed handle");
    sys.println("THREADD phase=timeout-poll");
    @as(*volatile bool, &timeout_release).* = true;
    switch (timeout_worker.join(r4os.time_contract.timeoutForever())) {
        .exited => |code| if (code != 61) return fail(&sys, "THREADD timeout worker exit mismatch"),
        else => return fail(&sys, "THREADD timeout worker join failed"),
    }
    sys.println("THREADD phase=timeout-join");

    var stress: u32 = 0;
    while (stress < 80) : (stress += 1) {
        var handle = switch (resources.createThread(stressWorkerMain, stress, 0)) {
            .handle => |value| value,
            .failure => return fail(&sys, "THREADD stress create leaked slots"),
        };
        switch (handle.join(r4os.time_contract.timeoutForever())) {
            .exited => |code| if (code != @as(i32, @intCast(stress))) return fail(&sys, "THREADD stress exit mismatch"),
            else => return fail(&sys, "THREADD stress join failed"),
        }
        if ((stress + 1) % 20 == 0) {
            sys.write("THREADD phase=stress count=");
            sys.printU64(stress + 1);
            sys.println("");
        }
    }

    sys.write("THREADD main=");
    sys.printU64(main_id);
    sys.write(" worker=");
    sys.printU64(worker_id);
    sys.write(" exit=");
    sys.printU64(exit_id);
    sys.println("");
    sys.println("THREADD result: OK");
    return 0;
}

fn dynamicTaskProfile(sys: *r4os.r4sys.Context, devices: *const r4os.Devices) i32 {
    sys.println("THREADD dynamic begin");
    @as(*volatile bool, &dynamic_release).* = false;
    @memset(dynamic_started[0..], false);
    @memset(dynamic_progress[0..], 0);

    var handles: [dynamic_concurrency]r4os.abi.ProgramJoinHandle = .{r4os.abi.ProgramJoinHandle{}} ** dynamic_concurrency;
    var ids: [dynamic_concurrency]u32 = .{0} ** dynamic_concurrency;
    var task_ids: [dynamic_concurrency]u32 = .{0} ** dynamic_concurrency;
    var index: usize = 0;
    while (index < ids.len) : (index += 1) {
        const status = sys.threadCreateHandle(dynamicWorkerMain, index, 0, 0, &handles[index]);
        if (status != r4os.abi.thread_ok or !validJoinHandle(handles[index])) return fail(sys, "THREADD dynamic concurrent create failed");
        ids[index] = handles[index].thread_id;
        if (idSeen(ids[0..index], ids[index])) return fail(sys, "THREADD dynamic duplicate concurrent thread id");
        if ((index + 1) % 32 == 0) {
            sys.write("THREADD dynamic create progress=");
            sys.printU64(index + 1);
            sys.println("");
        }
    }

    var wait_rounds: u32 = 0;
    while (startedCount() != dynamic_concurrency and wait_rounds < 20_000) : (wait_rounds += 1) {
        sys.taskYield();
        if (wait_rounds != 0 and wait_rounds % 1000 == 0) {
            sys.write("THREADD dynamic start progress rounds=");
            sys.printU64(wait_rounds);
            sys.write(" started=");
            sys.printU64(startedCount());
            sys.println("");
        }
    }
    if (startedCount() != dynamic_concurrency) return fail(sys, "THREADD dynamic concurrent start timeout");
    sys.println("THREADD dynamic phase=started");

    var runnable: u32 = 0;
    var blocked: u32 = 0;
    index = 0;
    while (index < ids.len) : (index += 1) {
        var info: r4os.abi.ProgramThreadInfo = .{};
        if (sys.threadHandleStatus(&handles[index], &info) != r4os.abi.thread_ok) return fail(sys, "THREADD dynamic live status failed");
        if (info.task_id == 0 or idSeen(task_ids[0..index], info.task_id)) return fail(sys, "THREADD dynamic duplicate concurrent task id");
        task_ids[index] = info.task_id;
        if (info.state == r4os.abi.thread_state_ready or info.state == r4os.abi.thread_state_running) runnable += 1 else blocked += 1;
    }

    @as(*volatile bool, &dynamic_release).* = true;
    var concurrent_post_join: u32 = 0;
    index = 0;
    while (index < ids.len) : (index += 1) {
        var exit_code: i32 = -1;
        if (sys.threadHandleJoin(&handles[index], r4os.abi.thread_wait_forever, &exit_code) != r4os.abi.thread_ok or
            exit_code != @as(i32, @intCast(index & 0x7FFF))) return fail(sys, "THREADD dynamic concurrent join failed");
        if (!joinedThreadIsGone(sys, ids[index])) return fail(sys, "THREADD dynamic concurrent joined id still addressable");
        concurrent_post_join += 1;
        if (@as(*volatile u32, &dynamic_progress[index]).* == 0) return fail(sys, "THREADD dynamic worker made no progress");
        if (index != 0 and index % 20 == 0) {
            sys.write("THREADD dynamic join progress=");
            sys.printU64(index);
            sys.println("");
        }
    }
    sys.println("THREADD dynamic phase=joined");

    // The 160-thread phase is also the allocator/registry warm phase. Capture
    // the baseline only after every ProgramThread was joined and its public ID
    // stopped resolving. Repeated identical ownership samples avoid measuring
    // a transient service task, while the later global-byte comparison remains
    // bounded rather than demanding flakey whole-system equality.
    const main_thread_id = sys.threadCurrent();
    if (main_thread_id == 0) return fail(sys, "THREADD dynamic main thread id missing");
    var main_info: r4os.abi.ProgramThreadInfo = .{};
    if (sys.threadStatus(main_thread_id, &main_info) != r4os.abi.thread_ok or main_info.instance_id == 0 or main_info.task_id == 0)
        return fail(sys, "THREADD dynamic main thread baseline missing");
    const baseline_before = captureStableBaseline(sys, devices, main_info.instance_id) orelse
        return fail(sys, "THREADD dynamic warm baseline unstable");
    sys.write("THREADD dynamic warm joined=");
    sys.printU64(dynamic_concurrency);
    sys.write(" postJoinGone=");
    sys.printU64(concurrent_post_join);
    sys.println(" baseline=captured");

    var churn: u32 = 0;
    var churn_post_join: u32 = 0;
    while (churn < dynamic_churn_cycles) : (churn += 1) {
        if (churn != 0 and churn % 1000 == 0) {
            sys.write("THREADD dynamic churn progress=");
            sys.printU64(churn);
            sys.println("");
        }
        var handle: r4os.abi.ProgramJoinHandle = .{};
        if (sys.threadCreateHandle(stressWorkerMain, churn & 0x7FFF, 0, 0, &handle) != r4os.abi.thread_ok or !validJoinHandle(handle))
            return fail(sys, "THREADD dynamic churn create failed");
        const id = handle.thread_id;
        var live_info: r4os.abi.ProgramThreadInfo = .{};
        if (sys.threadHandleStatus(&handle, &live_info) != r4os.abi.thread_ok or
            live_info.task_id == 0 or
            live_info.task_id == baseline_before.main_task_id or
            live_info.stack_reserved_bytes == 0 or
            live_info.stack_committed_bytes == 0) return fail(sys, "THREADD dynamic churn live identity invalid");
        var exit_code: i32 = -1;
        if (sys.threadHandleJoin(&handle, r4os.abi.thread_wait_forever, &exit_code) != r4os.abi.thread_ok or
            exit_code != @as(i32, @intCast(churn & 0x7FFF))) return fail(sys, "THREADD dynamic churn join failed");
        if (!joinedThreadIsGone(sys, id)) return fail(sys, "THREADD dynamic churn joined id still addressable");
        churn_post_join += 1;
    }

    const baseline_after = captureStableBaseline(sys, devices, main_info.instance_id) orelse
        return fail(sys, "THREADD dynamic final baseline unstable");
    if (!dynamicBaselineMatches(baseline_before, baseline_after)) {
        printDynamicBaseline(sys, baseline_before, baseline_after);
        return fail(sys, "THREADD dynamic baseline drift");
    }

    sys.write("THREADD dynamic concurrency live=");
    sys.printU64(dynamic_concurrency);
    sys.write(" runnable=");
    sys.printU64(runnable);
    sys.write(" blocked=");
    sys.printU64(blocked);
    sys.println(" stable=OK");
    printDynamicBaseline(sys, baseline_before, baseline_after);
    sys.write("THREADD dynamic churn=");
    sys.printU64(dynamic_churn_cycles);
    sys.write(" createReap=OK postJoinGone=");
    sys.printU64(churn_post_join);
    sys.println(" baseline=OK");
    sys.println("THREADD dynamic result: OK");
    sys.println("THREADD result: OK");
    return 0;
}

fn captureStableBaseline(sys: *r4os.r4sys.Context, devices: *const r4os.Devices, instance_id: u32) ?DynamicBaseline {
    var previous = captureBaseline(sys, devices, instance_id) orelse return null;
    var stable_samples: u32 = 0;
    var attempts: u32 = 0;
    while (attempts < baseline_stable_sample_limit) : (attempts += 1) {
        sys.taskYield();
        const current = captureBaseline(sys, devices, instance_id) orelse return null;
        if (dynamicOwnershipSnapshotEqual(previous, current)) {
            stable_samples += 1;
            if (stable_samples == baseline_stable_samples) return current;
        } else {
            stable_samples = 0;
        }
        previous = current;
    }
    return null;
}

fn captureBaseline(sys: *r4os.r4sys.Context, devices: *const r4os.Devices, instance_id: u32) ?DynamicBaseline {
    const performance = devices.performance().summary() orelse return null;
    const memory = devices.memory().summary() orelse return null;
    const instance = findProgramInstance(sys, instance_id) orelse return null;
    var main_info: r4os.abi.ProgramThreadInfo = .{};
    if (sys.threadStatus(0, &main_info) != r4os.abi.thread_ok or main_info.instance_id != instance_id or main_info.task_id == 0) return null;
    return .{
        .task_count = performance.task_count,
        .main_task_id = main_info.task_id,
        .fpu_state_bytes = performance.fpu_state_bytes,
        .fpu_task_state_count = performance.fpu_task_state_count,
        .fpu_task_init_count = performance.fpu_task_init_count,
        .fpu_task_state_bytes = performance.fpu_task_state_bytes,
        .memory_active_blocks = memory.active_blocks,
        .memory_error_blocks = memory.error_blocks,
        .memory_physical_bytes = memory.physical_bytes,
        .memory_reserved_bytes = memory.reserved_bytes,
        .memory_committed_bytes = memory.committed_bytes,
        .memory_free_physical_bytes = memory.free_physical_bytes,
        .memory_app_stack_blocks = memory.by_kind[r4os.abi.memory_kind_app_stack],
        .memory_r4x_owner_blocks = memory.by_owner[r4os.abi.memory_owner_r4x_instance],
        .memory_overflow = memory.overflow,
        .instance_reserved_bytes = instance.memory_reserved_bytes,
        .instance_committed_bytes = instance.memory_committed_bytes,
        .instance_resident_bytes = instance.memory_resident_bytes,
        .instance_stack_reserved_bytes = instance.stack_reserved_bytes,
        .instance_stack_committed_bytes = instance.stack_committed_bytes,
    };
}

fn findProgramInstance(sys: *r4os.r4sys.Context, instance_id: u32) ?r4os.abi.ProgramInstanceInfo {
    var attempt: u32 = 0;
    restart: while (attempt < inventory_restart_limit) : (attempt += 1) {
        var cursor: r4os.abi.ProgramInventoryCursor = .{};
        var summary: r4os.abi.ProgramInventorySummary = .{};
        if (!beginProgramInventory(sys, &cursor, &summary)) return null;
        while (true) {
            var entries: [@as(usize, r4os.abi.program_inventory_page_max)]r4os.abi.ProgramInstanceSnapshot = undefined;
            var page: r4os.abi.ProgramInventoryPageInfo = .{};
            if (!readProgramInventoryPage(sys, &cursor, entries[0..], &page)) return null;
            if (page.status == r4os.abi.program_inventory_status_restart) continue :restart;
            if (page.returned > entries.len or page.snapshot_generation != cursor.snapshot_generation) return null;
            for (entries[0..@intCast(page.returned)]) |entry| {
                if (entry.info.id == instance_id) return entry.info;
            }
            if (page.status == r4os.abi.program_inventory_status_complete) return null;
            if (page.status != r4os.abi.program_inventory_status_more or page.returned == 0) return null;
        }
    }
    return null;
}

fn beginProgramInventory(
    sys: *r4os.r4sys.Context,
    cursor: *r4os.abi.ProgramInventoryCursor,
    summary: *r4os.abi.ProgramInventorySummary,
) bool {
    var retry: u32 = 0;
    while (retry <= inventory_would_block_retry_limit) : (retry += 1) {
        cursor.* = .{};
        summary.* = .{};
        const status = sys.programInventoryBegin(cursor, summary);
        if (status == r4os.abi.program_handle_ok) return true;
        if (status != r4os.abi.program_handle_error_would_block or retry == inventory_would_block_retry_limit)
            return false;
        sys.sleepTicks(1);
    }
    return false;
}

fn readProgramInventoryPage(
    sys: *r4os.r4sys.Context,
    cursor: *r4os.abi.ProgramInventoryCursor,
    entries: []r4os.abi.ProgramInstanceSnapshot,
    page: *r4os.abi.ProgramInventoryPageInfo,
) bool {
    var retry: u32 = 0;
    while (retry <= inventory_would_block_retry_limit) : (retry += 1) {
        const cursor_before = cursor.*;
        page.* = .{};
        const status = sys.programInventoryPrograms(cursor, entries, page);
        if (status == r4os.abi.program_handle_ok) return true;
        cursor.* = cursor_before;
        page.* = .{};
        if (status != r4os.abi.program_handle_error_would_block or retry == inventory_would_block_retry_limit)
            return false;
        sys.sleepTicks(1);
    }
    return false;
}

fn joinedThreadIsGone(sys: *r4os.r4sys.Context, thread_id: u32) bool {
    // R4DEV exposes memory-block/VM aggregates, but no kernel-heap live/used
    // allocation counter (memory_kind_kernel_heap is only heap backing). The
    // public retirement proof is therefore threadStatus(NOT_FOUND): the kernel
    // keeps a ProgramThread whose heap free failed linked and status-visible.
    var stale_info: r4os.abi.ProgramThreadInfo = .{};
    return sys.threadStatus(thread_id, &stale_info) == r4os.abi.thread_error_not_found;
}

fn validJoinHandle(handle: r4os.abi.ProgramJoinHandle) bool {
    return handle.thread_id != 0 and
        handle.instance_id != 0 and
        handle.thread_generation != 0 and
        handle.instance_generation != 0 and
        handle.reserved == 0;
}

fn idSeen(values: []const u32, wanted: u32) bool {
    for (values) |value| {
        if (value == wanted) return true;
    }
    return false;
}

fn dynamicOwnershipSnapshotEqual(a: DynamicBaseline, b: DynamicBaseline) bool {
    return a.task_count == b.task_count and
        a.main_task_id == b.main_task_id and
        a.fpu_task_state_count == b.fpu_task_state_count and
        a.memory_error_blocks == b.memory_error_blocks and
        a.memory_overflow == b.memory_overflow and
        a.instance_reserved_bytes == b.instance_reserved_bytes and
        a.instance_committed_bytes == b.instance_committed_bytes and
        a.instance_resident_bytes == b.instance_resident_bytes and
        a.instance_stack_reserved_bytes == b.instance_stack_reserved_bytes and
        a.instance_stack_committed_bytes == b.instance_stack_committed_bytes;
}

fn dynamicBaselineMatches(before: DynamicBaseline, after: DynamicBaseline) bool {
    const expected_fpu_bytes = @as(u64, dynamic_churn_cycles) * @as(u64, before.fpu_state_bytes);
    return before.fpu_state_bytes != 0 and
        before.task_count == after.task_count and
        before.main_task_id == after.main_task_id and
        before.fpu_task_state_count == after.fpu_task_state_count and
        after.fpu_task_init_count -| before.fpu_task_init_count >= dynamic_churn_cycles and
        after.fpu_task_state_bytes -| before.fpu_task_state_bytes >= expected_fpu_bytes and
        before.memory_error_blocks == after.memory_error_blocks and
        before.memory_overflow == 0 and
        after.memory_overflow == 0 and
        before.instance_reserved_bytes == after.instance_reserved_bytes and
        before.instance_committed_bytes == after.instance_committed_bytes and
        before.instance_resident_bytes == after.instance_resident_bytes and
        before.instance_stack_reserved_bytes == after.instance_stack_reserved_bytes and
        before.instance_stack_committed_bytes == after.instance_stack_committed_bytes and
        growthWithin(before.memory_app_stack_blocks, after.memory_app_stack_blocks, global_memory_block_growth_limit) and
        growthWithin(before.memory_r4x_owner_blocks, after.memory_r4x_owner_blocks, global_memory_block_growth_limit) and
        growthWithin(before.memory_active_blocks, after.memory_active_blocks, global_memory_block_growth_limit) and
        growthWithin(before.memory_physical_bytes, after.memory_physical_bytes, global_memory_byte_growth_limit) and
        growthWithin(before.memory_reserved_bytes, after.memory_reserved_bytes, global_memory_byte_growth_limit) and
        growthWithin(before.memory_committed_bytes, after.memory_committed_bytes, global_memory_byte_growth_limit) and
        dropWithin(before.memory_free_physical_bytes, after.memory_free_physical_bytes, global_memory_byte_growth_limit);
}

fn growthWithin(before: u64, after: u64, limit: u64) bool {
    return after <= before or after - before <= limit;
}

fn dropWithin(before: u64, after: u64, limit: u64) bool {
    return after >= before or before - after <= limit;
}

fn printDynamicBaseline(sys: *r4os.r4sys.Context, before: DynamicBaseline, after: DynamicBaseline) void {
    sys.write("THREADD dynamic baseline task=");
    printPair(sys, before.task_count, after.task_count);
    sys.write(" fpu=");
    printPair(sys, before.fpu_task_state_count, after.fpu_task_state_count);
    sys.write(" fpuInitDelta=");
    sys.printU64(after.fpu_task_init_count -| before.fpu_task_init_count);
    sys.write(" fpuBytesDelta=");
    sys.printU64(after.fpu_task_state_bytes -| before.fpu_task_state_bytes);
    sys.println("");
    sys.write("THREADD dynamic memory instanceReserved=");
    printPair(sys, before.instance_reserved_bytes, after.instance_reserved_bytes);
    sys.write(" instanceCommitted=");
    printPair(sys, before.instance_committed_bytes, after.instance_committed_bytes);
    sys.write(" instanceResident=");
    printPair(sys, before.instance_resident_bytes, after.instance_resident_bytes);
    sys.write(" stackReserved=");
    printPair(sys, before.instance_stack_reserved_bytes, after.instance_stack_reserved_bytes);
    sys.write(" stackCommitted=");
    printPair(sys, before.instance_stack_committed_bytes, after.instance_stack_committed_bytes);
    sys.println(" exact=OK");
    sys.write("THREADD dynamic memory global appStack=");
    printPair(sys, before.memory_app_stack_blocks, after.memory_app_stack_blocks);
    sys.write(" r4xOwner=");
    printPair(sys, before.memory_r4x_owner_blocks, after.memory_r4x_owner_blocks);
    sys.write(" blocks=");
    printPair(sys, before.memory_active_blocks, after.memory_active_blocks);
    sys.write(" physical=");
    printPair(sys, before.memory_physical_bytes, after.memory_physical_bytes);
    sys.write(" reserved=");
    printPair(sys, before.memory_reserved_bytes, after.memory_reserved_bytes);
    sys.write(" committed=");
    printPair(sys, before.memory_committed_bytes, after.memory_committed_bytes);
    sys.println(" drift=bounded");
}

fn printPair(sys: *r4os.r4sys.Context, before: anytype, after: @TypeOf(before)) void {
    sys.printU64(@intCast(before));
    sys.write("/");
    sys.printU64(@intCast(after));
}

fn dynamicWorkerMain(arg: u64) callconv(.c) i32 {
    var sys = global_sys orelse return 100;
    const index: usize = @intCast(arg);
    if (index >= dynamic_concurrency) return 101;
    @as(*volatile bool, &dynamic_started[index]).* = true;
    while (!@as(*volatile bool, &dynamic_release).*) {
        @as(*volatile u32, &dynamic_progress[index]).* +%= 1;
        switch (index & 3) {
            0 => sys.taskYield(),
            1 => sys.sleepTicks(1),
            2 => sys.sleepTicks(2),
            else => {
                var spin: u32 = 0;
                while (spin < 256) : (spin += 1) @as(*volatile u32, &dynamic_progress[index]).* +%= 1;
                sys.taskYield();
            },
        }
    }
    return @intCast(index & 0x7FFF);
}

fn startedCount() usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < dynamic_started.len) : (index += 1) {
        if (@as(*volatile bool, &dynamic_started[index]).*) count += 1;
    }
    return count;
}

fn argsEqual(args: []const u8, expected: []const u8) bool {
    if (args.len != expected.len) return false;
    for (args, expected) |a, b| {
        const folded = if (a >= 'a' and a <= 'z') a - ('a' - 'A') else a;
        if (folded != b) return false;
    }
    return true;
}

fn workerMain(arg: u64) callconv(.c) i32 {
    var sys = global_sys orelse return 10;
    var self: r4os.abi.ProgramThreadInfo = .{};
    if (sys.threadStatus(0, &self) != r4os.abi.thread_ok) return 11;
    var i: usize = 0;
    while (i < arg) : (i += 1) {
        @as(*volatile u64, &shared_counter).* += 3;
        sys.sleepTicks(1);
    }
    return 40 + @as(i32, @intCast(arg));
}

fn workerExitMain(arg: u64) callconv(.c) i32 {
    var sys = global_sys orelse return 20;
    @as(*volatile usize, &exit_worker_arg).* = arg;
    sys.threadExit(60 + @as(i32, @intCast(arg)));
}

fn timeoutWorkerMain(_: u64) callconv(.c) i32 {
    var sys = global_sys orelse return 21;
    while (!@as(*volatile bool, &timeout_release).*) sys.taskYield();
    return 61;
}

fn stressWorkerMain(arg: u64) callconv(.c) i32 {
    return @intCast(arg);
}

fn fail(sys: *r4os.r4sys.Context, msg: []const u8) i32 {
    sys.println(msg);
    sys.println("THREADD result: FAILED");
    return 1;
}
