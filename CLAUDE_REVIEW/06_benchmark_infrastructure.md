# Review: Benchmark Infrastructure (`perf: Add initial benchmark for markdown element #59524`)

**Files:** `crates/benchmarks/benches/markdown_renderer.rs` (new, 348 lines),  
`crates/benchmarks/src/bench_utils.rs` (new, 89 lines),  
`crates/gpui/src/app/bench_context.rs` (+5 lines),  
`crates/gpui/src/platform/bench_dispatcher.rs` (+42 lines)

---

## What it does

Adds a criterion-style benchmark for the markdown rendering pipeline. The benchmark:

1. Generates pseudo-random markdown documents at sizes: 5 KB, 10 KB, 50 KB, 250 KB (optionally 1 MB via `ZED_BENCH_HUGE`).
2. Parses and renders each document, measuring frame time.
3. Uses a deterministic `StdRng` seeded by index so results are reproducible.

The `BenchDispatcher` gains a `run_ready_main_tasks()` method to flush main-thread work queued by background tasks *between* benchmark iterations, preventing task accumulation from skewing results.

---

## Architecture & Design

### Strengths

**1. Graduated sizes with opt-in huge mode.**

```rust
fn markdown_sizes() -> Vec<usize> {
    let mut sizes = vec![5_000, 10_000, 50_000, 250_000];
    if std::env::var("ZED_BENCH_HUGE").is_ok() {
        sizes.push(1_000_000);
    }
    sizes
}
```

The 1 MB case would make CI very slow, so gating it behind an env var is correct practice. The base sizes span a useful range for detecting O(n²) regressions.

**2. Pseudo-random but deterministic content generation.**

Each size is seeded as `StdRng::seed_from_u64(size as u64)`. This means:
- Benchmark results are reproducible across runs.
- Different sizes use different seeds (not just truncated versions of each other), giving independent content shapes.

Using the *size* as the seed is slightly unusual — if you added a new size, say 20 KB, its seed would be 20000, which may share prefix structure with 50000. A better seed might be `size_index as u64`. Low risk though.

**3. `run_ready_main_tasks()` in `BenchDispatcher`.**

```rust
pub fn run_ready_main_tasks(&self) -> bool {
    assert!(
        self.is_main_thread(),
        "run_ready_main_tasks must be called on the benchmark main thread"
    );
    self.drain_main_queue()
}
```

This is added so the benchmark can flush queued tasks (e.g. theme-change reactions) before each iteration, preventing accumulation. The test for it is:

```rust
#[test]
fn run_ready_main_tasks_does_not_wait_for_background_handoffs() {
    // spawns a background task that sleeps 10ms + signals a foreground task
    // run_ready_main_tasks() → should return true (ran something) but NOT wait
    assert!(dispatcher.run_ready_main_tasks());
    assert!(!completed.load(Ordering::SeqCst)); // foreground task hasn't run yet
    
    dispatcher.run_until_idle();
    assert!(completed.load(Ordering::SeqCst)); // now it has
}
```

This is an excellent test — it precisely documents the contract: "flush what's ready *now*, don't block on background work." The `assert!` return value is used correctly (it returns `bool` indicating whether any work was done).

**4. `bench_utils.rs` shared utilities.**

The `random_rust_file` generator is well-structured — it generates syntactically plausible Rust (uses, struct, impl, functions with bodies) rather than random gibberish. This is important because the markdown renderer uses syntax highlighting; real-looking code exercises the language grammar paths that random bytes wouldn't.

The `debug_assert_eq!(lines.len(), line_count)` at the end of `random_rust_file` is a nice correctness check.

---

### Issues Found

#### 🟡 Benchmark renders then immediately drops the frame — measures layout, not paint

```rust
let mut benchmark = || {
    dispatcher
        .as_bench()
        .expect(...)
        .run_ready_main_tasks();
    self.with_window(view.entity_id(), |window, cx| {
        view.update(cx, |view, cx| update(view, window, cx));
    })
    .expect(...);
};
```

`BenchAppContext::measure_renders` triggers `with_window`, which presumably runs a layout pass. Whether it also runs a paint pass (rasterization) is unclear from the diff. If it's layout-only, the benchmark doesn't measure the actual GPU or software rendering time for markdown, which involves iterating over text runs, computing ligatures, etc.

The comment in the PR title says "Add initial benchmark" — so this being layout-only (or partial) is acceptable as a starting point, but worth documenting.

#### 🟡 No warmup handling visible in the diff

Criterion benchmarks typically have a warmup phase. The `gpui::bench_group!` macro presumably handles this internally. No concern if that's the case, but if it doesn't, the first few iterations will be cold-cache and skew results.

#### 🟡 The `choose` function panics if `items` is empty

```rust
fn choose(rng: &mut StdRng, items: &'static [&'static str]) -> &'static str {
    let index = rng.random_range(0..items.len()); // panics on empty slice
    items.get(index).copied().unwrap_or("markdown")
}
```

`items.len()` is 0 would panic in `random_range`. The `unwrap_or("markdown")` is dead code because `get(index)` would always succeed if `random_range` returns a valid index. Since the slices are compile-time constants and non-empty, this is not a real bug, but the defensive `unwrap_or` gives a false impression of safety.

Better:
```rust
fn choose(rng: &mut StdRng, items: &'static [&'static str]) -> &'static str {
    debug_assert!(!items.is_empty());
    items[rng.random_range(0..items.len())]
}
```

---

## Code Quality

| Axis | Score | Notes |
|------|-------|-------|
| Correctness | ★★★★☆ | Benchmark methodology is sound; warmup unclear |
| Clarity | ★★★★☆ | `choose` has dead `unwrap_or` |
| Rust idioms | ★★★★★ | Deterministic RNG, `debug_assert_eq!` guard |
| Test coverage | ★★★★★ | `run_ready_main_tasks` is precisely tested |
| Architecture | ★★★★★ | Clean separation of bench utils into shared module |

**Overall: Good foundational benchmark infrastructure.** The `run_ready_main_tasks` addition and its test are particularly well-done. The generator code is solid. Minor cleanups (choose, warmup doc) would polish it further.
