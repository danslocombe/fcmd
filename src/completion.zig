const std = @import("std");
const alloc = @import("alloc.zig");
const data = @import("data.zig");
const windows = @import("windows.zig");

const lego_trie = @import("datastructures/lego_trie.zig");

pub const GetCompletionFlags = packed struct {
    complete_to_files_from_empty_prefix: bool = false,
    complete_to_directories_not_files: bool = false,
};

pub const DirValidator = *const fn ([]const u8, []const u8) bool;

pub const CompletionHandler = struct {
    local_history: LocalHistoryCompleter,
    global_history: GlobalHistoryCompleter,
    directory_completer: DirectoryCompleter,
    path_completer: PathCompleter = .{},

    cycle_index: usize = 0,
    dir_validator: ?DirValidator = null,

    pub fn init(trie_blocks: *data.MappedArray(lego_trie.TrieBlock)) CompletionHandler {
        const base = HistoryCompleter.init(trie_blocks);
        return .{
            .global_history = .{ .completer = base },
            .local_history = .{ .completer = base },
            .directory_completer = .{},
            .path_completer = .{},
        };
    }

    pub fn update(self: *CompletionHandler, cmd: []const u8) void {
        self.cycle_index = 0;

        //std.debug.print("Adding to local history...\n", .{});
        self.local_history.insert(cmd);
        if (is_global_command_heuristic(cmd)) {
            //std.debug.print("Adding to global history...\n", .{});
            self.global_history.insert(cmd);
        }

        self.directory_completer.clear();
    }

    pub fn get_completion(self: *CompletionHandler, prefix: []const u8, flags: GetCompletionFlags) ?[]const u8 {
        // No completions for empty prefix.
        if (prefix.len == 0) {
            return null;
        }

        var cycle = self.cycle_index;
        const validate = self.dir_validator orelse is_completion_a_directory;

        if (flags.complete_to_directories_not_files) {
            // cd mode: iterate history completions, validate each as directory
            var local_iter = self.local_history.iter(prefix);
            while (local_iter.next()) |completion| {
                if (validate(prefix, completion)) {
                    if (cycle == 0) return completion;
                    cycle -|= 1;
                }
            }
            var global_iter = self.global_history.iter(prefix);
            while (global_iter.next()) |completion| {
                if (validate(prefix, completion)) {
                    if (cycle == 0) return completion;
                    cycle -|= 1;
                }
            }
        } else {
            // Non-cd: single best result (existing behavior)
            if (self.local_history.get_completion(prefix, flags)) |completion| {
                if (cycle == 0) return completion;
                cycle -|= 1;
            }
            if (self.global_history.get_completion(prefix, flags)) |completion| {
                if (cycle == 0) return completion;
                cycle -|= 1;
            }
        }

        if (!has_unclosed_quotes(prefix)) {
            if (self.directory_completer.get_completion(prefix, cycle, flags)) |completion| {
                return completion;
            }
            cycle -|= self.directory_completer.last_match_count;
        }

        // PATH executable completion — only for the first word, not in cd mode
        if (!flags.complete_to_directories_not_files) {
            if (self.path_completer.get_completion(prefix, cycle)) |completion| {
                return completion;
            }
        }

        return null;
    }
};

pub const DirectoryCompleter = struct {
    pub const FileInfo = struct {
        name: []const u8,
        is_dir: bool,
    };

    pub const FileLister = *const fn (rel_dir: []const u8) ?std.ArrayList(FileInfo);

    rel_dir: ?[]const u8 = null,
    files: ?std.ArrayList(FileInfo) = null,
    file_lister: ?FileLister = null,
    last_match_count: usize = 0,

    pub fn clear(self: *DirectoryCompleter) void {
        if (self.rel_dir) |rd| {
            alloc.gpa.allocator().free(rd);
            self.rel_dir = null;
        }

        if (self.files) |*xs| {
            xs.deinit(alloc.gpa.allocator());
            self.files = null;
        }
    }

    pub fn regenerate(self: *DirectoryCompleter, rel_dir: []const u8) void {
        if (self.rel_dir) |rd| {
            if (std.mem.eql(u8, rel_dir, rd)) {
                // Nothing to do
                return;
            }

            // Start clearing data to prep for regenerate.
            alloc.gpa.allocator().free(rd);
            self.rel_dir = null;
        }

        if (self.files) |*xs| {
            xs.deinit(alloc.gpa.allocator());
            self.files = null;
        }

        self.rel_dir = alloc.copy_slice_to_gpa(rel_dir);

        if (self.file_lister) |lister| {
            self.files = lister(rel_dir);
            return;
        }

        //std.debug.print("Regenerating DirectoryCompleter at '{s}'...\n", .{rel_dir});

        // Bare drive letters like "C:" resolve to "current directory on C:",
        // not the root.  Append "\" so the OS opens the drive root instead.
        var open_path: []const u8 = rel_dir;
        if (rel_dir.len == 2 and rel_dir[1] == ':' and std.ascii.isAlphabetic(rel_dir[0])) {
            open_path = std.fmt.allocPrint(alloc.temp_alloc.allocator(), "{s}\\", .{rel_dir}) catch unreachable;
        }

        const cwd = std.Io.Dir.cwd();
        const dir = std.Io.Dir.openDir(cwd, alloc.g_io, open_path, .{ .iterate = true }) catch return;
        defer dir.close(alloc.g_io);

        self.files = alloc.new_arraylist(FileInfo);

        var iter = dir.iterate();
        while (iter.next(alloc.g_io) catch return) |file| {
            //std.debug.print("Found '{s}'\n", .{file.name});
            self.files.?.append(alloc.gpa.allocator(), .{
                .name = alloc.copy_slice_to_gpa(file.name),
                // TODO This overtriggers
                .is_dir = file.kind != std.Io.File.Kind.file,
            }) catch unreachable;
        }
    }

    pub fn get_completion(self: *DirectoryCompleter, prefix: []const u8, p_cycle: usize, flags: GetCompletionFlags) ?[]const u8 {
        var cycle = p_cycle;
        self.last_match_count = 0;

        // TODO drop all but final word
        var last_word = prefix;

        if (prefix.len > 0 and prefix[prefix.len - 1] == ' ') {
            // Ends with a space, want to match any files.
            last_word = "";
        } else {
            var words_iter = std.mem.tokenizeAny(u8, prefix, " ");
            while (words_iter.next()) |word| {
                last_word = word;
            }
        }

        var prefix_for_query = last_word;

        if (prefix_for_query.len == 0 and !flags.complete_to_files_from_empty_prefix) {
            return null;
        }

        const count = std.mem.count(u8, last_word, "/") + std.mem.count(u8, last_word, "\\");
        if (count == 0) {
            self.regenerate("");
        } else {
            const path_index = std.mem.lastIndexOfAny(u8, last_word, "/\\").?;
            const path = last_word[0..path_index];
            prefix_for_query = last_word[path_index + 1 ..];
            self.regenerate(path);
        }

        if (self.files) |xs| {
            for (xs.items) |x| {
                if (std.mem.startsWith(u8, x.name, prefix_for_query)) {
                    if (flags.complete_to_directories_not_files and !x.is_dir) {
                        continue;
                    }

                    self.last_match_count += 1;

                    if (cycle > 0) {
                        cycle -|= 1;
                        continue;
                    }

                    return alloc.copy_slice_to_gpa(x.name[prefix_for_query.len..]);
                }
            }
        }

        return null;
    }
};

pub const PathCompleter = struct {
    executables: ?std.ArrayList([]const u8) = null,
    exe_lister: ?ExeLister = null,

    pub const ExeLister = *const fn () ?std.ArrayList([]const u8);

    pub fn get_completion(self: *PathCompleter, prefix: []const u8, p_cycle: usize) ?[]const u8 {
        // Only complete the first word (no spaces in prefix).
        if (std.mem.indexOfScalar(u8, prefix, ' ') != null) return null;
        if (prefix.len == 0) return null;

        self.ensure_loaded();

        const exes = self.executables orelse return null;
        var cycle = p_cycle;

        for (exes.items) |name| {
            if (name.len > prefix.len and std.mem.startsWith(u8, name, prefix)) {
                if (cycle > 0) {
                    cycle -|= 1;
                    continue;
                }
                return alloc.copy_slice_to_gpa(name[prefix.len..]);
            }
        }

        return null;
    }

    fn ensure_loaded(self: *PathCompleter) void {
        if (self.executables != null) return;

        if (self.exe_lister) |lister| {
            self.executables = lister();
            return;
        }

        self.executables = scan_path_executables();
    }

    fn scan_path_executables() ?std.ArrayList([]const u8) {
        const path_var = windows.get_env_var("PATH") orelse return null;

        var result: std.ArrayList([]const u8) = .{};

        var dir_iter = std.mem.splitScalar(u8, path_var, ';');
        while (dir_iter.next()) |dir_path| {
            if (dir_path.len == 0) continue;

            const cwd = std.Io.Dir.cwd();
            const dir = std.Io.Dir.openDir(cwd, alloc.g_io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(alloc.g_io);

            var iter = dir.iterate();
            while (iter.next(alloc.g_io) catch null) |entry| {
                if (entry.kind != std.Io.File.Kind.file) continue;

                const name = entry.name;
                const ext = extension_of(name) orelse continue;
                if (!is_executable_ext(ext)) continue;

                // Strip extension
                const base = name[0 .. name.len - ext.len - 1];
                if (base.len == 0) continue;

                // Deduplicate: skip if already present
                var found = false;
                for (result.items) |existing| {
                    if (std.ascii.eqlIgnoreCase(existing, base)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    result.append(alloc.gpa.allocator(), alloc.copy_slice_to_gpa(base)) catch continue;
                }
            }
        }

        std.mem.sortUnstable([]const u8, result.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.ascii.orderIgnoreCase(a, b) == .lt;
            }
        }.lessThan);

        return result;
    }

    fn extension_of(name: []const u8) ?[]const u8 {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
        if (dot == name.len - 1) return null;
        return name[dot + 1 ..];
    }

    fn is_executable_ext(ext: []const u8) bool {
        return std.ascii.eqlIgnoreCase(ext, "exe") or
            std.ascii.eqlIgnoreCase(ext, "cmd") or
            std.ascii.eqlIgnoreCase(ext, "bat");
    }

    pub fn clear(self: *PathCompleter) void {
        if (self.executables) |*exes| {
            for (exes.items) |name| {
                alloc.gpa.allocator().free(name);
            }
            exes.deinit(alloc.gpa.allocator());
            self.executables = null;
        }
    }
};

pub const LocalHistoryCompleter = struct {
    cwd_path: ?[]const u8 = null,
    completer: HistoryCompleter,

    pub fn add_prefix(self: *LocalHistoryCompleter, s: []const u8) []const u8 {
        if (self.cwd_path == null) {
            const realpath = std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), alloc.g_io, ".", alloc.gpa.allocator()) catch unreachable;
            defer alloc.gpa.allocator().free(realpath);
            self.cwd_path = alloc.gpa.allocator().dupe(u8, realpath) catch unreachable;
        }

        return std.mem.concat(alloc.temp_alloc.allocator(), u8, &.{ self.cwd_path.?, "|", s }) catch unreachable;
    }

    pub fn insert(self: *LocalHistoryCompleter, cmd: []const u8) void {
        self.completer.insert(self.add_prefix(cmd));
    }

    pub fn get_completion(self: *LocalHistoryCompleter, prefix: []const u8, flags: GetCompletionFlags) ?[]const u8 {
        return self.completer.get_completion(self.add_prefix(prefix), flags);
    }

    pub fn iter(self: *LocalHistoryCompleter, prefix: []const u8) HistoryIterator {
        return self.completer.iter(self.add_prefix(prefix));
    }
};

pub const GlobalHistoryCompleter = struct {
    completer: HistoryCompleter,

    pub fn insert(self: *GlobalHistoryCompleter, cmd: []const u8) void {
        const with_prefix = std.mem.concat(alloc.temp_alloc.allocator(), u8, &.{ @as([]const u8, "GLOBAL_"), cmd }) catch unreachable;
        self.completer.insert(with_prefix);
    }

    pub fn get_completion(self: *GlobalHistoryCompleter, prefix: []const u8, flags: GetCompletionFlags) ?[]const u8 {
        const with_prefix = std.mem.concat(alloc.temp_alloc.allocator(), u8, &.{ @as([]const u8, "GLOBAL_"), prefix }) catch unreachable;
        return self.completer.get_completion(with_prefix, flags);
    }

    pub fn iter(self: *GlobalHistoryCompleter, prefix: []const u8) HistoryIterator {
        const with_prefix = std.mem.concat(alloc.temp_alloc.allocator(), u8, &.{ @as([]const u8, "GLOBAL_"), prefix }) catch unreachable;
        return self.completer.iter(with_prefix);
    }
};

pub const HistoryIterator = struct {
    subtree_iter: ?lego_trie.SubtreeIterator,
    prefix_extension: []const u8,
    leaf_only: bool,
    leaf_returned: bool = false,
    no_match: bool = false,

    pub fn next(self: *HistoryIterator) ?[]const u8 {
        if (self.no_match) return null;

        if (self.leaf_only) {
            if (self.leaf_returned) return null;
            self.leaf_returned = true;
            if (self.prefix_extension.len == 0) return null;
            return alloc.copy_slice_to_gpa(self.prefix_extension);
        }

        if (self.subtree_iter) |*iter| {
            if (iter.next(alloc.temp_alloc.allocator())) |subtree_result| {
                if (self.prefix_extension.len == 0) {
                    return alloc.copy_slice_to_gpa(subtree_result);
                }
                return std.mem.concat(alloc.gpa.allocator(), u8, &.{ self.prefix_extension, subtree_result }) catch null;
            }
        }

        return null;
    }
};

pub const HistoryCompleter = struct {
    trie: lego_trie.Trie,

    pub fn init(trie_blocks: *data.MappedArray(lego_trie.TrieBlock)) HistoryCompleter {
        return .{ .trie = lego_trie.Trie.init(trie_blocks) };
    }

    pub fn insert(self: *HistoryCompleter, cmd: []const u8) void {
        var view = self.trie.to_view();
        view.insert(cmd) catch unreachable;
    }

    pub fn iter(self: *HistoryCompleter, prefix: []const u8) HistoryIterator {
        const view = self.trie.to_view();
        var walker = lego_trie.TrieWalker.init(view, prefix);
        if (!walker.walk_to()) {
            return .{ .subtree_iter = null, .prefix_extension = "", .leaf_only = false, .no_match = true };
        }

        // Copy extension to temp_alloc since walker is stack-local
        const ext = alloc.temp_alloc.allocator().dupe(u8, walker.extension.slice()) catch unreachable;

        if (walker.reached_leaf) {
            return .{
                .subtree_iter = null,
                .prefix_extension = ext,
                .leaf_only = true,
            };
        }
        return .{
            .subtree_iter = lego_trie.SubtreeIterator{
                .trie = &self.trie,
                .root_block = @intCast(walker.trie_view.current_block),
            },
            .prefix_extension = ext,
            .leaf_only = false,
        };
    }

    pub fn get_completion(self: *HistoryCompleter, prefix: []const u8, flags: GetCompletionFlags) ?[]const u8 {
        const view = self.trie.to_view();
        var walker = lego_trie.TrieWalker.init(view, prefix);
        if (walker.walk_to()) {
            // All of this should be cleaned up, walker so ugly atm.
            const extension = walker.extension.slice();
            var end_extension: []const u8 = "";

            const add_heuristic_walk = !walker.reached_leaf;

            if (add_heuristic_walk) {
                end_extension = walker.walk_to_heuristic(alloc.temp_alloc.allocator(), walker.cost);
            }

            // If we are completing to files we want to discard history completions
            // that do not match anything.
            // ie we want to return null here on empty extensions.
            if (flags.complete_to_files_from_empty_prefix and
                extension.len == 0 and end_extension.len == 0)
            {
                return null;
            }

            return std.mem.concat(alloc.gpa.allocator(), u8, &.{ extension, end_extension }) catch unreachable;
        }

        return null;
    }
};

fn is_completion_a_directory(prefix: []const u8, completion: []const u8) bool {
    const full = std.mem.concat(alloc.temp_alloc.allocator(), u8, &.{ prefix, completion }) catch return false;

    // Extract the last word (the path argument).
    var last_word: []const u8 = full;
    var words_iter = std.mem.tokenizeAny(u8, full, " ");
    while (words_iter.next()) |word| {
        last_word = word;
    }

    const cwd = std.Io.Dir.cwd();
    const dir = std.Io.Dir.openDir(cwd, alloc.g_io, last_word, .{}) catch return false;
    dir.close(alloc.g_io);
    return true;
}

fn has_unclosed_quotes(xs: []const u8) bool {
    var double_count: u32 = 0;
    var single_count: u32 = 0;
    var backtick_count: u32 = 0;
    for (xs) |x| {
        if (x == '"') {
            double_count += 1;
        }
        // TODO writing "don't" or similar triggers unclosed quotes, probably want to check for whitespace on the prev char
        if (x == '\'') {
            single_count += 1;
        }
        if (x == '`') {
            backtick_count += 1;
        }
    }

    return double_count % 2 != 0 or single_count % 2 != 0 or backtick_count % 2 != 0;
}

fn is_global_command_heuristic(command: []const u8) bool {
    var words_iter = std.mem.tokenizeAny(u8, command, " ");

    while (words_iter.next()) |word| {
        if (std.mem.eql(u8, word, ".") or std.mem.eql(u8, word, "..")) {
            // Special cases, technically refer to current directoy, but also applicable anywhere.
            continue;
        }

        if (windows.word_is_local_path(word)) {
            return false;
        }
    }

    return true;
}

// --- Tests ---

fn create_test_trie(backing: []lego_trie.TrieBlock, len: *std.atomic.Value(usize), context: *data.MMapContext) lego_trie.Trie {
    var blocks = data.MappedArray(lego_trie.TrieBlock){
        .len = len,
        .map = backing,
        .mmap_context = context,
    };
    return lego_trie.Trie.init(&blocks);
}

test "HistoryIterator - leaf returns extension once" {
    var backing: [64]lego_trie.TrieBlock = undefined;
    var len = std.atomic.Value(usize).init(0);
    var test_context = data.MMapContext{};
    var blocks = data.MappedArray(lego_trie.TrieBlock){
        .len = &len,
        .map = &backing,
        .mmap_context = &test_context,
    };

    const trie = lego_trie.Trie.init(&blocks);
    var completer = HistoryCompleter{ .trie = trie };

    completer.insert("cd Documents");

    // Query for "cd Doc" - should match and return leaf extension "uments"
    var iter = completer.iter("cd Doc");
    const result = iter.next();
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("uments", result.?);

    // Should return null on second call
    try std.testing.expect(iter.next() == null);
}

test "HistoryIterator - iterates multiple branches" {
    var backing: [128]lego_trie.TrieBlock = undefined;
    var len = std.atomic.Value(usize).init(0);
    var test_context = data.MMapContext{};
    var blocks = data.MappedArray(lego_trie.TrieBlock){
        .len = &len,
        .map = &backing,
        .mmap_context = &test_context,
    };

    const trie = lego_trie.Trie.init(&blocks);
    var completer = HistoryCompleter{ .trie = trie };

    completer.insert("cd Documents");
    completer.insert("cd Downloads");

    // Query "cd Do" - should get both completions
    var iter = completer.iter("cd Do");
    const r1 = iter.next();
    try std.testing.expect(r1 != null);
    const r2 = iter.next();
    try std.testing.expect(r2 != null);
    try std.testing.expect(iter.next() == null);

    const has_cuments = std.mem.eql(u8, r1.?, "cuments") or std.mem.eql(u8, r2.?, "cuments");
    const has_wnloads = std.mem.eql(u8, r1.?, "wnloads") or std.mem.eql(u8, r2.?, "wnloads");
    try std.testing.expect(has_cuments);
    try std.testing.expect(has_wnloads);
}

test "HistoryIterator - no match returns null" {
    var backing: [64]lego_trie.TrieBlock = undefined;
    var len = std.atomic.Value(usize).init(0);
    var test_context = data.MMapContext{};
    var blocks = data.MappedArray(lego_trie.TrieBlock){
        .len = &len,
        .map = &backing,
        .mmap_context = &test_context,
    };

    const trie = lego_trie.Trie.init(&blocks);
    var completer = HistoryCompleter{ .trie = trie };

    completer.insert("git status");

    // No match for this prefix
    var iter = completer.iter("cd ");
    try std.testing.expect(iter.next() == null);
}

// Mock dir validator for testing: checks against a hardcoded set of valid dirs
const TestValidDirs = struct {
    var valid: [8][]const u8 = undefined;
    var count: usize = 0;

    fn reset() void {
        count = 0;
    }

    fn add(dir: []const u8) void {
        valid[count] = dir;
        count += 1;
    }

    fn validator(prefix: []const u8, completion: []const u8) bool {
        const full = std.mem.concat(alloc.temp_alloc.allocator(), u8, &.{ prefix, completion }) catch return false;
        var last_word: []const u8 = full;
        var words_iter = std.mem.tokenizeAny(u8, full, " ");
        while (words_iter.next()) |word| {
            last_word = word;
        }
        for (valid[0..count]) |d| {
            if (std.mem.eql(u8, last_word, d)) return true;
        }
        return false;
    }
};

test "CompletionHandler - cd mode skips invalid dirs" {
    alloc.g_io = std.testing.io;

    var backing: [256]lego_trie.TrieBlock = undefined;
    var len = std.atomic.Value(usize).init(0);
    var test_context = data.MMapContext{};
    var blocks = data.MappedArray(lego_trie.TrieBlock){
        .len = &len,
        .map = &backing,
        .mmap_context = &test_context,
    };

    const trie = lego_trie.Trie.init(&blocks);
    const base = HistoryCompleter{ .trie = trie };
    var handler = CompletionHandler{
        .global_history = .{ .completer = base },
        .local_history = .{ .completer = base },
        .directory_completer = .{},
        .dir_validator = &TestValidDirs.validator,
    };

    // Set a deterministic cwd path for local history
    handler.local_history.cwd_path = "TEST_CWD";

    // Pre-populate directory completer to prevent real I/O
    handler.directory_completer.rel_dir = alloc.copy_slice_to_gpa("");
    handler.directory_completer.files = alloc.new_arraylist(DirectoryCompleter.FileInfo);

    // Insert history entries
    handler.local_history.insert("cd deploy.sh");
    handler.local_history.insert("cd Documents");

    // Set up mock: only "Documents" is a valid directory
    TestValidDirs.reset();
    TestValidDirs.add("Documents");

    // Should skip "deploy.sh" and return the completion for "Documents"
    handler.cycle_index = 0;
    const result = handler.get_completion("cd D", .{ .complete_to_directories_not_files = true });
    try std.testing.expect(result != null);

    // The completion should end with "ocuments" (extending "cd D" -> "cd Documents")
    const full = std.mem.concat(alloc.temp_alloc.allocator(), u8, &.{ "cd D", result.? }) catch unreachable;
    var last_word: []const u8 = full;
    var words_iter = std.mem.tokenizeAny(u8, full, " ");
    while (words_iter.next()) |word| {
        last_word = word;
    }
    try std.testing.expectEqualStrings("Documents", last_word);
}

test "CompletionHandler - cd mode cycles through valid dirs" {
    alloc.g_io = std.testing.io;

    var backing: [256]lego_trie.TrieBlock = undefined;
    var len = std.atomic.Value(usize).init(0);
    var test_context = data.MMapContext{};
    var blocks = data.MappedArray(lego_trie.TrieBlock){
        .len = &len,
        .map = &backing,
        .mmap_context = &test_context,
    };

    const trie = lego_trie.Trie.init(&blocks);
    const base = HistoryCompleter{ .trie = trie };
    var handler = CompletionHandler{
        .global_history = .{ .completer = base },
        .local_history = .{ .completer = base },
        .directory_completer = .{},
        .dir_validator = &TestValidDirs.validator,
    };

    handler.local_history.cwd_path = "TEST_CWD";
    handler.directory_completer.rel_dir = alloc.copy_slice_to_gpa("");
    handler.directory_completer.files = alloc.new_arraylist(DirectoryCompleter.FileInfo);

    handler.local_history.insert("cd Documents");
    handler.local_history.insert("cd Downloads");

    // Both are valid directories
    TestValidDirs.reset();
    TestValidDirs.add("Documents");
    TestValidDirs.add("Downloads");

    // cycle 0 and cycle 1 should give different results
    handler.cycle_index = 0;
    const r0 = handler.get_completion("cd D", .{ .complete_to_directories_not_files = true });
    try std.testing.expect(r0 != null);

    handler.cycle_index = 1;
    const r1 = handler.get_completion("cd D", .{ .complete_to_directories_not_files = true });
    try std.testing.expect(r1 != null);

    // Both should produce valid completions and they should be different
    try std.testing.expect(!std.mem.eql(u8, r0.?, r1.?));

    // cycle 2 should fall through to directory completer (empty) -> null
    handler.cycle_index = 2;
    const r2 = handler.get_completion("cd D", .{ .complete_to_directories_not_files = true });
    try std.testing.expect(r2 == null);
}

test "CompletionHandler - non-cd mode unchanged" {
    alloc.g_io = std.testing.io;

    var backing: [256]lego_trie.TrieBlock = undefined;
    var len = std.atomic.Value(usize).init(0);
    var test_context = data.MMapContext{};
    var blocks = data.MappedArray(lego_trie.TrieBlock){
        .len = &len,
        .map = &backing,
        .mmap_context = &test_context,
    };

    const trie = lego_trie.Trie.init(&blocks);
    const base = HistoryCompleter{ .trie = trie };
    var handler = CompletionHandler{
        .global_history = .{ .completer = base },
        .local_history = .{ .completer = base },
        .directory_completer = .{},
    };

    handler.local_history.cwd_path = "TEST_CWD";
    handler.directory_completer.rel_dir = alloc.copy_slice_to_gpa("");
    handler.directory_completer.files = alloc.new_arraylist(DirectoryCompleter.FileInfo);

    handler.local_history.insert("git status");

    handler.cycle_index = 0;
    const result = handler.get_completion("git s", .{});
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("tatus", result.?);
}
