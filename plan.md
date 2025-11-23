# Memory-Mapped File Data Corruption Analysis & Fix Plan

## Executive Summary

Analysis of `data.zig` reveals multiple critical issues in the memory-mapped file implementation that can cause data corruption in multi-process scenarios. The most severe issue is a race condition during resize operations where the size is updated before the actual remapping occurs.

---

## Critical Issues Identified

### 🔴 CRITICAL: Issue #1 - Resize Race Condition
**Location**: `DumbList.append()` lines 457-471

**Problem**: 
```zig
self.mmap_context.backing_data.size_in_bytes_ptr.* = @intCast(new_size);
ensure_other_processes_have_released_handle(self.mmap_context);
BackingData.open_map(new_size, self.mmap_context);
```

The size is written to the OLD memory mapping before creating the NEW mapping. Other processes reading this size value will attempt to access memory beyond the valid range, causing:
- Access violations
- Reading uninitialized/garbage data
- Potential segmentation faults

**Impact**: HIGH - Direct cause of data corruption

---

### 🔴 CRITICAL: Issue #2 - Missing FlushViewOfFile
**Location**: Throughout file, no flush calls present

**Problem**: 
After writing data to the memory-mapped region, there's no `FlushViewOfFile` call to ensure data is persisted to disk. If a process crashes:
- Recent writes are lost
- Other processes may read stale data from disk
- File state becomes inconsistent

**Impact**: HIGH - Data loss on crashes

---

### 🟠 HIGH: Issue #3 - Alignment Not Guaranteed
**Location**: `open_map()` line 313

**Problem**:
```zig
// @Reliability switch to MapViewOfFile3 to guarentee alignment
const map_view = windows.MapViewOfFile(...)
```

Current code uses `@alignCast` which is a runtime assertion. If Windows returns an unaligned pointer:
- Runtime crash with assertion failure
- Or worse, undefined behavior if assertions are disabled
- Misaligned access to trie blocks

**Impact**: MEDIUM-HIGH - Can cause crashes or silent corruption

---

### 🟠 HIGH: Issue #4 - Inconsistent Volatile Usage
**Location**: Multiple locations - lines 225, 364, etc.

**Problem**:
```zig
map: []u8,  // Not volatile
trie_blocks.map = @volatileCast(...)  // Removing volatile
```

Memory is marked volatile at creation but immediately cast to non-volatile. Concurrent access from multiple processes requires volatile semantics to prevent compiler optimizations from caching values.

**Impact**: MEDIUM-HIGH - Stale reads, torn writes

---

### 🟠 HIGH: Issue #5 - Missing Memory Barriers
**Location**: All volatile pointer operations

**Problem**:
Using `volatile` pointers without memory barriers/fences. On modern multi-core systems, `volatile` alone doesn't guarantee memory ordering between processors.

**Impact**: MEDIUM-HIGH - Cross-process visibility issues

---

### 🟡 MEDIUM: Issue #6 - Non-Atomic Boolean Flag
**Location**: `hack_we_are_the_process_requesting_an_unload` line 492

**Problem**:
```zig
hack_we_are_the_process_requesting_an_unload: bool = false,
```

Regular boolean used for cross-thread communication without atomic operations or locks. Multiple threads in the same process could see torn reads/writes.

**Impact**: MEDIUM - Race condition in unload logic

---

### 🟡 MEDIUM: Issue #7 - Stale Pointer Risk After Remap
**Location**: `open_map()` lines 294-303

**Problem**:
When remapping, the base address can change. Any pointers held outside the function become invalid. The code updates internal pointers but external references (e.g., in the middle of trie operations) could become dangling.

**Impact**: MEDIUM - Use-after-free potential

---

### 🟡 MEDIUM: Issue #8 - TOCTOU in Semaphore Check
**Location**: `ensure_other_processes_have_released_handle()` lines 507-520

**Problem**:
```zig
if (prev_count == 0) {
    break;
} else {
    windows.Sleep(1);
}
```

Time-of-check-time-of-use race: between checking `prev_count` and breaking, another process could acquire the semaphore.

**Impact**: MEDIUM - Could allow overlapping exclusive operations

---

### 🟢 LOW: Issue #9 - Missing Error Handling
**Location**: Lines 249, 538

**Problem**:
`UnmapViewOfFile` return values not checked. Failed unmapping could lead to resource leaks or incorrect state.

**Impact**: LOW - Resource leak, not direct corruption

---

### 🟢 LOW: Issue #10 - No Mapping Generation Counter
**Location**: General architecture

**Problem**:
No mechanism to detect when pointers reference an old mapping vs the current one.

**Impact**: LOW - Makes debugging harder

---

## Fix Plan - Phased Approach

### Phase 1: Critical Fixes (Prevent Data Corruption)
**Priority**: IMMEDIATE

#### Task 1.1: Fix Resize Race Condition
- [ ] Move size update to AFTER successful remapping
- [ ] Add proper sequencing: unload → remap → update size → reload
- [ ] Add validation that new mapping succeeded before updating size
- [ ] Test with multiple processes performing concurrent resizes

**Files**: `data.zig` - `DumbList.append()`

#### Task 1.2: Add FlushViewOfFile Calls
- [ ] Add flush after critical writes (header updates, resize operations)
- [ ] Add flush before signaling other processes to reload
- [ ] Consider adding periodic background flush
- [ ] Add error handling for flush failures

**Files**: `data.zig` - `DumbList.append()`, `open_map()`, `background_unloader_loop()`

#### Task 1.3: Implement Proper Alignment
- [ ] Research and implement `MapViewOfFile3` for guaranteed alignment
- [ ] Add fallback for older Windows versions
- [ ] Add alignment validation even with MapViewOfFile3
- [ ] Update error handling for alignment failures

**Files**: `data.zig` - `init_internal()`, `open_map()`

---

### Phase 2: Synchronization Fixes (Prevent Races)
**Priority**: HIGH

#### Task 2.1: Fix Volatile Semantics
- [ ] Decide: make entire map volatile OR use atomic operations for shared fields
- [ ] If volatile: remove @volatileCast, make all access through volatile pointers
- [ ] If atomic: convert size_in_bytes_ptr and trie_blocks.len to atomic types
- [ ] Document the chosen memory model

**Files**: `data.zig` - `BackingData`, `DumbList`

#### Task 2.2: Add Memory Barriers
- [ ] Add memory fences after writes before signaling other processes
- [ ] Add memory fences after waits before reading shared data
- [ ] Research Zig's atomic fence API
- [ ] Add comments explaining barrier placement

**Files**: `data.zig` - `ensure_other_processes_have_released_handle()`, `signal_other_processes_can_reaquire_handle()`, `background_unloader_loop()`

#### Task 2.3: Fix Boolean Flag
- [ ] Replace `hack_we_are_the_process_requesting_an_unload` with atomic bool
- [ ] Use atomic load/store operations
- [ ] Add proper synchronization around flag access

**Files**: `data.zig` - `MMapContext`, related functions

---

### Phase 3: Robustness Improvements (Prevent Edge Cases)
**Priority**: MEDIUM

#### Task 3.1: Improve Semaphore Logic
- [ ] Add retry limit to prevent infinite loops
- [ ] Consider using WaitForMultipleObjects with timeout
- [ ] Add deadlock detection
- [ ] Improve logging around semaphore operations

**Files**: `data.zig` - `ensure_other_processes_have_released_handle()`

#### Task 3.2: Add Error Handling
- [ ] Check UnmapViewOfFile return values
- [ ] Handle partial failure scenarios (e.g., unmap succeeds but remap fails)
- [ ] Add recovery mechanisms for failures
- [ ] Improve error messages with more context

**Files**: `data.zig` - all unmap/remap locations

#### Task 3.3: Stale Pointer Detection
- [ ] Add generation counter to mapping
- [ ] Include generation in DumbList and other structures
- [ ] Validate generation before dereferencing
- [ ] Add debug assertions for generation mismatches

**Files**: `data.zig` - `BackingData`, `DumbList`

---

### Phase 4: Testing & Validation
**Priority**: ONGOING

#### Task 4.1: Stress Testing
- [ ] Create multi-process stress test that triggers resizes
- [ ] Run with ThreadSanitizer/AddressSanitizer equivalents
- [ ] Add chaos testing (random delays, crashes)
- [ ] Test on different Windows versions

**Files**: New test files in `src/`

#### Task 4.2: Add Assertions & Validation
- [ ] Add magic number checks before every operation
- [ ] Validate size is within reasonable bounds
- [ ] Add checksum/hash verification (optional)
- [ ] Enable debug logging for corruption investigations

**Files**: `data.zig`, test files

#### Task 4.3: Improve Observability
- [ ] Add detailed logging of all remap operations
- [ ] Log semaphore/event state transitions
- [ ] Add process ID to all log messages
- [ ] Create visualization tool for debugging multi-process scenarios

**Files**: `data.zig`, `log.zig`

---

## Implementation Order

### Week 1: Critical Fixes
1. Day 1-2: Fix resize race condition (Issue #1)
2. Day 3: Add FlushViewOfFile (Issue #2)
3. Day 4-5: Implement MapViewOfFile3 alignment (Issue #3)
4. Test and validate critical fixes

### Week 2: Synchronization
1. Day 1-2: Fix volatile semantics (Issue #4)
2. Day 3: Add memory barriers (Issue #5)
3. Day 4: Fix atomic boolean flag (Issue #6)
4. Day 5: Test synchronization fixes

### Week 3: Robustness & Testing
1. Day 1: Improve semaphore logic (Issue #8)
2. Day 2: Add error handling (Issue #9)
3. Day 3-4: Create comprehensive test suite
4. Day 5: Add observability improvements

---

## Testing Strategy

### Test Cases to Add:
1. **Concurrent resize test**: Multiple processes append simultaneously
2. **Crash recovery test**: Kill process mid-resize, verify other processes recover
3. **Alignment test**: Verify all pointers are properly aligned
4. **Stale read test**: Verify processes see consistent data after remaps
5. **Semaphore deadlock test**: Ensure no deadlocks under contention
6. **Memory barrier test**: Use tools to detect missing barriers
7. **Long-running stability test**: Run for hours/days with random operations

### Success Criteria:
- [ ] No crashes in 24-hour stress test
- [ ] No data corruption detected in validation checks
- [ ] All test cases pass consistently
- [ ] No deadlocks or hangs observed
- [ ] Clean runs with memory sanitizers

---

## Risk Assessment

### Highest Risk Changes:
1. **Memory barrier implementation** - Easy to get wrong, hard to test
2. **Resize sequence changes** - Could introduce new races if not careful
3. **MapViewOfFile3 migration** - Compatibility concerns with older Windows

### Mitigation:
- Implement changes incrementally with testing at each step
- Keep extensive logging during migration
- Have rollback plan (feature flag) for each major change
- Test on multiple Windows versions
- Consider beta testing with subset of users

---

## Open Questions

1. **Q**: Should we use `volatile` everywhere or switch to explicit atomics?
   - **Recommendation**: Use atomics for header fields (size, len), keep bulk data non-volatile

2. **Q**: What's the minimum Windows version to support?
   - **Impact**: Determines if MapViewOfFile3 can be used unconditionally

3. **Q**: Should we add a file format version bump?
   - **Recommendation**: Yes, to ensure old/new code don't mix

4. **Q**: Do we need distributed locking beyond semaphores?
   - **Recommendation**: Current approach OK if we fix the races

5. **Q**: Should we limit maximum file size?
   - **Recommendation**: Yes, add sanity check to prevent runaway growth

---

## Notes

- Current code has good structure but lacks proper synchronization primitives
- The "hack" comments indicate awareness of issues but deferred fixes
- Multi-process shared memory is inherently complex - consider simplifying architecture in future
- Document all assumptions about memory ordering and visibility
- Consider using existing libraries (e.g., Boost.Interprocess equivalent) in future refactor
