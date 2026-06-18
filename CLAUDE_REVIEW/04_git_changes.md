# Review: Git Changes

Two separate commits touching the `git` crate.

---

## 1. SCP Remote Detection for Non-Standard SSH Usernames (#59457)

**File:** `crates/git/src/remote.rs` (+18 lines)

### What it does

The `USERNAME_REGEX` that detects `user@host:path` SCP-style remotes previously matched only `[0-9a-zA-Z\-_]+@`. This excluded valid usernames containing a dot (`.`), e.g. `first.last@gitlab.example.com:group/repo.git`.

**Before:**
```rust
static USERNAME_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[0-9a-zA-Z\-_]+@").expect("Failed to create USERNAME_REGEX"));
```

**After:**
```rust
// Detect the `user@` prefix of an SCP-like remote (e.g. `git@host:path`). The
// username may contain anything but the `@`/`:`/`/` that delimit the user,
// host, and path, so match by exclusion rather than an allowlist that misses
// names like `first.last`.
static USERNAME_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[^/@:]+@").expect("Failed to create USERNAME_REGEX"));
```

### Assessment

**The fix is correct and the approach is right.** Exclusion-based character classes (`[^...]`) for username matching is the right strategy — SSH usernames can contain almost anything except `@`, `:`, and `/` which are structural delimiters in SCP syntax.

The comment is excellent — it explicitly explains *why* exclusion rather than allowlist. This is the kind of comment that saves future readers from reverting the change.

**Two new test cases added:**
```rust
("https://jlannister@github.com/octocat/zed.git", "https", ...),
("first.last@gitlab.example.com:group/repo.git", "ssh", ...),
```

These cover the HTTPS-with-username case and the dotted-username SCP case respectively. The regression case `git@github.com:octocat/zed.git` (plain username) is already tested and continues to pass.

**One omission:** The regex now matches `^[^/@:]+@` which would also accept empty component before `@` since `+` requires at least one char. An empty username `@host:path` would not match (correct). However, there's no test for a remote that starts with just `@`. Low risk since real git remotes always have a username.

**Verdict: Clean, targeted fix with good comment and adequate tests.** ✅

---

## 2. Fast Access Check for Repository in Git Panel (#59514)

**File:** `crates/git/src/repository.rs` (+33 lines)

### What it does

Adds a `check_access()` method to the `GitRepository` trait with a default no-op implementation:

```rust
fn check_access(&self) -> BoxFuture<'_, Result<()>> {
    async move { Ok(()) }.boxed()
}
```

`RealGitRepository` overrides it to run `git rev-parse` in the worktree:

```rust
fn check_access(&self) -> BoxFuture<'_, Result<()>> {
    let git = self.git_binary_in_worktree();
    self.executor
        .spawn(async move {
            git?.run(&["rev-parse"]).await?;
            Ok(())
        })
        .boxed()
}
```

### Assessment

**Purpose:** The Git panel previously called expensive operations (e.g. listing branches) to detect if the repository is accessible. `git rev-parse` is lighter-weight — it just verifies the working tree exists and git can see it.

**Trait design:**

The default implementation returning `Ok(())` is appropriate for stub/fake repositories in tests. This follows Rust trait design best practices: provide a sensible default for implementors that don't care about access checking, override for the real implementation.

**`git rev-parse` is correct for this purpose.** It:
- Is fast (no network)
- Fails if the git directory is corrupt
- Fails if the worktree is not a git repo
- Exits 0 for any valid git repo (including bare)

**Test:**

```rust
#[gpui::test]
async fn test_check_access(cx: &mut TestAppContext) {
    let repo_dir = tempfile::tempdir().unwrap();
    let repository = RealGitRepository::new(
        &repo_dir.path().join(".git"),
        None, Some("git".into()), cx.executor(),
    ).unwrap();

    assert!(repository.check_access().await.is_err());   // no .git yet
    git_init_repo(repo_dir.path());
    assert!(repository.check_access().await.is_ok());    // .git created
}
```

This is a clean, direct test. It constructs the repo against a non-existent `.git` dir (should fail), then initialises it (should succeed). Correct.

**Minor style note:** `Some("git".into())` — the `git` path argument. This is fine, but in a real environment the binary path comes from settings. The test hardcodes `"git"` which relies on `git` being on `PATH`. The test calls `disable_git_global_config()` to avoid interference, which is correct practice.

**Verdict: Well-designed minimal API.** ✅

---

## Combined Code Quality

| Axis | Score | Notes |
|------|-------|-------|
| Correctness | ★★★★★ | Both fixes are correct |
| Clarity | ★★★★★ | The regex comment is exemplary |
| Rust idioms | ★★★★★ | `BoxFuture` + `boxed()` is idiomatic for async trait methods |
| Test coverage | ★★★★☆ | Both have tests; username edge cases slightly undertested |
| Architecture | ★★★★★ | Default impl on trait is exactly right |
