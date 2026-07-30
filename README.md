# Cairn

A fast, cross-platform Git client with integrated terminals and AI coding-agent
workflows. Cairn is built with Tauri 2, Rust/libgit2, React, and TypeScript.

This repository publishes the signed desktop installers, standalone terminal UI
packages, Docker image, and the [Cairn website](https://layatai.github.io/cairn-app/).

[Download the latest release](https://github.com/layatai/cairn-app/releases/latest)
· [Interactive tour](https://layatai.github.io/cairn-app/)

![Cairn](site/screenshot.png)

## Downloads

Current release: [Cairn v0.6.39](https://github.com/layatai/cairn-app/releases/tag/v0.6.39)

| Product | Platform | Release asset | Notes |
|---|---|---|---|
| Desktop app | macOS, Intel + Apple Silicon | `Cairn_<version>_universal.dmg` | Universal, Developer ID signed, notarized, and stapled |
| Desktop app | Windows x64 | `Cairn_<version>_x64-setup.exe` or `Cairn_<version>_x64_en-US.msi` | Windows may show SmartScreen because the installer is not yet code-signed |
| Standalone TUI | macOS | `cairn-tui-darwin-universal.tar.gz` | Universal binary |
| Standalone TUI | Linux | `cairn-tui-linux-x64.tar.gz` or `cairn-tui-linux-arm64.tar.gz` | Also supported in WSL2 |
| Standalone TUI | Windows | `cairn-tui-windows-x64.zip` or `cairn-tui-windows-arm64.zip` | Native terminal host included |

## Install the desktop app

### macOS

1. Download the universal DMG from the [latest release](https://github.com/layatai/cairn-app/releases/latest).
2. Open it and drag **Cairn** into **Applications**.
3. Launch Cairn normally. The app is signed and notarized by Apple.

### Windows

Download either the setup executable or MSI from the
[latest release](https://github.com/layatai/cairn-app/releases/latest). If
SmartScreen appears, choose **More info → Run anyway**.

## Install the standalone TUI

The installers select the correct architecture, verify the release checksum,
install the native terminal host, and can be rerun later to update Cairn.

### macOS, Linux, or WSL2

```bash
curl -fsSL --proto '=https' --tlsv1.2 https://layatai.github.io/cairn-app/install.sh | bash
```

### Windows PowerShell

```powershell
iwr -useb https://layatai.github.io/cairn-app/install.ps1 | iex
```

Standalone package hashes are published in
[`cairn-tui-checksums.txt`](https://github.com/layatai/cairn-app/releases/latest/download/cairn-tui-checksums.txt).

## Run Cairn with Docker

The published web image currently targets Linux AMD64. It keeps repositories
and user configuration in named volumes and binds to localhost by default. The
first start installs the common agent CLI toolset and can take one or two minutes.

```bash
CAIRN_DOCKER_PASSWORD="$(openssl rand -hex 12)"
docker run -d \
  --name cairn \
  --restart unless-stopped \
  -p 127.0.0.1:8080:8080 \
  -e CAIRN_USER=cairn \
  -e CAIRN_PASS="$CAIRN_DOCKER_PASSWORD" \
  -v cairn-workspace:/workspace \
  -v cairn-home:/home/cairn \
  docker.io/layatai/cairn-web:0.6.39
printf 'Open http://127.0.0.1:8080 and sign in as cairn with password: %s\n' "$CAIRN_DOCKER_PASSWORD"
```

Use a TLS reverse proxy before exposing Cairn beyond localhost. The immutable
`0.6.39` image and `latest` currently resolve to Docker index digest
`sha256:562ea2ca9272c0937bc303c9deb3daf5c748bf4de5c74608342d1d77ea53cd05`.

## Features

- Integrated terminal tabs for shells and AI coding agents such as Claude Code,
  Codex, Gemini, and OpenCode
- Resizable terminal session rail that automatically switches between compact
  and expanded layouts
- Standalone TUI with detachable sessions and native reconnect support
- AI-generated Conventional Commit messages from staged changes
- Commit graph with lane coloring, virtualized history, and message, author, and
  path filters
- Complete working-tree workflow: stage, unstage, discard, commit, and amend
- Branch, remote, tag, and stash management
- Fetch, pull, push, and clone through system Git authentication
- Diff viewer, blame, file history, interactive rebase, cherry-pick, revert,
  reset, merge, split, and reword
- History Rewrite Studio and stack-aware `.gitignore` generation
- Command palette, configurable themes and density, and English/Vietnamese UI

## Integrity

- The macOS v0.6.39 DMG SHA-256 is
  `f09b5890c3c7837decf5f3a6d6e25ef117bf3402f4d97efca13173cbb3c1fd86`.
- Standalone TUI checksums are shipped with every release and verified by the
  installation scripts.

---

© Cairn. Signed and notarized for distribution.
