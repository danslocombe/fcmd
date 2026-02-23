# Zig 0.16.0-dev Migration Notes

Migrated from an older Zig version to `0.16.0-dev.2565+684032671`.

## build.zig

**`linkLibC` moved from `Compile` to `Module`**

```zig
// Before
exe.linkLibC();

// After
exe.root_module.link_libc = true;
```

Applied to: `exe`, `basic_tests`, `phase1_tests`, `phase2_tests`, `phase3_tests`, `phase5_tests`, `exe_check`.

---

## src/alloc.zig

**Added global `Io` instance** — required because most filesystem and mutex operations now take an `Io` parameter that was previously implicit.

```zig
pub var g_io: std.Io = undefined;
```

Initialized early in `main` from the runtime-provided `init.io`.

---

## src/main.zig

**`main` signature** — switched from parameterless to `std.process.Init` to receive the runtime-provided `Io`, allocator, and args.

```zig
// Before
pub fn main() !void {
    var args = std.process.argsAlloc(alloc.gpa.allocator()) catch unreachable;
    defer std.process.argsFree(alloc.gpa.allocator(), args);

// After
pub fn main(init: std.process.Init) !void {
    alloc.g_io = init.io;
    var args_arena = std.heap.ArenaAllocator.init(alloc.gpa.allocator());
    defer args_arena.deinit();
    const args = try init.minimal.args.toSlice(args_arena.allocator());
```

**`std.fs.cwd()` filesystem operations** — now go through `std.Io.Dir` and require an `Io` parameter.

```zig
// Before
std.fs.cwd().realpathAlloc(allocator, path)
std.fs.cwd().makePath(path)

// After
std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io, path, allocator)  // returns [:0]u8
std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, path)
```

**`resolveAndCreateStatePath` return type** changed from `![]const u8` to `![:0]u8` to match `realPathFileAlloc`'s return type and prevent allocator size-mismatch crashes on `free`.

**`data_mutex` lock/unlock** updated (see `data.zig` section).

**`runTestMode` / `runVerifyTest` signatures** — args element type changed from `[]const u8` to `[:0]const u8` to match `Args.toSlice` output.

---

## src/data.zig

**`std.Thread.Mutex` → `std.Io.Mutex`** — mutex API now requires an `Io` parameter.

```zig
// Before
data_mutex: std.Thread.Mutex = .{},
mmap_context.data_mutex.lock();
mmap_context.data_mutex.unlock();

// After
data_mutex: std.Io.Mutex = .init,
mmap_context.data_mutex.lockUncancelable(alloc.g_io);
mmap_context.data_mutex.unlock(alloc.g_io);
```

**`std.fs.makeDirAbsolute`** removed.

```zig
// Before
std.fs.makeDirAbsolute(state_dir) catch |err| { ... }

// After
std.Io.Dir.createDirPath(std.Io.Dir.cwd(), alloc.g_io, state_dir) catch |err| { ... }
```

---

## src/preprompt.zig

**`std.fs.cwd()` + `std.os.getFdPath`** replaced with `std.process.currentPath`.

```zig
// Before
var cwd = std.fs.cwd();
var buffer: [std.os.windows.PATH_MAX_WIDE * 3 + 1]u8 = undefined;
const filename = std.os.getFdPath(cwd.fd, &buffer) catch unreachable;

// After
var buffer: [std.os.windows.PATH_MAX_WIDE * 3 + 1]u8 = undefined;
const len = std.process.currentPath(alloc.g_io, &buffer) catch unreachable;
const filename = buffer[0..len];
```

---

## src/completion.zig

**Directory iteration** — `std.fs.Dir` / `CopyPastedFromStdLibWithAdditionalSafety` replaced with the new `std.Io.Dir` API.

```zig
// Before
const cwd = std.fs.cwd();
var dir: std.fs.Dir = undefined;
if (windows.CopyPastedFromStdLibWithAdditionalSafety.openIterableDir(cwd, rel_dir, .{})) |rdir| {
    dir = rdir;
} else |_| { return; }
defer dir.close();
var iter = dir.iterate();
while (iter.next()) |m_file| { ... } else |_| { return; }

// After
const cwd = std.Io.Dir.cwd();
const dir = std.Io.Dir.openDir(cwd, alloc.g_io, rel_dir, .{ .iterate = true }) catch return;
defer dir.close(alloc.g_io);
var iter = dir.iterate();
while (iter.next(alloc.g_io) catch return) |file| { ... }
```

**`std.fs.File.Kind.file` → `std.Io.File.Kind.file`**

**`LocalHistoryCompleter.add_prefix`** — fixed allocator size mismatch. `realPathFileAlloc` returns `[:0]u8` (N+1 bytes allocated) but `cwd_path` is `?[]const u8` (N bytes visible). Dupe avoids the sentinel mismatch on `free`.

```zig
// Before (crashes: free(N) but allocated N+1)
self.cwd_path = cwd.realpathAlloc(alloc.gpa.allocator(), "") catch unreachable;

// After
const realpath = std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), alloc.g_io, ".", alloc.gpa.allocator()) catch unreachable;
defer alloc.gpa.allocator().free(realpath);
self.cwd_path = alloc.gpa.allocator().dupe(u8, realpath) catch unreachable;
```

---

## src/windows.zig

**`CopyPastedFromStdLibWithAdditionalSafety` removed** — this was a copy of old stdlib directory-open code using `std.fs.Dir`, which no longer exists. The new `std.Io.Dir.openDir` handles errors cleanly.

**`std.os.windows.SetConsoleCtrlHandler`** removed from stdlib, now called via C import.

```zig
// Before
std.os.windows.SetConsoleCtrlHandler(control_signal_handler, true) catch @panic("...");

// After
if (import.SetConsoleCtrlHandler(control_signal_handler, 1) == 0) @panic("...");
```

**`CTRL_C/BREAK/CLOSE_EVENT`** removed from stdlib, defined as local constants (values 0/1/2).

**New exports** added for items removed from `std.os.windows`:

```zig
pub const PROCESS_INFORMATION = extern struct {
    hProcess: std.os.windows.HANDLE,
    hThread: std.os.windows.HANDLE,
    dwProcessId: std.os.windows.DWORD,
    dwThreadId: std.os.windows.DWORD,
};
pub const INFINITE: std.os.windows.DWORD = 0xFFFFFFFF;
pub const CTRL_C_EVENT: std.os.windows.DWORD = 0;
pub const CTRL_BREAK_EVENT: std.os.windows.DWORD = 1;
pub const CTRL_CLOSE_EVENT: std.os.windows.DWORD = 2;

pub fn SetCurrentDirectoryW(path: [*:0]const u16) bool { ... }
pub fn CreateProcessW(lp_command_line, creation_flags, startup_info, process_info) bool { ... }
```

---

## src/run.zig

**`std.os.windows.PROCESS_INFORMATION`** → `windows.PROCESS_INFORMATION`

**`std.os.windows.SetCurrentDirectory(slice)`** replaced with null-terminated version:

```zig
// Before
const utf16_buffer = alloc.temp_alloc.allocator().alloc(u16, cd.len) catch unreachable;
_ = std.unicode.utf8ToUtf16Le(utf16_buffer, cd) catch unreachable;
std.os.windows.SetCurrentDirectory(utf16_buffer) catch |err| { ... };

// After
const utf16_buffer = std.unicode.utf8ToUtf16LeAllocZ(alloc.temp_alloc.allocator(), cd) catch unreachable;
if (!windows.SetCurrentDirectoryW(utf16_buffer.ptr)) { ... }
```

**`std.os.windows.CreateProcessW`** → `windows.CreateProcessW` wrapper (C import, BOOL return)

**`std.os.windows.WaitForSingleObject` / `INFINITE`** → `windows.WaitForSingleObject` / `windows.INFINITE`

---

---

## src/test_phase5.zig + src/test_multiprocess.zig

**`std.process.getEnvVarOwned`** removed. Replacement uses `Environ.getAlloc` with the global env block:

```zig
// Before
std.process.getEnvVarOwned(alloc, "TEMP") catch ...

// After
(std.process.Environ{ .block = .global }).getAlloc(alloc, "TEMP") catch ...
```

**`std.fs.cwd()` in test context** — use `std.Io.Dir.cwd()` with `std.testing.io`:

```zig
// Before
std.fs.cwd().deleteFile(path) catch {};

// After
std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
```

**`std.process.Child` API** fully replaced by top-level `std.process.spawn`:

```zig
// Before
var child = std.process.Child.init(args, alloc);
child.stdout_behavior = .Inherit;
child.stderr_behavior = .Inherit;
try child.spawn();

// After
const child = try std.process.spawn(std.testing.io, .{
    .argv = args,
    .stdout = .inherit,
    .stderr = .inherit,
});
```

**`child.kill()` / `child.wait()`** now take `io` and `kill` is `void`:

```zig
// Before
_ = proc.kill() catch {};
const term = try proc.wait();
switch (term) { .Exited => |code| ..., else => 255 }

// After
proc.kill(std.testing.io);
const term = try proc.wait(std.testing.io);
switch (term) { .exited => |code| ..., else => 255 }
```

---

## src/data.zig (runtime fix)

**Named event left signaled by crashed processes** — `CreateEventA` with a named event opens the existing
object without resetting its state. If a previous fcmd process crashed mid-remap, `fcmd_unload_data` could
be left signaled, causing the background_unloader_loop to fire immediately on next startup and deadlock
(holds mutex while waiting for reload_event that is never set). Fix: call `ResetEvent` after create/open.

```zig
// After creating unload_event:
_ = windows.ResetEvent(unload_event); // Reset if left signaled by a crashed process
```

---

## Still present in `std.os.windows` (no changes needed)

- `DWORD`, `BOOL`, `HANDLE`
- `CloseHandle`
- `CreateProcessFlags`
- `STARTUPINFOW`
- `UNICODE_STRING`, `OBJECT_ATTRIBUTES`, `ntdll.NtCreateFile`, etc.
