// Module to export dependencies for testing
// This file only exports common dependencies used across test files.
// Actual tests are in:
// - test_basic.zig: Core trie functionality tests
// - test_trie_extended.zig: Stress, integrity, and edge case tests
// - test_multiprocess_scenarios.zig: Cross-process insert/search/verify tests
// - test_helpers.zig: Shared helper functions for all tests
// - test_multiprocess.zig: ProcessController for spawning subprocesses

pub const lego_trie = @import("datastructures/lego_trie.zig");
pub const data = @import("data.zig");
pub const alloc = @import("alloc.zig");
pub const log = @import("log.zig");
pub const windows = @import("windows.zig");
pub const completion = @import("completion.zig");
pub const run = @import("run.zig");
