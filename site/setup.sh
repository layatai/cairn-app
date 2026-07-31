#!/usr/bin/env bash
# Bootstrap Node.js when absent, then hand all setup work to setup-wizard.mjs.
set -euo pipefail

readonly CAIRN_SETUP_BASE_DEFAULT="https://layatai.github.io/cairn-app"
readonly CAIRN_NODE_BASE_DEFAULT="https://nodejs.org/dist"
readonly CAIRN_MANAGED_NODE_VERSION="22.23.1"
readonly CAIRN_MIN_NODE_MAJOR="18"
readonly PATH_MARKER_BEGIN="# >>> Cairn setup runtime PATH >>>"
readonly PATH_MARKER_END="# <<< Cairn setup runtime PATH <<<"

MODE=""
TOOL_ID=""
DRY_RUN="${CAIRN_SETUP_DRY_RUN:-0}"
SETUP_BASE="${CAIRN_SETUP_BASE_URL:-$CAIRN_SETUP_BASE_DEFAULT}"
NODE_BASE="${CAIRN_NODE_BASE_URL:-$CAIRN_NODE_BASE_DEFAULT}"
TMP_DIR=""

die() {
  printf 'cairn setup: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT HUP INT TERM

while (($# > 0)); do
  case "$1" in
    --all) MODE="all"; shift ;;
    --tool)
      (($# >= 2)) || die "--tool requires an id"
      [[ "$2" =~ ^[a-z0-9-]+$ ]] || die "invalid tool id"
      MODE="tool"
      TOOL_ID="$2"
      shift 2
      ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      printf 'Usage: setup.sh (--all | --tool <id>) [--dry-run]\n'
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$MODE" ]] || die "choose --all or --tool <id>"
[[ "$DRY_RUN" == 0 || "$DRY_RUN" == 1 ]] || die "CAIRN_SETUP_DRY_RUN must be 0 or 1"

OS_NAME="$(uname -s)"
MACHINE_ARCH="$(uname -m)"
case "$OS_NAME" in
  Darwin)
    PLATFORM="darwin"
    DATA_DIR="${CAIRN_DATA_DIR:-$HOME/Library/Application Support/Cairn}"
    ;;
  Linux)
    PLATFORM="linux"
    DATA_DIR="${CAIRN_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/cairn}"
    ;;
  *) die "unsupported operating system: $OS_NAME" ;;
esac
case "$MACHINE_ARCH" in
  arm64|aarch64) NODE_ARCH="arm64" ;;
  x86_64|amd64) NODE_ARCH="x64" ;;
  *) die "unsupported architecture: $MACHINE_ARCH" ;;
esac

NODE_RUNTIME_DIR="$DATA_DIR/runtime/node-v$CAIRN_MANAGED_NODE_VERSION-$PLATFORM-$NODE_ARCH"
NODE_BIN="$NODE_RUNTIME_DIR/bin/node"
NODE_SOURCE=""

node_major() {
  "$1" --version 2>/dev/null | sed -E 's/^v?([0-9]+).*/\1/' | head -n 1
}

if command -v node >/dev/null 2>&1; then
  NODE_BIN="$(command -v node)"
  NODE_SOURCE="existing"
  MAJOR="$(node_major "$NODE_BIN")"
  [[ "$MAJOR" =~ ^[0-9]+$ ]] || die "could not determine the existing Node.js version"
  if ((MAJOR < CAIRN_MIN_NODE_MAJOR)); then
    die "Node.js exists but is too old ($("$NODE_BIN" --version)); upgrade it to Node.js $CAIRN_MIN_NODE_MAJOR+ and retry"
  fi
elif [[ -x "$NODE_BIN" ]]; then
  NODE_SOURCE="managed-existing"
  MAJOR="$(node_major "$NODE_BIN")"
  [[ "$MAJOR" =~ ^[0-9]+$ ]] || die "could not determine the Cairn-managed Node.js version"
  if ((MAJOR < CAIRN_MIN_NODE_MAJOR)); then
    die "Cairn-managed Node.js exists but is too old ($("$NODE_BIN" --version)); remove or upgrade it and retry"
  fi
else
  NODE_SOURCE="managed"
fi

printf 'Cairn setup bootstrap:\n'
printf '  platform : %s/%s\n' "$PLATFORM" "$NODE_ARCH"
printf '  node     : %s (%s)\n' "$NODE_BIN" "$NODE_SOURCE"
printf '  mode     : %s%s\n' "$MODE" "${TOOL_ID:+/$TOOL_ID}"
if [[ "$DRY_RUN" == 1 ]]; then
  if [[ "$NODE_SOURCE" == managed ]]; then
    printf '  action   : would install managed Node.js v%s because node is absent\n' "$CAIRN_MANAGED_NODE_VERSION"
  else
    printf '  action   : would reuse %s\n' "$("$NODE_BIN" --version)"
  fi
  printf '(dry run; no downloads or files changed)\n'
  exit 0
fi

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar >/dev/null 2>&1 || die "tar is required"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cairn-setup.XXXXXX")"

download() {
  local url="$1" destination="$2"
  local -a options=(--fail --silent --show-error --location --retry 3 --retry-delay 1)
  if [[ "$url" == https://* ]]; then
    options+=(--proto '=https' --tlsv1.2)
  elif [[ "${CAIRN_ALLOW_INSECURE_DOWNLOADS:-0}" != 1 ]]; then
    die "refusing non-HTTPS download: $url"
  fi
  curl "${options[@]}" --output "$destination" "$url"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "sha256sum or shasum is required"
  fi
}

verify_checksum() {
  local file="$1" manifest="$2" name="$3" expected actual
  expected="$(awk -v target="$name" '$2 == target || $2 == "*" target { print $1; exit }' "$manifest")"
  [[ -n "$expected" ]] || die "checksum for $name is missing"
  actual="$(sha256_file "$file")"
  [[ "$actual" == "$expected" ]] || die "checksum mismatch for $name"
}

update_runtime_path() {
  local bin_dir="$1" shell_name rc quoted
  PATH="$bin_dir:$PATH"
  export PATH
  shell_name="$(basename "${SHELL:-}")"
  case "$shell_name" in
    zsh) rc="$HOME/.zshrc" ;;
    bash) if [[ "$PLATFORM" == darwin ]]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
    *) rc="$HOME/.profile" ;;
  esac
  if [[ -f "$rc" ]] && grep -F "$PATH_MARKER_BEGIN" "$rc" >/dev/null 2>&1; then
    return
  fi
  printf -v quoted '%q' "$bin_dir"
  {
    printf '\n%s\n' "$PATH_MARKER_BEGIN"
    printf 'export PATH=%s:"$PATH"\n' "$quoted"
    printf '%s\n' "$PATH_MARKER_END"
  } >> "$rc"
}

if [[ "$NODE_SOURCE" == managed ]]; then
  printf '\n==> Installing managed Node.js v%s\n' "$CAIRN_MANAGED_NODE_VERSION"
  NODE_PACKAGE="node-v$CAIRN_MANAGED_NODE_VERSION-$PLATFORM-$NODE_ARCH.tar.gz"
  NODE_URL="${NODE_BASE%/}/v$CAIRN_MANAGED_NODE_VERSION"
  ARCHIVE="$TMP_DIR/$NODE_PACKAGE"
  CHECKSUMS="$TMP_DIR/node-checksums.txt"
  download "$NODE_URL/$NODE_PACKAGE" "$ARCHIVE"
  download "$NODE_URL/SHASUMS256.txt" "$CHECKSUMS"
  verify_checksum "$ARCHIVE" "$CHECKSUMS" "$NODE_PACKAGE"
  tar -tzf "$ARCHIVE" | awk '
    BEGIN { safe = 1 }
    /^\// { safe = 0 }
    /(^|\/)\.\.($|\/)/ { safe = 0 }
    END { exit safe ? 0 : 1 }
  ' || die "Node.js archive contains an unsafe path"
  RUNTIME_PARENT="$(dirname "$NODE_RUNTIME_DIR")"
  STAGE="$RUNTIME_PARENT/.node-install-$$"
  BACKUP="$RUNTIME_PARENT/.node-backup-$$"
  mkdir -p "$RUNTIME_PARENT"
  rm -rf -- "$STAGE" "$BACKUP"
  mkdir "$STAGE"
  tar -xzf "$ARCHIVE" -C "$STAGE" --strip-components=1
  [[ -x "$STAGE/bin/node" ]] || die "Node.js archive is missing bin/node"
  [[ "$("$STAGE/bin/node" --version)" == "v$CAIRN_MANAGED_NODE_VERSION" ]] || die "downloaded Node.js version is invalid"
  if [[ -e "$NODE_RUNTIME_DIR" ]]; then mv "$NODE_RUNTIME_DIR" "$BACKUP"; fi
  if ! mv "$STAGE" "$NODE_RUNTIME_DIR"; then
    [[ ! -e "$BACKUP" ]] || mv "$BACKUP" "$NODE_RUNTIME_DIR"
    die "could not install managed Node.js"
  fi
  rm -rf -- "$BACKUP"
  update_runtime_path "$(dirname "$NODE_BIN")"
elif [[ "$NODE_SOURCE" == managed-existing ]]; then
  update_runtime_path "$(dirname "$NODE_BIN")"
fi

WIZARD="$TMP_DIR/setup-wizard.mjs"
CATALOG="$TMP_DIR/setup-tools.json"
SETUP_CHECKSUMS="$TMP_DIR/setup-checksums.txt"
if [[ -n "${CAIRN_SETUP_SCRIPT:-}" || -n "${CAIRN_SETUP_CATALOG:-}" ]]; then
  [[ -f "${CAIRN_SETUP_SCRIPT:-}" && -f "${CAIRN_SETUP_CATALOG:-}" ]] \
    || die "CAIRN_SETUP_SCRIPT and CAIRN_SETUP_CATALOG must both name existing files"
  cp "$CAIRN_SETUP_SCRIPT" "$WIZARD"
  cp "$CAIRN_SETUP_CATALOG" "$CATALOG"
else
  download "${SETUP_BASE%/}/setup-wizard.mjs" "$WIZARD"
  download "${SETUP_BASE%/}/setup-tools.json" "$CATALOG"
  download "${SETUP_BASE%/}/setup-checksums.txt" "$SETUP_CHECKSUMS"
  verify_checksum "$WIZARD" "$SETUP_CHECKSUMS" "setup-wizard.mjs"
  verify_checksum "$CATALOG" "$SETUP_CHECKSUMS" "setup-tools.json"
fi

ARGS=(--catalog "$CATALOG")
if [[ "$MODE" == all ]]; then ARGS+=(--all); else ARGS+=(--tool "$TOOL_ID"); fi
"$NODE_BIN" "$WIZARD" "${ARGS[@]}"
