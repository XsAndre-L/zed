# Review: Markdown Preview Changes

Two separate commits:

1. **Do not show deleted hunks (#59485)** — fixes the preview using diff-expanded text
2. **Add max-width setting (#59512)** — adds configurable content width

---

## 1. Do Not Show Deleted Hunks in Markdown Preview (#59485)

**File:** `crates/markdown_preview/src/markdown_preview_view.rs`

### What it does

When the editor's `MultiBuffer` contains an expanded diff (e.g. from a `BufferDiff`), `snapshot.text()` includes both the old (deleted) and new (inserted) lines. The markdown preview was using that full diff-expanded text, causing "old" content to appear in the preview alongside "new" content.

**Before:**
```rust
let contents = editor.buffer().read(cx).snapshot(cx).text();
```

**After:**
```rust
editor.update(cx, |editor, cx| {
    let contents = editor
        .buffer()
        .read(cx)
        .as_singleton()?
        .read(cx)
        .as_rope()
        .to_string()
        .into();
    let selection_start = Self::selected_source_index(editor, cx)?;
    Some((contents, selection_start))
})
```

The fix reads the *singleton buffer* directly, bypassing the `MultiBuffer` snapshot that includes diff hunks.

### Assessment

**Correct diagnosis and fix.** The `MultiBuffer` snapshot text includes diff hunk text for display purposes; the actual file content lives in the underlying singleton buffer. Reading `as_singleton()?.read(cx).as_rope().to_string()` gives the true buffer text.

**`selected_source_index` now returns `Option<usize>`:**

```rust
fn selected_source_index(editor: &Editor, cx: &mut App) -> Option<usize> {
    let display_snapshot = editor.display_snapshot(cx);
    let source_offset = editor
        .selections
        .last::<MultiBufferOffset>(&display_snapshot)
        .range()
        .start;
    let buffer = editor.buffer().read(cx).as_singleton()?;
    let buffer_id = buffer.read(cx).remote_id();
    let (buffer_snapshot, buffer_offset) = display_snapshot
        .buffer_snapshot()
        .point_to_buffer_offset(source_offset)?;

    if buffer_snapshot.remote_id() == buffer_id {
        Some(buffer_offset.0)
    } else {
        None
    }
}
```

Previously this returned `usize` (0 if not found). The new version returns `None` when:
- The editor doesn't have a singleton buffer (multi-file editor)
- The cursor position maps to a different buffer than the singleton (e.g. cursor is inside a diff hunk from another buffer)

Both cases are correct — the preview should not attempt to sync scroll position when the cursor is in diff content.

**The `sync_preview_to_source_index` call is now guarded:**

```rust
if let Some(selection_start) = selection_start {
    this.sync_preview_to_source_index(selection_start, editor_is_focused, cx);
    cx.notify();
}
```

This is correct. Previously it was called unconditionally with `0` when the cursor wasn't in the main buffer.

**Test:**

```rust
#[gpui::test]
async fn preview_uses_buffer_contents_instead_of_diff_contents(cx: &mut TestAppContext) {
```

The test creates a buffer with content `"new\n"`, attaches a diff with base text `"old\n"`, expands the diff hunks (which makes `snapshot.text()` include both), and verifies the preview shows only `"new\n"`. This is a direct regression test for the bug.

**One concern:** The fix uses `.as_rope().to_string()` which clones the entire buffer text. For very large markdown files, this could be expensive (but was already the case before; the old `.text()` on `MultiBuffer::snapshot` also allocates). No regression here.

**Verdict: Correct, well-tested fix for a subtle rendering bug.** ✅

---

## 2. Add Max-Width Setting for Markdown Preview (#59512)

**Files:** `crates/markdown_preview/src/markdown_preview_settings.rs`,  
`crates/markdown_preview/src/markdown_preview_view.rs`,  
`crates/settings_content/src/settings_content.rs`,  
`crates/settings_ui/src/page_data.rs`,  
`assets/settings/default.json`

### What it does

Adds two settings:
- `markdown_preview.limit_content_width: bool` (default: `true`) — whether to constrain width
- `markdown_preview.max_width: f32` (default: `800`) — pixel width when constraining

When enabled, the preview wraps content in:
```rust
div()
    .w_full()
    .when_some(max_width, |this, max_width| this.max_w(max_width).mx_auto())
    .child(content)
```

### Assessment

**Clean, minimal implementation.** The layout approach (`max_w` + `mx_auto`) is standard CSS-like centered-content pattern, appropriate for GPUI's styling system.

**Settings architecture is correct.** The settings content struct, settings UI page data, and the actual settings struct are all updated in sync. The `DynamicItem` in `page_data.rs` correctly gates the `max_width` item on `limit_content_width: true` being selected.

**Issue: `max_width` setting uses `f32` rather than `Pixels`.**

```rust
pub max_width: Option<f32>,
```

In GPUI, layout dimensions are in `Pixels` (a newtype over `f32`). Internally, the code does:

```rust
let max_width = MarkdownPreviewSettings::get_global(cx).max_width;
// ...
.when_some(max_width, |this, max_width| this.max_w(max_width).mx_auto())
```

`max_w()` presumably accepts a value that can be coerced to a `DefiniteLength` — if `max_w(f32)` is defined it likely treats it as `px(f32)`. This works but is implicit. Using a named unit in the settings (e.g., documenting "in pixels") is fine, but the type `f32` in the settings struct and the GPUI `Pixels` used in layout create an implicit conversion that future maintainers might misread as "relative units."

Not a bug, but worth a comment: `// interpreted as pixels`.

**Settings UI: `DynamicItem` wiring is verbose but correct.**

The `pick_discriminant` closure:
```rust
pick_discriminant: |settings_content| {
    let enabled = settings_content
        .markdown_preview
        .as_ref()?
        .limit_content_width
        .unwrap_or(true);
    Some(if enabled { 1 } else { 0 })
},
```

The `unwrap_or(true)` correctly matches the default setting. The discriminant 1 → show max_width field, 0 → hide it. This pattern is consistent with how other conditional settings are handled in the settings UI.

**Verdict: Clean, well-integrated feature addition.** The `f32` vs `Pixels` implicit conversion is a minor documentation gap. ✅

---

## Combined Code Quality

| Axis | Score | Notes |
|------|-------|-------|
| Correctness | ★★★★★ | Hunk-exclusion fix is provably correct |
| Clarity | ★★★★☆ | `f32` vs `Pixels` needs a comment |
| Rust idioms | ★★★★★ | Option-returning function, `when_some` chaining |
| Test coverage | ★★★★★ | Direct regression test for the hunk bug |
| Architecture | ★★★★★ | Settings integration follows established patterns |
