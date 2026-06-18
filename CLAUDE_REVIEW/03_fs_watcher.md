# Review: FS Watcher Reader-Thread Dispatch (`fs: Dispatch watcher events from the reader thread to avoid thrashing #59537`)

**File:** `crates/fs/src/fs_watcher.rs` (+347 / -60 net)

---

## What it does

Previously, `notify` watcher callbacks were dispatched *directly* on the OS watcher's internal thread, and each callback had to acquire `state.lock()` to look up which registered callbacks to fire. This caused lock contention between the reader thread and any thread registering/unregistering watchers.

The new design:

1. `enqueue()` — called from the OS watcher thread; filters trivial `Access` events and sends `(mode, event)` over an `async_channel`.
2. A dedicated **dispatch thread** reads from the channel and calls `dispatch()`.
3. `dispatch()` acquires the lock once, collects all matching callbacks into a `Vec`, releases the lock, then fires the callbacks without holding the lock.

Additionally:
- `PathRegistrationState.count: u32` → `watcher_ids: Vec<WatcherRegistrationId>` — from a count to an actual list of IDs, enabling O(1) removal by ID rather than requiring the caller to ensure symmetric add/remove.
- All path keys upgraded from `Arc<std::path::Path>` → `Arc<SanitizedPath>`.

---

## Architecture & Design

### Strengths

**1. Lock is held for lookup only, not during callback execution.**  
This is the central improvement. The previous design held the lock while running callbacks (or it wasn't holding it at all, depending on the path — the diff shows `dispatch` was previously inlined in the watcher callback). Now there's a clear separation: lock → collect callbacks → unlock → fire. This is exactly the right pattern for observer dispatch.

**2. `watcher_ids` instead of `count` is a meaningful improvement.**  
The old `count: u32` was misleading — it tracked how many registrations existed for a path but couldn't tell *which ones*, making `remove_registration` fragile (it decremented blindly). Switching to `Vec<WatcherRegistrationId>` means `remove_registration` can now do:

```rust
path_state.watcher_ids.retain(|&existing| existing != id);
```

This is unambiguous and correct even if the same path is registered multiple times from different callers.

**3. `enqueue` pre-filters `Access` events.**  
```rust
if matches!(event, Ok(Event { kind: EventKind::Access(_), .. })) {
    return;
}
```
Access events are high-frequency noise (file reads trigger them). Dropping them at the enqueue site avoids a round-trip through the channel for events that would be discarded anyway.

**4. `SanitizedPath` in map keys.**  
Upgrading from raw `Arc<std::path::Path>` to `Arc<SanitizedPath>` in both hash maps ensures path comparison is always normalised. This would fix subtle bugs where e.g. trailing slashes or case differences (on macOS's case-insensitive FS) could cause duplicate registrations.

---

### Issues Found

#### 🟡 Dispatch thread has no backpressure / overflow handling

`async_channel` is unbounded by default. If the OS generates a burst of events (e.g., large file tree move) faster than the dispatch thread can drain them, memory will grow without bound.

```rust
type DispatchEvent = (WatcherMode, Result<notify::Event, notify::Error>);
// ...
self.event_tx.try_send((mode, event)).ok();  // silently drops on full
```

Wait — `try_send` on an *unbounded* channel never returns `Err(Full)`, only `Err(Disconnected)`. So this won't drop events on burst. Unbounded is fine here since watcher events tend to burst then stop, and `dispatch` is fast (just lock + collect). The comment `// A failed send only happens once the dispatch thread has shut down` is accurate.

**Verdict:** No bug. The comment is clear. Unbounded is a fine choice for this use case.

---

#### 🟡 `ids.sort_unstable_by_key(|id| id.0)` + `dedup()` could silently wrong-deduplicate

```rust
for path in &event.paths {
    let sanitized = SanitizedPath::new(path);
    for ancestor in sanitized.as_path().ancestors() {
        let ancestor = SanitizedPath::unchecked_new(ancestor);
        if let Some(registration) = path_registrations.get(ancestor) {
            ids.extend_from_slice(&registration.watcher_ids);
        }
    }
}
ids.sort_unstable_by_key(|id| id.0);
ids.dedup();
```

An event affecting multiple paths might list the same watcher ID twice (once per path). `sort + dedup` is the correct and idiomatic way to deduplicate a `Vec`. The sort is by `id.0` (the `u32` inner field of `WatcherRegistrationId`), which is total order — correct.

**One minor point:** `ids.dedup()` only removes *consecutive* duplicates, which is only correct after sorting. Since sorting is done first, this is fine. The implementation is correct.

---

#### 🟢 `unchecked_new` naming warrants a comment

```rust
let ancestor = SanitizedPath::unchecked_new(ancestor);
```

`unchecked_new` is used because `ancestor` is a sub-path of an already-sanitised path, so it's safe. A brief comment would reassure future readers:

```rust
// ancestor is derived from a SanitizedPath so it is already normalized
let ancestor = SanitizedPath::unchecked_new(ancestor);
```

---

#### 🟢 No test coverage for the new dispatch path

The diff adds no new tests for:
- The `enqueue` / `dispatch` split
- The `watcher_ids` tracking behaviour
- Multi-path event deduplication

The existing watcher integration tests presumably still pass, exercising the system end-to-end, but the new internal mechanics are not unit-tested. Given this is a performance/correctness fix to a concurrency-sensitive subsystem, a targeted test for the "multiple registrations on same path → each fires exactly once" behaviour would be valuable.

---

## Code Quality

| Axis | Score | Notes |
|------|-------|-------|
| Correctness | ★★★★★ | Lock discipline is correct; dedup logic is correct |
| Clarity | ★★★★☆ | `unchecked_new` needs a comment; channel type alias helps |
| Rust idioms | ★★★★★ | `retain`, `extend_from_slice`, `sort_unstable` all appropriate |
| Test coverage | ★★★☆☆ | No new unit tests for the new dispatch path |
| Architecture | ★★★★★ | The enqueue/dispatch split is a clean, industry-standard pattern |

**Overall: Solid, well-executed fix for a real concurrency issue.** A targeted unit test for the dispatch logic would raise confidence significantly.
