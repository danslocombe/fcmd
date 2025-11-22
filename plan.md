# Test Suite Plan for Memory-Mapped Trie Corruption Detection

## Current Status: Phase 5 Complete ✅ (November 22, 2025)

**Latest Results:** 44/44 tests passing
- Phase 0: Basic Infrastructure ✅ (11 tests)
- Phase 1: Single-Process Stress ✅ (6 tests)
- Phase 2: Data Integrity ✅ (7 tests)
- Phase 3: Edge Cases & Boundaries ✅ (7 tests)
- Phase 4: Multi-Process Infrastructure ✅ (3 tests)
- Phase 4.5: Multi-Process Concurrency ✅ (3 tests)
- **Phase 5: Advanced Multi-Process Scenarios ✅ (3 tests)**
- Legacy tests: 5 tests

**Phase 4 Progress:**
- ✅ Test state file creation and serialization
- ✅ CLI test mode (--test-mp insert/search/verify)
- ✅ Basic infrastructure tests
- ✅ Process spawning and coordination
- ✅ Multi-process concurrency tests (Phase 4.5)

**Phase 4.5 Complete:** Three actual multi-process tests implemented and passing:
1. ✅ Simultaneous readers (5 processes searching 100 strings)
2. ✅ Concurrent readers + writer (4 readers + 10 inserts)
3. ✅ Multiple writers (3 writers × 20 inserts = 60 concurrent writes)

**Phase 5 Complete:** Three advanced multi-process scenarios:
1. ✅ Rapid insert stress (5 processes × 50 inserts = 250 concurrent operations)
2. ✅ Search during concurrent inserts (3 readers + 60 writer operations)
3. ✅ Shared prefix stress (60 concurrent inserts with common prefix testing tall→wide promotions)

**Next:** Consider file system integration tests (cold start, corruption detection, etc.).

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

### **Phase 4: Multi-Process Concurrency Tests 🚧 IN PROGRESS**

**Goal:** Test the trie under multi-process access patterns to detect race conditions, synchronization bugs, and corruption from concurrent operations.

**Architecture Overview:**
The trie uses cross-process synchronization via:
- Named semaphore (`Local\\fcmd_data_semaphore`) - coordinates exclusive file access
- Named events (`fcmd_unload_data`, `fcmd_reload_data`) - signals background unload/reload
- Memory-mapped file (`trie.frog`) - shared state across processes
- Background thread per process - handles dynamic unload/reload on resize

**Test Framework Design:**

1. **Test State Files:**
   - Serialize trie state to a standalone `.frog` file
   - Each test creates a clean state file with known data
   - Processes load from this file instead of global state
   - Format: same as runtime (magic number, version, size, trie blocks)

2. **Process Controller:**
   - Spawn multiple fcmd.exe processes with special test mode
   - Each process runs a specific operation sequence
   - Operations: INSERT, SEARCH, WALK, RESIZE_TRIGGER
   - Synchronization barriers between phases
   - Collect results from each process (success/failure, data found, errors)

3. **Test Operations:**
   - `test_insert <state_file> <string>` - Insert and verify
   - `test_search <state_file> <string>` - Search and report result
   - `test_walk <state_file> <prefix>` - Walk and collect extensions
   - `test_stress <state_file> <count>` - Rapid insertions
   - `test_verify <state_file> <expected_strings_file>` - Bulk verification

4. **Validation Strategy:**
   - Before: Create known-good state file
   - During: Parallel process operations with timing control
   - After: All processes verify complete data set is intact
   - Check: No corruption (structure valid, all strings findable)

**Detailed Test Plan:**

**Test 1: Simultaneous Readers**
- Setup: State file with 100 pre-inserted strings
- Spawn: 5 reader processes searching for different strings
- Expected: All searches succeed, no corruption

**Test 2: Concurrent Readers + 1 Writer**
- Setup: State file with 50 strings
- Spawn: 4 readers continuously searching, 1 writer inserting new strings
- Expected: Readers find their strings, writer succeeds, final state contains all

**Test 3: Multiple Writers (Semaphore Stress)**
- Setup: Empty state file
- Spawn: 3 writers each inserting 20 unique strings
- Expected: All 60 strings present in final state, no duplicates lost

**Test 4: Resize During Read**
- Setup: State file near capacity (large backing array mostly full)
- Spawn: 2 readers actively walking, 1 writer triggering resize by filling remaining space
- Expected: Background unloader handles resize, readers recover, all data intact

**Test 5: Background Unloader Rapid Cycling**
- Setup: State file with 50 strings
- Spawn: 10 processes rapidly inserting (forcing multiple resizes)
- Expected: All processes handle unload/reload events correctly, no data loss

**Test 6: Zombie Process Simulation**
- Setup: State file with known data
- Spawn: Process that acquires semaphore, then forcibly killed
- Recovery: Timeout mechanism or manual semaphore reset
- Expected: Other processes can eventually continue (may require retry logic)

**Test 7: Race on Sibling Allocation**
- Setup: State file with root node at capacity (4 wide nodes)
- Spawn: 2 writers simultaneously inserting strings that require sibling allocation
- Expected: Proper synchronization prevents double allocation

**Implementation Steps:**

1. ✅ **Update plan.md** - Document Phase 4 architecture (this section)

2. ✅ **Create Test Harness Module** (`src/test_multiprocess.zig`):
   - ✅ State file creation/loading utilities (TestStateFile)
   - ✅ Test operation execution functions
   - ✅ Validation helpers for multi-process context (verifyStringsInStateFile)
   - ✅ ProcessController structure (spawn/waitAll/allSucceeded)

3. ✅ **Add CLI Test Mode** (extend `src/main.zig`):
   - ✅ `fcmd --test-mp <operation> <state_file> [args...]`
   - ✅ Operations: insert, search, verify
   - ✅ Exit with status code (0 = success, 1 = failure)

4. ✅ **Build Initial Infrastructure Tests** (in `src/test_exports.zig`):
   - ✅ Test state file creation and population
   - ✅ Verify state file reading
   - ✅ CLI test mode infrastructure validation

5. 🚧 **Implement Process Spawning** (next step):
   - Use ProcessController to spawn multiple fcmd.exe instances
   - Coordinate timing with barriers/delays
   - Collect and verify exit codes
   - Test concurrent readers scenario

6. ⏳ **Implement Full Test Cases** (pending):
   - Simultaneous readers test
   - Concurrent readers + writer test
   - Multiple writers (semaphore stress) test
   - Resize during read test
   - Background unloader rapid cycling test

**Current Status:** Infrastructure complete, ready for process spawning implementation.

---

### **Phase 4.5: Actual Multi-Process Tests ✅ COMPLETE**

**Goal:** Implement the actual multi-process concurrency tests using the infrastructure built in Phase 4.

**Prerequisites:**
- ✅ Test state file serialization (Phase 4)
- ✅ CLI test mode with --test-mp (Phase 4)
- ✅ Process controller structure (Phase 4)
- ✅ Process spawning implementation

**Completed Tests:**

**Test 1: Simultaneous Readers ✅**
- Creates state file with 100 pre-inserted strings
- Spawns 5 `fcmd --test-mp search` processes, each searching for different strings
- Verifies all processes exit with code 0 (found)
- Verifies state file unchanged after concurrent reads
- **Result:** All 5 reader processes succeeded, state file intact ✓

**Test 2: Concurrent Readers + 1 Writer ✅**
- State file with 50 initial strings
- Spawns 4 reader processes searching for existing strings
- Spawns 10 writer operations inserting new strings
- Verifies all 60 strings present at end (50 original + 10 new)
- Verifies all readers succeeded
- **Result:** Readers + writer test passed, all 60 strings present ✓

**Test 3: Multiple Writers (Semaphore Stress) ✅**
- Empty state file
- Spawns 60 writer processes (3 writers × 20 strings each)
- Tests semaphore coordination under concurrent write load
- Verifies all 60 strings present in final state (no lost writes)
- Verifies no duplicate blocks or corruption
- **Result:** Multiple writers test passed, all 60 strings present ✓

**Implementation Summary:**
- All tests use `ProcessController` to spawn multiple fcmd.exe instances
- Each process runs with `--test-mp <operation> <state_file> <args>`
- Exit codes communicate success/failure (0 = success)
- Final verification ensures data integrity after concurrent operations
- Tests clean up temporary state files on completion

**Technical Notes:**
- Process spawning uses `std.process.Child.spawn()`
- No artificial delays needed - natural process startup provides timing variation
- Semaphore coordination (in data.zig) handles concurrent access correctly
- All operations verified via `verifyStringsInStateFile()` helper

**Test Results:** 3/3 tests passing ✅
**Total Test Count:** 41/41 tests passing (including all phases)

**Deferred to Future Phases:**
- Resize during concurrent read (requires triggering resize at specific capacity)
- Rapid insert stress with >60 processes (resource limits)
- Zombie process simulation (requires process killing)
- Cross-machine testing (network file systems)

---

### **Phase 5: Advanced Multi-Process Scenarios ✅ COMPLETE**

**Goal:** Test more complex multi-process patterns that stress the trie's synchronization and structural integrity under heavy concurrent load.

**Prerequisites:**
- ✅ All Phase 4.5 tests passing
- ✅ ProcessController infrastructure working reliably
- ✅ CLI test mode handling all operations correctly

**Completed Tests:**

**Test 1: Rapid Insert Stress ✅**
- State file with 10 initial strings
- Spawns 250 concurrent insert operations (5 processes × 50 inserts each)
- Tests semaphore handling under heavy write load
- Verifies all 260 strings present (10 initial + 250 inserted)
- **Result:** All 260 strings verified, no data loss under rapid concurrent writes ✓

**Test 2: Search During Concurrent Inserts ✅**
- State file with 100 original strings
- Spawns 3 reader processes searching for original strings
- Spawns 60 writer operations inserting new strings (3 writers × 20 each)
- Tests read/write interleaving and data consistency
- Verifies all 160 strings present (100 original + 60 new)
- Verifies all reader searches succeeded
- **Result:** All readers succeeded, all 160 strings present ✓

**Test 3: Shared Prefix Stress (Concurrent Tall→Wide Promotions) ✅**
- Empty state file
- Spawns 60 concurrent inserts with common prefix "SHARED_PREFIX_TESTING_"
- Tests structural promotions (tall→wide) under concurrent access
- Verifies trie promotion logic handles concurrent modifications correctly
- All strings have 22-character common prefix, forcing deep tree structure
- **Result:** All 60 strings with shared prefix present, no corruption during promotions ✓

**Implementation Summary:**
- Rapid stress test validates semaphore performance under 250 concurrent operations
- Search during inserts proves readers can operate safely during concurrent writes
- Shared prefix test stresses the tall→wide promotion code path concurrently
- All tests verify complete data integrity after concurrent operations

**Technical Notes:**
- Rapid stress spawns processes quickly to maximize concurrency overlap
- No artificial delays - natural OS scheduling provides realistic concurrency
- Shared prefix test uses 22-char prefix (same as TallStringLen) to force promotions
- All operations go through semaphore coordination in data.zig

**Test Results:** 3/3 tests passing ✅
**Total Test Count:** 44/44 tests passing (all phases)

**Performance Observations:**
- 250 concurrent inserts complete successfully with no lost writes
- Semaphore coordination scales well under heavy concurrent load
- Tall→wide promotions handle concurrent access without corruption
- Read operations proceed safely during concurrent writes

**Deferred:**
- Resize during concurrent access (requires precise capacity control)
- >250 concurrent operations (OS resource limits)
- Long-running concurrent operations with process lifecycle events

---

## Proposed Test Categories (Future Phases)
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

1. ✅ **Phase 0:** Implement basic test infrastructure (11 tests) - COMPLETE
2. ✅ **Phase 1:** Single-process stress tests (6 tests) - COMPLETE
3. ✅ **Phase 2:** Data integrity validation (7 tests) - COMPLETE
4. ✅ **Phase 3:** Edge cases and boundary conditions (7 tests) - COMPLETE
5. ✅ **Phase 4:** Multi-process infrastructure (3 tests) - COMPLETE
6. ✅ **Phase 4.5:** Multi-process concurrency tests (3 tests) - COMPLETE
7. ✅ **Phase 5:** Advanced multi-process scenarios (3 tests) - COMPLETE
8. **Phase 6:** File system integration tests (cold start, corruption detection, etc.)
9. **Phase 7:** Fuzzing and chaos engineering

**Current Status:** 44/44 tests passing ✅

**Phase 5 Achievement:** Successfully stress-tested concurrent multi-process access with:
- Rapid insert stress (250 concurrent write operations)
- Search during concurrent inserts (readers operating safely during writes)
- Shared prefix stress (60 concurrent inserts forcing tall→wide promotions)

All tests demonstrate robust semaphore coordination, structural integrity under concurrent load, and complete data consistency.

