// Module to export dependencies for testing
// This file only exports common dependencies used across test files.
// Actual tests have been moved to:
// - test_basic.zig: Basic trie functionality tests
// - test_phase1.zig: Single-process stress tests
// - test_phase2.zig: Data integrity tests
// - test_phase3.zig: Edge cases and boundary conditions
// - test_phase4.zig: Multi-process concurrency tests (Phase 4 & 4.5)
// - test_phase5.zig: Additional multi-process scenarios
// - test_phase6.zig: File system integration tests
// - test_phase7.zig: Fuzzing and chaos engineering tests
// - test_helpers.zig: Shared helper functions for all tests

pub const lego_trie = @import("datastructures/lego_trie.zig");
pub const data = @import("data.zig");
pub const alloc = @import("alloc.zig");
pub const log = @import("log.zig");
pub const windows = @import("windows.zig");
