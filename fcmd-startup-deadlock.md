# fcmd Startup Deadlock: Root Cause and Fix

## Symptom

Opening fcmd after a test run that crashed or was force-killed results in the prompt
drawing but all keyboard input being silently ignored. The process is alive but stuck.

## Root Cause

fcmd uses three named Windows kernel objects for cross-process coordination:

| Object | Name | Type |
|--------|------|------|
| Unload signal | `fcmd_unload_data` | Manual-reset event |
| Reload signal | `fcmd_reload_data` | Manual-reset event |
| Handle count | `Local\fcmd_data_semaphore` | Semaphore |

These objects are **global by name** — any process on the same session that calls
`CreateEventA` / `CreateSemaphoreA` with these names opens the existing object rather
than creating a fresh one.

### Normal startup sequence

On a clean boot:

1. `BackingData.init` creates/opens `fcmd_unload_data` (initial state: **not signaled**)
2. Background thread starts and blocks on `WaitForSingleObject(unload_event, INFINITE)`
3. Main thread enters the input loop, locking `data_mutex` per keystroke

### What goes wrong after a crash

The phase5 integration tests spawn many short-lived `fcmd.exe --test-mp` processes.
If those processes are force-killed mid-operation (e.g. test timeout, Ctrl-C), they
may leave `fcmd_unload_data` in the **signaled** state.

The next time fcmd starts:

1. `BackingData.init` calls `CreateEventA` — **returns the existing, still-signaled
   event** (Windows opens by name, no reset)
2. Background thread calls `WaitForSingleObject(unload_event)` — **returns immediately**
   because the event is already signaled
3. Background thread acquires `data_mutex` (no contention yet)
4. Background thread calls `WaitForSingleObject(reload_event, INFINITE)` — **blocks
   forever**: nobody will signal `reload_event` because no unload was actually requested
5. User types a character; main thread calls `data_mutex.lockUncancelable()` —
   **deadlocks**: background thread holds the mutex and will never release it

The prompt draws (that happens before the first keystroke acquires the mutex) but all
input is silently lost.

## Fix

After opening/creating `fcmd_unload_data`, unconditionally reset it:

```zig
// src/data.zig — BackingData.init_internal
const unload_event = get_event_response.?;
mmap_context.unload_event = unload_event;
// Reset to non-signaled regardless of prior state: if a previous process crashed
// mid-remap it may have left unload_event signaled, which would cause the
// background thread to fire immediately and deadlock while waiting for
// reload_event that no one will ever set.
_ = windows.ResetEvent(unload_event);
```

`ResetEvent` is idempotent — calling it on an already-not-signaled event is a no-op —
so this is safe on a fresh boot too.

## Normal Operation (No Deadlock)

In normal single-process use the coordination objects are never in a bad state:

- `fcmd_unload_data` stays not-signaled; background thread parks on it indefinitely
- The mutex is only held briefly while the trie is read/written
- The background thread only wakes when the mapping needs to be resized

In multi-process use (multiple fcmd instances sharing state), the sequence is:

1. Process A's main thread needs to resize the mapping
2. A sets `hack_we_are_the_process_requesting_an_unload = true`, signals `fcmd_unload_data`
3. Process B's background thread wakes, locks its local mutex, closes its map handle,
   decrements the semaphore, waits on `fcmd_reload_data`
4. Process A polls the semaphore until the count reaches 0 (all other processes have
   unmapped), resizes, then signals `fcmd_reload_data`
5. Process B's background thread wakes, reopens the mapping, increments the semaphore,
   unlocks the mutex

Process A's own background thread skips step 3 because it checks the
`hack_we_are_the_process_requesting_an_unload` flag and sleeps instead.

## Known Limitation (Pre-existing)

If two processes attempt to resize **simultaneously**, both set the hack flag and both
background threads skip the semaphore-decrement step. Both main threads then spin
waiting for the semaphore count to reach zero — which never happens. This is a
livelock. It is an existing design constraint, not something introduced by this fix,
and does not arise in typical single-user shell usage.
