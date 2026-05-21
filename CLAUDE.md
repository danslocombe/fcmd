# fcmd

Windows shell written in Zig. Target: Zig 0.16.0-dev.

## Build & test

- `zig build` — produces `zig-out/bin/fcmd.exe`.
- `zig build check` — compile-only.
- `zig build test --summary all` — **always pass `--summary all`**. The test runner prints `failed command:` lines on stderr even when every test passes (0.16.0-dev quirk); only the `Build Summary` line is authoritative.
- Individual test targets: `test-basic`, `test-extended`, `test-behavioral`, `test-multiprocess`, `test-render`.
- Tests are chained sequentially in `build.zig` to avoid 0.16.0-dev IPC hangs under parallel execution. Don't reintroduce parallelism without fixing that root cause.

## Win32 bindings

- All Win32 API access goes through the `win32` package (zigwin32, https://github.com/marlersoft/zigwin32) wired up in `build.zig.zon`. Do not add `@cImport` of `Windows.h`.
- `src/windows.zig` exposes specialized, project-specific helpers (e.g. `open_or_create_file_rw`, `wait_forever`, `send_ctrl_break`) rather than generic Win32 wrappers. Add new helpers in the same style instead of re-exporting `win32` symbols directly.

## Layout

- `src/main.zig` — entry point, REPL loop.
- `src/windows.zig` — Win32 helpers.
- `src/data.zig` — cross-process memory-mapped trie (named mutex + shared file mapping).
- `src/datastructures/lego_trie.zig` — the trie structure inside the mapping (see below).
- `src/datastructures/inline_string.zig` — fixed-capacity zero-terminated inline strings used for trie edges.
- `src/completion.zig` — tab completion (directory + history + PATH-based).
- `src/run.zig` — process execution and shell built-ins (cd, echo, ls, exit).
- `src/input.zig`, `src/prompt.zig`, `src/render.zig`, `src/shell.zig` — input, prompt, rendering, shell state.
- `src/alloc.zig` — global GPA, temp arena, and shared `g_io: std.Io`.

## lego_trie architecture

Persistent prefix tree backing command history and tab-completion. Lives in a fixed 16MB memory-mapped file (`%APPDATA%\fcmd\trie.frog`); multiple fcmd processes share one trie via the OS page cache. `data.zig` sets up the mapping, `lego_trie.zig` is the structure inside it.

- **Block-indexed layout.** A `Trie` is just a `*MappedArray(TrieBlock)`; block 0 is the root. Children reference other blocks by `u30` block-index, never by pointer, so the file is position-independent — each process can map it at a different virtual address with no fixups.
- **Two block shapes in one union.** A `TrieBlock` is either *tall* (1 edge, up to 22 inline chars per edge) or *wide* (4 edges, 1 inline char each), tagged by `metadata.wide`. Tall is good for linear runs; wide is good for fan-out. Blocks start tall and **promote** to wide one-way when they fill (`promote_tall_to_wide`: the tall edge's tail spills into a fresh child block, leaving the first `WideStringLen` chars on the now-wide parent).
- **Insert = split on common prefix, then spill.** `try_insert_along` finds the longest common prefix with an existing edge; if the new key matches the whole edge, recurse into the child; if they diverge, split the edge — common chunk stays, diverging suffix moves to a new child block. If the block has no matching edge and isn't full, `insert_down` appends. If it's full + tall, promote. If it's full + wide, follow `metadata.next` to a sibling block (creating one if absent) — the spillover chain lets one trie level hold arbitrarily many children.
- **Cost-ordered children with usage decay.** Each edge has `cost: u16`, baseline 65535. Every insert that traverses an edge saturating-decrements its cost — frequently-used edges have *lower* cost. After each insert, `sort` bubble-sorts children across the whole spillover chain so index 0 is the most-used. `TrieWalker.walk_to_heuristic` descends index-0 at each level but bails out when "score of stopping here" comes within a 1.8× ratio of "score of the best child," giving an ambiguity-aware completion (`gi` → `git`, not `git status`, because many `git X` continuations are roughly equal).
- **Leaf encoding.** Two cases: (a) the edge has `is_leaf=true` (the whole string fits in the edge's inline chars), or (b) the child block holds a zero-length leaf edge meaning "this string also terminates here, but longer continuations exist below." Walk / get_child special-case the empty-string edge so it isn't traversed during prefix walks.
- **Cross-process correctness.** Writes go through `Local\fcmd_trie_write_mutex` (`MappedArray.append`). The block count `len` is `std.atomic.Value(usize)` at a fixed offset; release-store after writing a new block's bytes, acquire-load by readers — so readers without the mutex still see fully-published blocks. File starts with magic `frog` + 1-byte version (currently 3), checked on open. No resize: 16MB is hard-coded (`fixed_map_size`), and the trie panics if it fills.
- **Read APIs.** `TrieWalker.walk_to(prefix)` advances as far as the prefix matches and surfaces the trailing edge fragment in `extension` (used for inline ghost-text completion). `SubtreeIterator` is an explicit DFS stack (max depth 64) that yields every complete completion under a subtree root in cost order — used when the UI needs the full candidate list rather than a single best guess.

Known smells: bubble-sort over the full spillover chain on every insert (the source admits it: `// I'm so sorry`); 16MB hard cap with a panic; no recovery path for version-mismatched files.
