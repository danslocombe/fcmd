# Test Suite Plan for Memory-Mapped Trie Corruption Detection

## Current Status: Phase 3 Complete ✅

**Latest Results:** 36/36 tests passing (November 22, 2025)
- Phase 0: Basic Infrastructure ✅ (11 tests)
- Phase 1: Single-Process Stress ✅ (6 tests)
- Phase 2: Data Integrity ✅ (7 tests)
- Phase 3: Edge Cases & Boundaries ✅ (7 tests)
- Legacy tests: 5 tests

**Next:** Continue with additional validation and stress test combinations, then move toward multi-process testing.

## Overview
The trie uses a complex memory-mapped file system with:
- Cross-process synchronization (semaphores, events)
- Dynamic resizing with process coordination
- Mixed tall/wide node structures
- Volatile memory access patterns
- Background thread for unload/reload

## Implementation Phases

### **Phase 0: Basic Test Infrastructure ✅ COMPLETE**
Successfully implemented basic testing infrastructure:

**Completed:**
- ✅ Created `src/test_exports.zig` with Phase 0 test suite (11 tests, all passing)
- ✅ Implemented validation helpers in `TestHelpers`:
  - `validate_trie_structure()` - walks entire trie, checks pointers, verifies no cycles
  - `validate_can_find()` - verifies inserted strings are findable
  - `validate_all_can_find()` - bulk verification helper
  - `count_total_nodes()` - counts all blocks for sanity checks
  - `create_test_trie()` - helper to set up test trie with backing buffer
- ✅ Passing tests (10 corruption tests + 1 stress test):
  1. Basic insertion - insert 10 strings and verify all findable
  2. Duplicate insertion - verify cost updates correctly
  3. Tall to wide promotion - insert 3 strings forcing promotion
  4. Node spillover - insert enough strings to cause sibling allocation
  5. Long string insertion - strings longer than TallStringLen (22)
  6. Common prefix handling - deep tree structure verification
  7. Prefix search - partial matches return extensions
  8. Empty trie operations - search in empty trie
  9. Single character strings - edge case handling
  10. Stress test - insert 100 varied strings (uses 131 blocks)

**Technical Notes:**
- Tests use fixed backing arrays (512-2048 blocks) to avoid memory-mapped resize complexity
- Added guard in `DumbList.append()` to detect test mode and panic with helpful message if array too small
- Fixed critical bug: `DumbList` pointer was going out of scope (now passed from test caller)
- All tests run without initializing global `BackingData` - pure in-memory testing

**Build Status:**
- Full test suite: 15/17 tests passing
- 2 legacy test failures (brittle block ID assertions, not corruption-related)
- All Phase 0 corruption tests: 10/10 passing ✅

**Ready for:** Phase 1 - Single-process stress tests

---

### **Phase 1: Single-Process Stress Tests ✅ COMPLETE**

**Goal:** Test trie under heavy load with various insertion patterns to detect corruption in single-process scenarios.

**Completed Tests:**
1. ✅ Stress test (100 strings) - Basic stress from Phase 0 - **131 blocks**
2. ✅ Heavy insertion - Insert 1,000 commands rapidly - **1,301 blocks**
3. ✅ Very long strings - Insert 30 commands with 100+ character paths - **53 blocks**
4. ✅ Alternating tall/wide - 60 strings forcing tall→wide promotions - **80 blocks**
5. ✅ Deep trie - 81 strings with long common prefixes creating deep tree - **168 blocks**
6. ✅ Wide trie - 310 strings with diverse first characters creating wide fan-out - **450 blocks**

**Results:**
- All 6 stress tests passing ✅
- Successfully validated structure integrity after heavy loads
- All inserted strings verified findable via `validate_all_can_find()`
- No crashes or corruption detected under single-process stress
- Block allocation scales appropriately with insertion patterns

**Technical Notes:**
- Tests use fixed backing arrays (1024-2048 blocks) to handle stress loads
- Patterns tested: rapid insertion, long strings, tall/wide promotion, deep/wide trees
- All tests run without global `BackingData` initialization - pure in-memory

**Deferred:**
- Resize triggers (requires memory-mapped file setup) - moved to future phase

**Build Status:**
- Full test suite: 22/22 tests passing ✅
- All Phase 0 + Phase 1 tests passing

**Ready for:** Phase 2 - Data integrity validation

---

### **Phase 2: Data Integrity Tests ✅ COMPLETE**

**Goal:** Validate that data is stored and retrieved correctly, with comprehensive round-trip verification and consistency checks.

**Completed Tests:**
1. ✅ Round-trip verification - Insert 8 diverse strings, verify exact retrieval
2. ✅ Walker consistency - 100 walks produce deterministic results
3. ✅ Cost consistency - Costs strictly decrease on 10 duplicate insertions
4. ✅ Sibling chain validation - No cycles or dangling pointers detected
5. ✅ Prefix extension accuracy - Extensions match expected suffixes exactly
6. ✅ Duplicate handling - 50 duplicates don't bloat structure (≤10 extra blocks)
7. ✅ Mixed operation consistency - 50 interleaved insert/search operations maintain integrity

**Results:**
- All 7 data integrity tests passing ✅
- Round-trip verified with diverse strings (symbols, spaces, numbers, varying lengths)
- Walker determinism confirmed over 100 iterations
- Cost ordering maintained under duplicate insertions
- Sibling chains validated without cycles or invalid pointers
- Prefix extensions computed accurately
- Structure remains efficient under duplicates
- Mixed operations maintain searchability of all previous insertions

**Technical Notes:**
- Tests verify both exact matches (no extension) and partial matches (with extensions)
- Duplicate insertions verified to not significantly grow block count
- All tests validate structure integrity via `validate_trie_structure()`
- Sibling chain traversal uses visited set to detect cycles

**Build Status:**
- Full test suite: 29/29 tests passing ✅
- All Phase 0 + Phase 1 + Phase 2 tests passing

**Ready for:** Phase 3 - Edge cases and boundary conditions

---

### **Phase 3: Edge Cases & Boundary Conditions ✅ COMPLETE**

**Goal:** Test boundary conditions, special characters, and edge cases that might reveal off-by-one errors or special handling issues.

**Completed Tests:**
1. ✅ Empty string operations - Empty string insertion documented (returns false on search)
2. ✅ Maximum string length - TallStringLen boundary (21, 22, 23 chars) all work correctly
3. ✅ Node capacity boundaries - WideNodeLen (4→5) triggers spillover correctly
4. ✅ Special characters - Unicode (café, 🎉), spaces, quotes, tabs, symbols all handled
5. ✅ Identical prefix stress - 50 strings with 37-char common prefix handled correctly
6. ✅ Single character differences - 9 strings differing by 1 char at various positions
7. ✅ Case sensitivity - Trie is case-sensitive (lowercase ≠ UPPERCASE)

**Results:**
- All 7 edge case tests passing ✅
- Empty string behavior documented (not found after insertion)
- Boundary conditions at TallStringLen (22) handled correctly
- Node capacity overflow (WideNodeLen=4) triggers proper sibling allocation
- Special characters including unicode and emojis stored/retrieved correctly
- Long common prefixes create deep structures without corruption
- Case sensitivity confirmed (different cases treated as different strings)

**Technical Notes:**
- TallStringLen = 22, strings at 21/22/23 chars all work
- WideNodeLen = 4, tested exact capacity (4) and overflow (5)
- Special chars tested: spaces, unicode (café), emoji (🎉), symbols, tabs
- Identical prefix test uses 37-char common prefix with 50 variations
- Case test verifies 'lowercase' ≠ 'UPPERCASE'

**Build Status:**
- Full test suite: 36/36 tests passing ✅
- All Phase 0-3 tests passing

**Ready for:** Phase 4 - Additional validation helpers and stress combinations

---

## Proposed Test Categories (Future Phases)

### **1. Single-Process Stress Tests ✅ COMPLETE**
See Phase 1 above for detailed status.

### **2. Multi-Process Concurrency Tests**
- **Simultaneous readers:** Multiple processes reading while one writes
- **Resize during read:** One process triggers resize while others are walking the trie
- **Race on semaphore:** Multiple processes trying to insert simultaneously
- **Background unloader stress:** Rapid acquire/release cycles
- **Zombie process simulation:** Kill a process while it holds the semaphore

### **3. Data Integrity Tests**
- **Round-trip verification:** Insert known data, read back, verify exact match
- **Walker consistency:** Ensure walk_to() produces deterministic results
- **Cost consistency:** Verify costs update correctly after insertions
- **Sibling chain validation:** Walk all siblings, ensure no cycles or null pointers
- **Alignment checks:** Verify TrieBlock boundaries align correctly after resize

### **4. Edge Cases & Boundary Conditions**
- **Empty trie operations:** Search empty trie, insert into empty
- **Single character strings:** "a", "b", "c"...
- **Duplicate insertions:** Same string inserted 1000 times
- **Special characters:** Strings with unicode, spaces, quotes
- **Maximum string length:** TallStringLen (22) boundary cases
- **Node overflow:** Exactly WideNodeLen (4) and TallNodeLen (1) insertions

### **5. File System & Mapping Tests**
- **Cold start:** Load from existing file, verify all data intact
- **Corruption detection:** Manually corrupt magic number/version, ensure graceful handling
- **Partial writes:** Simulate crashes during resize
- **File size validation:** Ensure size_in_bytes_ptr matches actual mapping
- **Memory mapping alignment:** Verify all structures properly aligned

### **6. Sorting & Ordering Tests**
- **Cost-based ordering:** Verify bubble sort maintains cost order
- **Recent preference:** Ensure >= comparison prefers recent insertions
- **Spillover sorting:** Verify sorting across sibling blocks
- **Iterator validation:** Walk all children, verify order matches costs

### **7. Memory Safety Tests**
- **Bounds checking:** Verify no out-of-bounds access in get_child_size()
- **Null pointer checks:** Ensure metadata.next==0 handled correctly
- **Volatile access patterns:** Verify volatile reads don't get optimized incorrectly
- **Use-after-unmap:** Ensure no access after background unload

### **8. Determinism & Reproducibility**
- **Seed-based fuzzing:** Use fixed seeds to reproduce insertion sequences
- **Operation logging:** Record all operations for replay on failure
- **Snapshot comparison:** Save trie state, reload, compare
- **Hash verification:** Compute hash of trie structure, verify after operations

---

## Test Infrastructure Recommendations

### 1. Test Harness Features
- Configurable backing buffer sizes for fast iteration
- Mock file system for fault injection
- Operation recording/replay capability
- Trie validation function (walks entire structure, checks invariants)
- Hash/checksum computation for state comparison

### 2. Validation Functions
- `validate_trie_structure()` - checks all pointers, no cycles, valid indices
- `validate_sorting()` - ensures costs are properly ordered
- `validate_data_integrity()` - round-trip all inserted data
- `check_alignment()` - verifies memory alignment
- `validate_no_duplicates_in_block()` - ensures no duplicate strings in same block
- `validate_sibling_chain()` - walk siblings, check for cycles

### 3. Fuzzing Strategy
- Random operation sequences (insert, walk, resize)
- Random string generation with weighted distributions
- Controlled chaos: kill processes at random points
- Property-based testing: invariants that should always hold

### 4. Performance Baselines
- Track insertion time to detect degradation
- Monitor resize frequency
- Measure walk_to() latency distributions
- Memory usage patterns

---

## Key Invariants to Check

These should hold true after any sequence of operations:

1. **Structural Integrity:**
   - All costs are sorted (descending) within each block and across siblings
   - No dangling pointers (metadata.next either 0 or valid index < blocks.len)
   - No cycles in sibling chains
   - All referenced blocks exist in valid range

2. **Data Consistency:**
   - All string lengths match actual content
   - is_leaf and node data are mutually exclusive states
   - exists flag accurately represents slot usage
   - Size calculations match actual memory layout

3. **Functional Correctness:**
   - After any operation sequence, all inserted strings should be findable
   - Walk operations are deterministic (same input → same output)
   - Cost updates happen correctly on duplicate insertions
   - Extension strings match remaining suffix after walk

4. **Memory Safety:**
   - No out-of-bounds array access
   - Proper alignment of all structures
   - Volatile pointer access doesn't cause UB
   - No use-after-free scenarios

---

## Common Corruption Patterns to Watch For

Based on the memory-mapped multi-process design:

1. **Race Conditions:**
   - Multiple processes modifying during resize
   - Background unloader interrupting operation
   - Semaphore count mismatches

2. **Pointer Corruption:**
   - Stale pointers after resize
   - Invalid next indices
   - Sibling chain cycles

3. **Data Corruption:**
   - Partial writes during crashes
   - Cost values getting out of sync
   - String data getting truncated or overwritten

4. **Alignment Issues:**
   - Misaligned TrieBlock after resize
   - Packed struct padding problems
   - Volatile cast alignment problems

---

## Next Steps

1. ✅ **Phase 0:** Implement basic test infrastructure (5-10 simple tests)
2. **Phase 1:** Single-process stress tests (heavy insertion, deep/wide tries)
3. **Phase 2:** Data integrity validation (round-trip, consistency checks)
4. **Phase 3:** Edge cases and boundary conditions
5. **Phase 4:** Multi-process concurrency (most complex, likely source of corruption)
6. **Phase 5:** File system integration tests
7. **Phase 6:** Fuzzing and chaos engineering

Each phase builds on the previous, with validation functions getting more sophisticated over time.
