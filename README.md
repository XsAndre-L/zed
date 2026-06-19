# Xide

> A personal fork of [Zed](https://github.com/zed-industries/zed) — the high-performance, multiplayer code editor — with a handful of opinionated adjustments to better suit my own workflow.

---

## What is Xide?

Xide is built directly on top of Zed's open-source codebase. Zed itself is a high-performance code editor written in Rust, built by the creators of [Atom](https://github.com/atom/atom) and [Tree-sitter](https://github.com/tree-sitter/tree-sitter). It is fast, keyboard-driven, and designed for serious development work.

Xide keeps everything that makes Zed great and adds a small number of personal tweaks:

- **Left dock, right dock, and terminal open by default** on first launch
- **Key-repeat throughput fix on Windows** — restored to Zed v1.7.x levels by removing a per-character synchronous render that had been introduced in a later commit
- **Xide branding** — logo, app name, and window title

That's it. No grand vision, no diverging roadmap. Just Zed, the way I want it.

---

## Relationship to Zed

| | Zed | Xide |
|---|---|---|
| Codebase | Original | Fork |
| License | GPL-3.0 / Apache-2.0 | Same |
| Target audience | Everyone | Primarily me |
| Cloud features | Full | Unchanged |
| Updates | Official releases | Manual merges from upstream |

Upstream Zed changes can be merged into Xide at any time. I try to stay close to `main`.

---

## Building

Xide builds exactly like Zed. Follow the official Zed build docs for your platform:

- [Building for Windows](./docs/src/development/windows.md)
- [Building for macOS](./docs/src/development/macos.md)
- [Building for Linux](./docs/src/development/linux.md)

```bash
cargo build -p zed --release
# Binary at: target/release/zed.exe (Windows) or target/release/zed (macOS/Linux)
```

---

## Using Xide

You are welcome to clone, fork, or use Xide for your own purposes. It is public and carries the same license as upstream Zed (GPL-3.0-or-later, with Apache-2.0 components where marked).

If you want something specific from Zed without Xide's changes, use [Zed directly](https://zed.dev).

---

## Licensing

Source code is licensed under **GPL-3.0-or-later**, with Apache-2.0 components where marked — identical to upstream Zed.

See [LICENSE-GPL](./LICENSE-GPL) and [LICENSE-APACHE](./LICENSE-APACHE).

---

## Credits

All the real work here was done by the [Zed Industries](https://zed.dev) team and the Zed open-source contributors. Xide stands entirely on their shoulders.
