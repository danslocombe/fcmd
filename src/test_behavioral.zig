const std = @import("std");
const test_exports = @import("test_exports.zig");
const lego_trie = test_exports.lego_trie;
const data = test_exports.data;
const alloc = test_exports.alloc;
const completion = test_exports.completion;

const CompletionHandler = completion.CompletionHandler;
const DirectoryCompleter = completion.DirectoryCompleter;
const PathCompleter = completion.PathCompleter;
const GetCompletionFlags = completion.GetCompletionFlags;

// ---------------------------------------------------------------------------
// MockFS — fake filesystem for testing directory completion without real I/O
// ---------------------------------------------------------------------------

const MockFS = struct {
    dirs: [16]MockDir = [_]MockDir{.{}} ** 16,
    dir_count: usize = 0,

    const MockDir = struct {
        path: []const u8 = "",
        entries: [16]MockEntry = [_]MockEntry{.{}} ** 16,
        entry_count: usize = 0,
    };

    const MockEntry = struct {
        name: []const u8 = "",
        is_dir: bool = false,
    };

    fn reset(self: *MockFS) void {
        self.dir_count = 0;
    }

    fn addDir(self: *MockFS, path: []const u8) *MockDir {
        const idx = self.dir_count;
        self.dirs[idx] = .{ .path = path };
        self.dir_count += 1;
        return &self.dirs[idx];
    }

    fn addEntry(dir: *MockDir, name: []const u8, is_dir: bool) void {
        dir.entries[dir.entry_count] = .{ .name = name, .is_dir = is_dir };
        dir.entry_count += 1;
    }

    fn findDir(self: *MockFS, path: []const u8) ?*const MockDir {
        for (self.dirs[0..self.dir_count]) |*dir| {
            if (std.mem.eql(u8, dir.path, path)) return dir;
        }
        return null;
    }

    /// Check whether `path` names a directory in the mock filesystem.
    fn isDirectory(self: *MockFS, path: []const u8) bool {
        for (self.dirs[0..self.dir_count]) |*dir| {
            for (dir.entries[0..dir.entry_count]) |entry| {
                if (!entry.is_dir) continue;
                if (dir.path.len == 0) {
                    if (std.mem.eql(u8, path, entry.name)) return true;
                } else {
                    // Try both separator styles so that absolute paths
                    // like "C:\Users" match dirs registered as "C:".
                    for ([_][]const u8{ "/", "\\" }) |sep| {
                        const full = std.mem.concat(
                            alloc.temp_alloc.allocator(),
                            u8,
                            &.{ dir.path, sep, entry.name },
                        ) catch continue;
                        if (std.mem.eql(u8, path, full)) return true;
                    }
                }
            }
        }
        return false;
    }
};

var global_mock_fs: MockFS = .{};

// ---------------------------------------------------------------------------
// MockExeList — fake PATH executables for testing
// ---------------------------------------------------------------------------

var global_mock_exes: [32][]const u8 = undefined;
var global_mock_exe_count: usize = 0;

fn mock_exe_list_reset() void {
    global_mock_exe_count = 0;
}

fn mock_exe_list_add(name: []const u8) void {
    global_mock_exes[global_mock_exe_count] = name;
    global_mock_exe_count += 1;
}

fn mock_exe_lister() ?std.ArrayList([]const u8) {
    if (global_mock_exe_count == 0) return null;
    var list: std.ArrayList([]const u8) = .{};
    for (global_mock_exes[0..global_mock_exe_count]) |name| {
        list.append(alloc.gpa.allocator(), alloc.copy_slice_to_gpa(name)) catch unreachable;
    }
    return list;
}

fn mock_dir_validator(prefix: []const u8, comp: []const u8) bool {
    const full = std.mem.concat(alloc.temp_alloc.allocator(), u8, &.{ prefix, comp }) catch return false;
    var last_word: []const u8 = full;
    var words_iter = std.mem.tokenizeAny(u8, full, " ");
    while (words_iter.next()) |word| {
        last_word = word;
    }
    return global_mock_fs.isDirectory(last_word);
}

fn mock_file_lister(rel_dir: []const u8) ?std.ArrayList(DirectoryCompleter.FileInfo) {
    const dir = global_mock_fs.findDir(rel_dir) orelse return null;
    var list: std.ArrayList(DirectoryCompleter.FileInfo) = .{};
    for (dir.entries[0..dir.entry_count]) |entry| {
        list.append(alloc.gpa.allocator(), .{
            .name = alloc.copy_slice_to_gpa(entry.name),
            .is_dir = entry.is_dir,
        }) catch unreachable;
    }
    return list;
}

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

const BehavioralTest = struct {
    handler: CompletionHandler,
    backing: [4096]lego_trie.TrieBlock,
    len: std.atomic.Value(usize),
    context: data.MMapContext,
    blocks: data.MappedArray(lego_trie.TrieBlock),
};

fn init_behavioral_test(bt: *BehavioralTest) void {
    alloc.g_io = std.testing.io;
    global_mock_fs.reset();
    mock_exe_list_reset();

    bt.len = std.atomic.Value(usize).init(0);
    bt.context = .{};
    bt.blocks = .{
        .len = &bt.len,
        .map = &bt.backing,
        .mmap_context = &bt.context,
    };

    const trie = lego_trie.Trie.init(&bt.blocks);
    const base = completion.HistoryCompleter{ .trie = trie };
    bt.handler = CompletionHandler{
        .global_history = .{ .completer = base },
        .local_history = .{ .completer = base },
        .directory_completer = .{ .file_lister = &mock_file_lister },
        .path_completer = .{ .exe_lister = &mock_exe_lister },
        .dir_validator = &mock_dir_validator,
    };
    bt.handler.local_history.cwd_path = "TEST_CWD";
}

/// Insert a command into local history and reset the directory completer,
/// simulating what happens when the user runs a command.
fn simulateCommand(bt: *BehavioralTest, cmd: []const u8) void {
    bt.handler.local_history.insert(cmd);
    bt.handler.directory_completer.clear();
    bt.handler.cycle_index = 0;
}

fn getCompletion(bt: *BehavioralTest, prefix: []const u8, flags: GetCompletionFlags, cycle: usize) ?[]const u8 {
    bt.handler.cycle_index = cycle;
    return bt.handler.get_completion(prefix, flags);
}

fn expectCompletion(
    bt: *BehavioralTest,
    prefix: []const u8,
    flags: GetCompletionFlags,
    cycle: usize,
    expected: []const u8,
) !void {
    const result = getCompletion(bt, prefix, flags, cycle) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(expected, result);
}

fn expectNoCompletion(
    bt: *BehavioralTest,
    prefix: []const u8,
    flags: GetCompletionFlags,
    cycle: usize,
) !void {
    const result = getCompletion(bt, prefix, flags, cycle);
    try std.testing.expect(result == null);
}

const cd_flag: GetCompletionFlags = .{ .complete_to_directories_not_files = true };
const no_flag: GetCompletionFlags = .{};

// ---------------------------------------------------------------------------
// Test 1: cd completes to directories, skipping files
// ---------------------------------------------------------------------------

test "cd completes to directories, skipping files" {
    var bt: BehavioralTest = undefined;
    init_behavioral_test(&bt);

    // MockFS: cwd has Documents(dir), Dockerfile(file), Downloads(dir)
    const root = MockFS.addDir(&global_mock_fs, "");
    MockFS.addEntry(root, "Documents", true);
    MockFS.addEntry(root, "Dockerfile", false);
    MockFS.addEntry(root, "Downloads", true);

    // No history — all completions come from the directory completer.
    // "Dockerfile" must be skipped because it is a file, not a directory.
    try expectCompletion(&bt, "cd D", cd_flag, 0, "ocuments");
    try expectCompletion(&bt, "cd D", cd_flag, 1, "ownloads");
    try expectNoCompletion(&bt, "cd D", cd_flag, 2);
}

// ---------------------------------------------------------------------------
// Test 2: History completions preferred over directory listing
// ---------------------------------------------------------------------------

test "history completions preferred over directory listing" {
    var bt: BehavioralTest = undefined;
    init_behavioral_test(&bt);

    // MockFS: cwd has Documents(dir), Downloads(dir)
    const root = MockFS.addDir(&global_mock_fs, "");
    MockFS.addEntry(root, "Documents", true);
    MockFS.addEntry(root, "Downloads", true);

    // User previously ran "cd Documents" — it goes into history.
    simulateCommand(&bt, "cd Documents");

    // cycle 0 comes from history (the validated "Documents" entry).
    try expectCompletion(&bt, "cd D", cd_flag, 0, "ocuments");

    // After history is exhausted, the directory completer kicks in.
    // Dir completer cycle 0 = Documents, cycle 1 = Downloads.
    try expectCompletion(&bt, "cd D", cd_flag, 1, "ocuments"); // dir completer
    try expectCompletion(&bt, "cd D", cd_flag, 2, "ownloads"); // dir completer
    try expectNoCompletion(&bt, "cd D", cd_flag, 3);
}

// ---------------------------------------------------------------------------
// Test 3: History skips deleted directories
// ---------------------------------------------------------------------------

test "history skips deleted directories" {
    var bt: BehavioralTest = undefined;
    init_behavioral_test(&bt);

    // MockFS: cwd has Downloads only — Documents has been "deleted".
    const root = MockFS.addDir(&global_mock_fs, "");
    MockFS.addEntry(root, "Downloads", true);

    // History has both (from previous sessions).
    simulateCommand(&bt, "cd Documents");
    simulateCommand(&bt, "cd Downloads");

    // "Documents" is skipped by the validator (not in MockFS).
    // cycle 0 = "Downloads" from history.
    try expectCompletion(&bt, "cd D", cd_flag, 0, "ownloads");
    // Dir completer only has Downloads.
    try expectCompletion(&bt, "cd D", cd_flag, 1, "ownloads"); // dir completer
    try expectNoCompletion(&bt, "cd D", cd_flag, 2);
}

// ---------------------------------------------------------------------------
// Test 4: Non-cd mode returns best match without dir validation
// ---------------------------------------------------------------------------

test "non-cd mode returns match without dir validation" {
    var bt: BehavioralTest = undefined;
    init_behavioral_test(&bt);

    // History contains "git status".
    simulateCommand(&bt, "git status");

    // Non-cd mode: no directory validation, just best match from history.
    try expectCompletion(&bt, "git s", no_flag, 0, "tatus");
}

// ---------------------------------------------------------------------------
// Test 5: Tab cycling across history and directory completer
// ---------------------------------------------------------------------------

test "tab cycling across history and directory completer" {
    var bt: BehavioralTest = undefined;
    init_behavioral_test(&bt);

    // MockFS: cwd has Documents(dir), Downloads(dir), Desktop(dir)
    const root = MockFS.addDir(&global_mock_fs, "");
    MockFS.addEntry(root, "Documents", true);
    MockFS.addEntry(root, "Downloads", true);
    MockFS.addEntry(root, "Desktop", true);

    simulateCommand(&bt, "cd Documents");
    simulateCommand(&bt, "cd Downloads");

    // cycle 0, 1: from local history (both valid dirs, trie order unspecified)
    const h0 = getCompletion(&bt, "cd D", cd_flag, 0) orelse return error.TestExpectedEqual;
    const h1 = getCompletion(&bt, "cd D", cd_flag, 1) orelse return error.TestExpectedEqual;
    // Must be different and both from the history set.
    try std.testing.expect(!std.mem.eql(u8, h0, h1));
    const h_has_ocuments = std.mem.eql(u8, h0, "ocuments") or std.mem.eql(u8, h1, "ocuments");
    const h_has_ownloads = std.mem.eql(u8, h0, "ownloads") or std.mem.eql(u8, h1, "ownloads");
    try std.testing.expect(h_has_ocuments);
    try std.testing.expect(h_has_ownloads);

    // cycle 2..4: directory completer (Documents, Downloads, Desktop in MockFS order)
    try expectCompletion(&bt, "cd D", cd_flag, 2, "ocuments");
    try expectCompletion(&bt, "cd D", cd_flag, 3, "ownloads");
    try expectCompletion(&bt, "cd D", cd_flag, 4, "esktop");

    // Exhausted.
    try expectNoCompletion(&bt, "cd D", cd_flag, 5);
}

// ---------------------------------------------------------------------------
// Test 6: Subdirectory path completion
// ---------------------------------------------------------------------------

test "subdirectory path completion" {
    var bt: BehavioralTest = undefined;
    init_behavioral_test(&bt);

    // MockFS: "src" directory has main.zig(file), lib(dir), tests(dir)
    const src = MockFS.addDir(&global_mock_fs, "src");
    MockFS.addEntry(src, "main.zig", false);
    MockFS.addEntry(src, "lib", true);
    MockFS.addEntry(src, "tests", true);

    // No history. "cd src/" extracts rel_dir="src", prefix_for_query="".
    // main.zig is skipped (file). lib and tests are directories.
    try expectCompletion(&bt, "cd src/", cd_flag, 0, "lib");
    try expectCompletion(&bt, "cd src/", cd_flag, 1, "tests");
    try expectNoCompletion(&bt, "cd src/", cd_flag, 2);
}

// ---------------------------------------------------------------------------
// Test 7: Absolute path completion (cd C:\Us → cd C:\Users)
// ---------------------------------------------------------------------------

test "cd completes absolute paths" {
    var bt: BehavioralTest = undefined;
    init_behavioral_test(&bt);

    // MockFS: "C:" drive root has Users(dir), Windows(dir), pagefile.sys(file)
    const drive = MockFS.addDir(&global_mock_fs, "C:");
    MockFS.addEntry(drive, "Users", true);
    MockFS.addEntry(drive, "Windows", true);
    MockFS.addEntry(drive, "pagefile.sys", false);

    // "cd C:\Us" → last_word "C:\Us", path "C:", prefix "Us"
    // regenerate("C:") opens "C:\" (bare drive fix), lists root.
    // pagefile.sys skipped (file). "Users" matches prefix "Us".
    try expectCompletion(&bt, "cd C:\\Us", cd_flag, 0, "ers");
    try expectCompletion(&bt, "cd C:\\W", cd_flag, 0, "indows");
    try expectNoCompletion(&bt, "cd C:\\Z", cd_flag, 0);
}

// ---------------------------------------------------------------------------
// Test 8: Absolute path with history validation
// ---------------------------------------------------------------------------

test "cd absolute path history validated" {
    var bt: BehavioralTest = undefined;
    init_behavioral_test(&bt);

    // MockFS: "C:" drive root has Users(dir)
    const drive = MockFS.addDir(&global_mock_fs, "C:");
    MockFS.addEntry(drive, "Users", true);

    // History has "cd C:\Users" — validator should confirm it exists.
    simulateCommand(&bt, "cd C:\\Users");

    // cycle 0 from history (validated), cycle 1 from dir completer.
    try expectCompletion(&bt, "cd C:\\Us", cd_flag, 0, "ers");
    try expectCompletion(&bt, "cd C:\\Us", cd_flag, 1, "ers"); // dir completer
    try expectNoCompletion(&bt, "cd C:\\Us", cd_flag, 2);
}

// ---------------------------------------------------------------------------
// Test 9: PATH completes first word
// ---------------------------------------------------------------------------

test "PATH completes first word" {
    var bt: BehavioralTest = undefined;
    init_behavioral_test(&bt);

    mock_exe_list_add("notepad");
    mock_exe_list_add("npm");

    try expectCompletion(&bt, "note", no_flag, 0, "pad");
    try expectCompletion(&bt, "np", no_flag, 0, "m");
}

// ---------------------------------------------------------------------------
// Test 10: PATH skipped when prefix contains spaces (arguments)
// ---------------------------------------------------------------------------

test "PATH skipped for arguments" {
    var bt: BehavioralTest = undefined;
    init_behavioral_test(&bt);

    mock_exe_list_add("notepad");

    // "git note" has a space — user is typing an argument, not a command.
    try expectNoCompletion(&bt, "git note", no_flag, 0);
}

// ---------------------------------------------------------------------------
// Test 11: PATH skipped in cd mode
// ---------------------------------------------------------------------------

test "PATH skipped in cd mode" {
    var bt: BehavioralTest = undefined;
    init_behavioral_test(&bt);

    mock_exe_list_add("notepad");

    // cd mode should never offer PATH executables.
    try expectNoCompletion(&bt, "cd note", cd_flag, 0);
}

// ---------------------------------------------------------------------------
// Test 12: Cycling across history, directory, and PATH sources
// ---------------------------------------------------------------------------

test "cycling across history directory and PATH" {
    var bt: BehavioralTest = undefined;
    init_behavioral_test(&bt);

    // MockFS: cwd has "notes.txt" file
    const root = MockFS.addDir(&global_mock_fs, "");
    MockFS.addEntry(root, "notes.txt", false);

    // PATH has "notepad"
    mock_exe_list_add("notepad");

    // No history for "note" prefix.
    // cycle 0: directory completer finds "notes.txt"
    try expectCompletion(&bt, "note", no_flag, 0, "s.txt");
    // cycle 1: PATH completer finds "notepad"
    try expectCompletion(&bt, "note", no_flag, 1, "pad");
    // cycle 2: exhausted
    try expectNoCompletion(&bt, "note", no_flag, 2);
}

// ---------------------------------------------------------------------------
// Test 13: PATH deduplication and cycling
// ---------------------------------------------------------------------------

test "PATH cycles through multiple matches" {
    var bt: BehavioralTest = undefined;
    init_behavioral_test(&bt);

    mock_exe_list_add("gist");
    mock_exe_list_add("git");

    try expectCompletion(&bt, "gi", no_flag, 0, "st");
    try expectCompletion(&bt, "gi", no_flag, 1, "t");
    try expectNoCompletion(&bt, "gi", no_flag, 2);
}

// ===========================================================================
// Environment variable expansion tests
// ===========================================================================

const expand_env_vars = test_exports.run.expand_env_vars;

fn mock_env_lookup(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "HOME")) return "/users/alice";
    if (std.mem.eql(u8, name, "A")) return "val_a";
    if (std.mem.eql(u8, name, "B")) return "val_b";
    return null;
}

test "expand_env_vars: simple expansion" {
    alloc.g_io = std.testing.io;
    const result = expand_env_vars("cd %HOME%\\Documents", &mock_env_lookup);
    try std.testing.expectEqualStrings("cd /users/alice\\Documents", result);
}

test "expand_env_vars: undefined stays literal" {
    alloc.g_io = std.testing.io;
    const result = expand_env_vars("echo %NOPE%", &mock_env_lookup);
    try std.testing.expectEqualStrings("echo %NOPE%", result);
}

test "expand_env_vars: multiple vars" {
    alloc.g_io = std.testing.io;
    const result = expand_env_vars("%A% and %B%", &mock_env_lookup);
    try std.testing.expectEqualStrings("val_a and val_b", result);
}

test "expand_env_vars: trailing percent" {
    alloc.g_io = std.testing.io;
    const result = expand_env_vars("echo %", &mock_env_lookup);
    try std.testing.expectEqualStrings("echo %", result);
}

test "expand_env_vars: empty var name (%%)" {
    alloc.g_io = std.testing.io;
    const result = expand_env_vars("echo %%", &mock_env_lookup);
    try std.testing.expectEqualStrings("echo %%", result);
}

test "expand_env_vars: no vars passthrough" {
    alloc.g_io = std.testing.io;
    const result = expand_env_vars("git status", &mock_env_lookup);
    try std.testing.expectEqualStrings("git status", result);
}

test "expand_env_vars: adjacent vars" {
    alloc.g_io = std.testing.io;
    const result = expand_env_vars("%A%%B%", &mock_env_lookup);
    try std.testing.expectEqualStrings("val_aval_b", result);
}
