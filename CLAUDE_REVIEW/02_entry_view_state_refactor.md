# Review: `EntryViewState` Refactor

**Files touched:** `crates/agent_ui/src/entry_view_state.rs` (+220 / -0 net new logic),  
`crates/agent_ui/src/conversation_view/thread_view.rs` (callers updated)

---

## What it does

Moves scattered per-entry display state from `ThreadView` into the shared `EntryViewState` entity:

- `expanded_thinking_blocks: HashSet<(usize, usize)>`
- `user_toggled_thinking_blocks: HashSet<(usize, usize)>`
- `auto_expanded_thinking_block: Option<(usize, usize)>`
- `expanded_compactions: HashSet<usize>`
- `expanded_tool_calls: HashSet<ToolCallId>` (pre-existing)

Previously `ThreadView` owned `expanded_thinking_blocks`, `expanded_compactions`, etc. directly. Now they live in `EntryViewState`, which is also shared with `ThreadSearchBar` — allowing search to respect visibility without coupling `ThreadView` into the search logic.

---

## Architecture & Design

### Strengths

**1. Correct motivation.**  
The refactor is not gratuitous. The `ThreadSearchBar` *needs* to know which blocks are expanded to decide what to search. The cleanest way to share that knowledge is to put it in a shared entity, which is exactly what `EntryViewState` becomes.

**2. Proper index-rebase on removal.**  
The new `remove` implementation carefully adjusts indices in all three thinking-block sets and `expanded_compactions` after a splice:

```rust
pub fn remove(&mut self, range: Range<usize>) {
    self.entries.drain(range.clone());

    self.expanded_compactions = self
        .expanded_compactions
        .iter()
        .filter_map(|&entry_ix| reindex_after_removal(entry_ix, &range))
        .collect();
    // ... same for thinking blocks ...
}
```

And the helper is simple and correctly tested:

```rust
fn reindex_after_removal(entry_ix: usize, range: &Range<usize>) -> Option<usize> {
    if entry_ix < range.start {
        Some(entry_ix)             // before removal → unchanged
    } else if entry_ix < range.end {
        None                       // inside removal → dropped
    } else {
        Some(entry_ix - (range.end - range.start))  // after → slide down
    }
}
```

The dedicated unit test covers all three cases including an empty range. This is the kind of code that is easy to get subtly wrong, and the author didn't.

**3. `thinking_block_state` properly encapsulates multi-mode logic.**  
The four `ThinkingBlockDisplay` modes had their toggle / state logic spread across `ThreadView`. Now it lives in one place:

```rust
pub(crate) fn thinking_block_state(&self, key: (usize, usize), cx: &App) -> (bool, bool) {
    let is_user_toggled = self.user_toggled_thinking_blocks.contains(&key);
    let is_in_expanded_set = self.expanded_thinking_blocks.contains(&key);
    match AgentSettings::get_global(cx).thinking_display { ... }
}
```

Returning `(is_open, is_constrained)` as a tuple is fine for a crate-internal API, though a named struct would read better at call sites.

---

### Issues Found

#### 🟡 `auto_expand_streaming_thought` is called with `let changed = self.entry_view_state.update(cx, ...)` — change detection is indirect

```rust
pub(crate) fn auto_expand_streaming_thought(&mut self, cx: &mut Context<Self>) {
    let thread = self.thread.clone();
    let changed = self.entry_view_state.update(cx, |state, cx| {
        let thread = thread.read(cx);
        // ...
        state.auto_expand_streaming_thought(thread, cx)
    });
    if changed {
        cx.notify();
    }
}
```

The boolean return from `auto_expand_streaming_thought` is the only signal for `cx.notify()`. If `EntryViewState` is an GPUI `Entity`, any mutation inside `update` already enqueues a notification for *that entity*'s observers. The outer `cx.notify()` on `ThreadView` is still needed (to re-render `ThreadView` itself), so this is correct. But the `changed` boolean path is subtle — if someone adds an early return that forgets to return `false`, the outer `notify` is skipped silently. Consider using `cx.notify()` unconditionally when in streaming state, guarding with a debounce if needed.

---

#### 🟡 `(usize, usize)` key is weakly typed

The `(entry_ix, chunk_ix)` key is used in three separate `HashSet`s. There is no newtype, no doc, and no type alias. A reader has to track the meaning from context. A small type alias:

```rust
type ThinkingBlockKey = (usize, usize); // (entry_ix, chunk_ix)
```

or a tiny struct:

```rust
#[derive(Hash, Eq, PartialEq, Clone, Copy)]
struct ThinkingBlockKey { entry_ix: usize, chunk_ix: usize }
```

would make the intent clear and prevent accidental argument transposition.

---

#### 🟢 `toggle_thinking_block_expansion` for `AlwaysExpanded` mode

```rust
ThinkingBlockDisplay::AlwaysExpanded => {
    if self.user_toggled_thinking_blocks.contains(&key) {
        self.user_toggled_thinking_blocks.remove(&key);
    } else {
        self.user_toggled_thinking_blocks.insert(key);
    }
}
```

In `AlwaysExpanded` mode, all blocks are open by default. A user toggle closes the block, and a second toggle reopens it. The `expanded_thinking_blocks` set is *not* touched here (the visibility comes from `!is_user_toggled` in `thinking_block_state`). The logic is correct but reading `toggle_thinking_block_expansion` requires understanding the `thinking_block_state` reader to verify it — they're effectively two halves of a state machine that are separated across methods. A comment cross-referencing them would help maintainers.

---

## Code Quality

| Axis | Score | Notes |
|------|-------|-------|
| Correctness | ★★★★★ | Index rebase is correct and well-tested |
| Clarity | ★★★★☆ | Weakly-typed key tuple is the main friction |
| Rust idioms | ★★★★★ | Good use of `filter_map` + `collect` for set reindex |
| Test coverage | ★★★★☆ | `reindex` tested; toggle logic not directly tested |
| Architecture | ★★★★★ | The refactor is well-motivated and executed cleanly |

**Overall: Strong refactor.** The thinking-block key being a raw tuple is the only real wart.
