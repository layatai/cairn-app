#!/usr/bin/env bash
# Install or update the standalone Cairn TUI and its native terminal host.
set -euo pipefail

readonly CAIRN_RELEASE_REPOSITORY="layatai/cairn-app"
readonly CAIRN_MANAGED_NODE_VERSION="22.23.1"
readonly PATH_MARKER_BEGIN="# >>> Cairn TUI PATH >>>"
readonly PATH_MARKER_END="# <<< Cairn TUI PATH <<<"

RELEASE_TAG="${CAIRN_VERSION:-latest}"
INSTALL_DIR="${CAIRN_INSTALL_DIR:-}"
DATA_DIR="${CAIRN_DATA_DIR:-}"
SKIP_PATH_UPDATE="${CAIRN_SKIP_PATH_UPDATE:-0}"
DRY_RUN="${CAIRN_DRY_RUN:-0}"
VERIFY_INSTALL="${CAIRN_VERIFY_INSTALL:-0}"
TMP_DIR=""

usage() {
  cat <<'EOF'
Install or update the standalone Cairn TUI.

Usage:
  install-tui.sh [options]

Options:
  --version <latest|vX.Y.Z>  Release to install (default: latest)
  --install-dir <path>       Launcher directory (default: ~/.local/bin)
  --data-dir <path>          Cairn application-data directory
  --no-path-update           Do not update the active shell profile
  --dry-run                  Print resolved actions without downloading or writing
  --verify                   Run the installed launcher after installation
  -h, --help                 Show this help

Environment:
  CAIRN_VERSION, CAIRN_INSTALL_DIR, CAIRN_DATA_DIR
  CAIRN_SKIP_PATH_UPDATE=1, CAIRN_DRY_RUN=1, CAIRN_VERIFY_INSTALL=1
  CAIRN_DOWNLOAD_BASE_URL    Override the Cairn release download base
  CAIRN_NODE_BASE_URL        Override the official Node.js download base
  CAIRN_ALLOW_INSECURE_DOWNLOADS=1 permits HTTP overrides for local mirrors/tests
EOF
}

die() {
  printf 'install-tui.sh: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '\n==> %s\n' "$*"
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT HUP INT TERM

while (($# > 0)); do
  case "$1" in
    --version)
      (($# >= 2)) || die "--version requires a value"
      RELEASE_TAG="$2"
      shift 2
      ;;
    --install-dir)
      (($# >= 2)) || die "--install-dir requires a value"
      INSTALL_DIR="$2"
      shift 2
      ;;
    --data-dir)
      (($# >= 2)) || die "--data-dir requires a value"
      DATA_DIR="$2"
      shift 2
      ;;
    --no-path-update) SKIP_PATH_UPDATE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verify) VERIFY_INSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

validate_toggle() {
  local name="$1" value="$2"
  [[ "$value" == 0 || "$value" == 1 ]] || die "$name must be 0 or 1"
}
validate_toggle CAIRN_SKIP_PATH_UPDATE "$SKIP_PATH_UPDATE"
validate_toggle CAIRN_DRY_RUN "$DRY_RUN"
validate_toggle CAIRN_VERIFY_INSTALL "$VERIFY_INSTALL"

OS_NAME="$(uname -s)"
MACHINE_ARCH="$(uname -m)"
case "$OS_NAME" in
  Darwin)
    PLATFORM="darwin"
    PLATFORM_LABEL="macOS"
    CAIRN_ARCH="universal"
    case "$MACHINE_ARCH" in
      arm64|aarch64) NODE_ARCH="arm64" ;;
      x86_64|amd64) NODE_ARCH="x64" ;;
      *) die "unsupported macOS architecture: $MACHINE_ARCH" ;;
    esac
    CAIRN_PACKAGE="cairn-tui-darwin-universal.tar.gz"
    ;;
  Linux)
    PLATFORM="linux"
    PLATFORM_LABEL="Linux"
    if [[ -n "${WSL_INTEROP:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null; then
      PLATFORM_LABEL="WSL2"
    fi
    case "$MACHINE_ARCH" in
      arm64|aarch64)
        CAIRN_ARCH="arm64"
        NODE_ARCH="arm64"
        ;;
      x86_64|amd64)
        CAIRN_ARCH="x64"
        NODE_ARCH="x64"
        ;;
      *) die "unsupported Linux architecture: $MACHINE_ARCH" ;;
    esac
    CAIRN_PACKAGE="cairn-tui-linux-${CAIRN_ARCH}.tar.gz"
    ;;
  *) die "unsupported operating system: $OS_NAME" ;;
esac

if [[ -z "$INSTALL_DIR" ]]; then
  INSTALL_DIR="$HOME/.local/bin"
fi
if [[ -z "$DATA_DIR" ]]; then
  if [[ "$PLATFORM" == darwin ]]; then
    DATA_DIR="$HOME/Library/Application Support/Cairn"
  else
    DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/cairn"
  fi
fi
[[ -n "$INSTALL_DIR" && "$INSTALL_DIR" != / ]] || die "unsafe install directory: $INSTALL_DIR"
[[ -n "$DATA_DIR" && "$DATA_DIR" != / ]] || die "unsafe data directory: $DATA_DIR"

case "$RELEASE_TAG" in
  latest) RELEASE_PATH="latest/download" ;;
  v[0-9]*.[0-9]*.[0-9]*) RELEASE_PATH="download/$RELEASE_TAG" ;;
  [0-9]*.[0-9]*.[0-9]*) RELEASE_TAG="v$RELEASE_TAG"; RELEASE_PATH="download/$RELEASE_TAG" ;;
  *) die "invalid version: $RELEASE_TAG" ;;
esac

readonly DEFAULT_CAIRN_BASE="https://github.com/$CAIRN_RELEASE_REPOSITORY/releases/$RELEASE_PATH"
readonly DEFAULT_NODE_BASE="https://nodejs.org/dist/v$CAIRN_MANAGED_NODE_VERSION"
CAIRN_BASE="${CAIRN_DOWNLOAD_BASE_URL:-$DEFAULT_CAIRN_BASE}"
NODE_BASE="${CAIRN_NODE_BASE_URL:-$DEFAULT_NODE_BASE}"
CAIRN_BASE="${CAIRN_BASE%/}"
NODE_BASE="${NODE_BASE%/}"
NODE_PACKAGE="node-v${CAIRN_MANAGED_NODE_VERSION}-${PLATFORM}-${NODE_ARCH}.tar.gz"
NODE_RUNTIME_DIR="$DATA_DIR/runtime/node-v${CAIRN_MANAGED_NODE_VERSION}-${PLATFORM}-${NODE_ARCH}"
NODE_BIN="$NODE_RUNTIME_DIR/bin/node"

cat <<PLAN
Cairn TUI install plan:
  platform : $PLATFORM_LABEL/$MACHINE_ARCH
  release  : $RELEASE_TAG ($CAIRN_PACKAGE)
  launcher : $INSTALL_DIR/cairn
  data     : $DATA_DIR
  node     : v$CAIRN_MANAGED_NODE_VERSION ($NODE_PACKAGE)
  verify   : $VERIFY_INSTALL
PLAN

if [[ "$DRY_RUN" == 1 ]]; then
  if command -v git >/dev/null 2>&1; then
    printf '  git      : %s\n' "$(git --version 2>/dev/null || printf installed)"
  else
    printf '  git      : install with the detected system package manager\n'
  fi
  printf '\n(dry run; no downloads or files changed)\n'
  exit 0
fi

need curl
need tar
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cairn-install.XXXXXX")"

download() {
  local url="$1" destination="$2"
  local -a options=(--fail --silent --show-error --location --retry 3 --retry-delay 1 --retry-connrefused --speed-limit 1 --speed-time 30)
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
  local archive="$1" manifest="$2" filename="$3" expected actual
  expected="$(awk -v file="$filename" '$2 == file || $2 == "*" file { print $1; exit }' "$manifest")"
  [[ -n "$expected" ]] || die "checksum for $filename is missing"
  actual="$(sha256_file "$archive")"
  [[ "$expected" == "$actual" ]] || die "checksum mismatch for $filename"
}

validate_tar_archive() {
  local archive="$1"
  tar -tzf "$archive" | awk '
    BEGIN { valid = 1 }
    /^\// { valid = 0 }
    /(^|\/)\.\.($|\/)/ { valid = 0 }
    END { exit valid ? 0 : 1 }
  ' || die "archive contains an unsafe path: $(basename "$archive")"
}

run_as_root() {
  if [[ "$(id -u)" == 0 ]]; then
    "$@"
    return
  fi
  command -v sudo >/dev/null 2>&1 || die "installing Git requires root or sudo"
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    sudo "$@"
  elif sudo -n true >/dev/null 2>&1; then
    sudo -n "$@"
  else
    die "installing Git requires an interactive sudo prompt; install Git and rerun"
  fi
}

install_git() {
  command -v git >/dev/null 2>&1 && return
  step "Installing Git"
  if [[ "$PLATFORM" == darwin ]]; then
    if ! command -v brew >/dev/null 2>&1; then
      local brew_script="$TMP_DIR/install-homebrew.sh"
      download "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh" "$brew_script"
      [[ "$(head -c 2 "$brew_script")" == '#!' ]] || die "invalid Homebrew installer response"
      /bin/bash "$brew_script"
      if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
      fi
    fi
    command -v brew >/dev/null 2>&1 || die "Homebrew installation did not expose brew"
    brew install git
  elif command -v apt-get >/dev/null 2>&1; then
    run_as_root apt-get update
    run_as_root apt-get install -y git
  elif command -v dnf >/dev/null 2>&1; then
    run_as_root dnf install -y git
  elif command -v yum >/dev/null 2>&1; then
    run_as_root yum install -y git
  elif command -v apk >/dev/null 2>&1; then
    run_as_root apk add git
  elif command -v pacman >/dev/null 2>&1; then
    run_as_root pacman -Sy --noconfirm git
  elif command -v zypper >/dev/null 2>&1; then
    run_as_root zypper --non-interactive install git
  else
    die "Git is missing and no supported package manager was found"
  fi
  command -v git >/dev/null 2>&1 || die "Git installation completed but git is not on PATH"
}

install_node() {
  if [[ -x "$NODE_BIN" && "$("$NODE_BIN" --version 2>/dev/null || true)" == "v$CAIRN_MANAGED_NODE_VERSION" ]]; then
    return
  fi
  step "Installing managed Node.js v$CAIRN_MANAGED_NODE_VERSION"
  local archive="$TMP_DIR/$NODE_PACKAGE" checksums="$TMP_DIR/node-checksums.txt"
  download "$NODE_BASE/$NODE_PACKAGE" "$archive"
  download "$NODE_BASE/SHASUMS256.txt" "$checksums"
  verify_checksum "$archive" "$checksums" "$NODE_PACKAGE"
  validate_tar_archive "$archive"

  local runtime_parent stage backup
  runtime_parent="$(dirname "$NODE_RUNTIME_DIR")"
  stage="$runtime_parent/.node-install-$$"
  backup="$runtime_parent/.node-backup-$$"
  mkdir -p "$runtime_parent"
  rm -rf -- "$stage" "$backup"
  mkdir -p "$stage"
  tar -xzf "$archive" -C "$stage" --strip-components=1
  [[ -x "$stage/bin/node" ]] || die "managed Node.js archive is missing bin/node"
  [[ "$("$stage/bin/node" --version)" == "v$CAIRN_MANAGED_NODE_VERSION" ]] || die "managed Node.js version is invalid"
  if [[ -e "$NODE_RUNTIME_DIR" ]]; then mv "$NODE_RUNTIME_DIR" "$backup"; fi
  if ! mv "$stage" "$NODE_RUNTIME_DIR"; then
    [[ ! -e "$backup" ]] || mv "$backup" "$NODE_RUNTIME_DIR"
    die "could not install managed Node.js"
  fi
  rm -rf -- "$backup"
}

validate_cairn_package() {
  local package_dir="$1" version protocol build_id marker expected_marker
  [[ "$(head -n 1 "$package_dir/cairn.mjs" 2>/dev/null || true)" == '#!/usr/bin/env node' ]] || die "invalid Cairn TUI executable"
  [[ -f "$package_dir/cairn-terminal-host" ]] || die "Cairn terminal host is missing"
  version="$(tr -d '\r\n' < "$package_dir/VERSION" 2>/dev/null || true)"
  protocol="$(tr -d '\r\n' < "$package_dir/PROTOCOL_VERSION" 2>/dev/null || true)"
  build_id="$(tr -d '\r\n' < "$package_dir/HOST_BUILD_ID" 2>/dev/null || true)"
  marker="$(tr -d '\r\n' < "$package_dir/PACKAGE" 2>/dev/null || true)"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid Cairn package version"
  [[ "$protocol" =~ ^[0-9]+$ ]] || die "invalid terminal-host protocol version"
  [[ "$build_id" =~ ^[0-9a-f]{16}$ ]] || die "invalid terminal-host build id"
  expected_marker="cairn-tui $version $PLATFORM $CAIRN_ARCH"
  [[ "$marker" == "$expected_marker" ]] || die "incompatible Cairn package metadata: $marker"
  if [[ "$RELEASE_TAG" != latest && "$RELEASE_TAG" != "v$version" ]]; then
    die "package version $version does not match requested release $RELEASE_TAG"
  fi
  printf '%s' "$version"
}

install_git
install_node

step "Downloading Cairn TUI"
CAIRN_ARCHIVE="$TMP_DIR/$CAIRN_PACKAGE"
CAIRN_CHECKSUMS="$TMP_DIR/cairn-checksums.txt"
download "$CAIRN_BASE/$CAIRN_PACKAGE" "$CAIRN_ARCHIVE"
download "$CAIRN_BASE/cairn-tui-checksums.txt" "$CAIRN_CHECKSUMS"
verify_checksum "$CAIRN_ARCHIVE" "$CAIRN_CHECKSUMS" "$CAIRN_PACKAGE"
validate_tar_archive "$CAIRN_ARCHIVE"

EXTRACTED="$TMP_DIR/cairn-package"
mkdir "$EXTRACTED"
tar -xzf "$CAIRN_ARCHIVE" -C "$EXTRACTED"
PACKAGE_VERSION="$(validate_cairn_package "$EXTRACTED")"
chmod 755 "$EXTRACTED/cairn.mjs" "$EXTRACTED/cairn-terminal-host"

VERSIONS_DIR="$DATA_DIR/tui/versions"
PACKAGE_DIR="$VERSIONS_DIR/$PACKAGE_VERSION"
STAGE_DIR="$VERSIONS_DIR/.cairn-install-$$"
BACKUP_DIR="$VERSIONS_DIR/.cairn-backup-$$"
mkdir -p "$VERSIONS_DIR"
rm -rf -- "$STAGE_DIR" "$BACKUP_DIR"
mkdir "$STAGE_DIR"
cp -R "$EXTRACTED/." "$STAGE_DIR/"

if [[ -e "$PACKAGE_DIR" ]]; then mv "$PACKAGE_DIR" "$BACKUP_DIR"; fi
if ! mv "$STAGE_DIR" "$PACKAGE_DIR"; then
  [[ ! -e "$BACKUP_DIR" ]] || mv "$BACKUP_DIR" "$PACKAGE_DIR"
  die "could not install Cairn package"
fi
INSTALLED_VERSION="$("$NODE_BIN" "$PACKAGE_DIR/cairn.mjs" --version || true)"
if [[ "$INSTALLED_VERSION" != "cairn $PACKAGE_VERSION" ]]; then
  rm -rf -- "$PACKAGE_DIR"
  [[ ! -e "$BACKUP_DIR" ]] || mv "$BACKUP_DIR" "$PACKAGE_DIR"
  die "installed Cairn package failed version verification (got: ${INSTALLED_VERSION:-no output})"
fi
rm -rf -- "$BACKUP_DIR"

step "Installing Cairn launcher"
mkdir -p "$INSTALL_DIR"
TARGET="$INSTALL_DIR/cairn"
if [[ -e "$TARGET" ]]; then ACTION="Updated"; else ACTION="Installed"; fi
LAUNCHER_TEMP="$INSTALL_DIR/.cairn-install-$$"
printf -v QUOTED_DATA '%q' "$DATA_DIR"
printf -v QUOTED_NODE '%q' "$NODE_BIN"
printf -v QUOTED_TUI '%q' "$PACKAGE_DIR/cairn.mjs"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf 'export CAIRN_DATA_DIR=%s\n' "$QUOTED_DATA"
  printf 'exec %s %s "$@"\n' "$QUOTED_NODE" "$QUOTED_TUI"
} > "$LAUNCHER_TEMP"
chmod 755 "$LAUNCHER_TEMP"
mv -f "$LAUNCHER_TEMP" "$TARGET"

update_path() {
  [[ "$SKIP_PATH_UPDATE" == 0 ]] || return 0
  case ":${PATH:-}:" in *":$INSTALL_DIR:"*) return 0 ;; esac
  local shell_name rc quoted_dir
  shell_name="$(basename "${SHELL:-}")"
  case "$shell_name" in
    zsh) rc="$HOME/.zshrc" ;;
    bash) if [[ "$PLATFORM" == darwin ]]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
    *) rc="$HOME/.profile" ;;
  esac
  if [[ -f "$rc" ]] && grep -F "$PATH_MARKER_BEGIN" "$rc" >/dev/null 2>&1; then
    return 0
  fi
  printf -v quoted_dir '%q' "$INSTALL_DIR"
  {
    printf '\n%s\n' "$PATH_MARKER_BEGIN"
    printf "export PATH=%s:\"\$PATH\"\n" "$quoted_dir"
    printf '%s\n' "$PATH_MARKER_END"
  } >> "$rc"
  PATH_NOTE="Added $INSTALL_DIR to PATH in $rc; open a new terminal."
}

PATH_NOTE=""
update_path
if [[ "$VERIFY_INSTALL" == 1 ]]; then
  [[ "$("$TARGET" --version 2>/dev/null || true)" == "cairn $PACKAGE_VERSION" ]] || die "installed launcher verification failed"
fi

printf '\n%s Cairn TUI %s.\n' "$ACTION" "$PACKAGE_VERSION"
printf '  command: %s\n' "$TARGET"
printf '  package: %s\n' "$PACKAGE_DIR"
printf '  node:    %s\n' "$NODE_BIN"
if [[ -n "$PATH_NOTE" ]]; then
  printf '  note:    %s\n' "$PATH_NOTE"
elif [[ ":${PATH:-}:" != *":$INSTALL_DIR:"* ]]; then
  printf '  note:    Add %s to PATH before running cairn.\n' "$INSTALL_DIR"
fi
printf 'Run: cairn\n'
