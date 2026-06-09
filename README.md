# gitui

A fast, cross-platform desktop **Git client** — near-native performance with
comprehensive workflow coverage. Built with **Tauri 2 + Rust (libgit2) + React/TypeScript**.

This repository hosts the **signed, notarized installers**. Grab the latest from
[**Releases**](../../releases/latest).

![gitui](screenshot.png)

## Download

| Platform | File | Notes |
|---|---|---|
| **macOS** (Intel + Apple Silicon) | `gitui_<version>_universal.dmg` | Universal binary, **notarized** by Apple — opens with no Gatekeeper warning |
| **Windows** | `.msi` / `-setup.exe` | _coming soon_ |

## Install (macOS)

1. Download the `.dmg` from [Releases](../../releases/latest).
2. Open it and drag **gitui** into your **Applications** folder.
3. Launch it — it's signed with a Developer ID and notarized, so it just opens.

## Features

- **Integrated terminal** with tabs — run shells **or AI coding agents** (Claude Code, Codex, Gemini, OpenCode) right in the repo; background tabs ring when an agent needs you
- **AI commit messages** — ✦ Generate a Conventional Commits message from the staged diff
- **Open in** any installed app — VS Code, Cursor, Terminal, Finder, Xcode, …
- Commit graph with lane coloring, virtualized history, and message/author/path filters
- Working directory: stage / unstage / discard, commit, amend
- Branches, remotes, tags, stashes — as collapsible trees
- Diff viewer, blame, file history
- Fetch / pull / push / clone via the system `git` (reliable auth)
- Interactive rebase, cherry-pick, revert, reset, merge, split/reword
- **History Rewrite Studio** (git-filter-repo powered)
- `.gitignore` generator (detects your stack, unions github/gitignore templates)
- Right-click file menus, command palette (⌘K), themes (warm / dark / cream / classic),
  density + EN/VI via the Tweaks panel

---

© gitui. Signed & notarized for distribution.
