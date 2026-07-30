#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./install.sh [options] [-- <zig build args>]

Build maai and install it to ~/.local/bin by default.

Options:
  --prefix DIR          Install under DIR/bin (default: $PREFIX or ~/.local)
  --bindir DIR          Install directly into DIR (default: <prefix>/bin)
  --optimize MODE       Zig optimize mode (default: $OPTIMIZE or ReleaseFast)
  -Doptimize=MODE       Same as --optimize MODE
  --debug               Shortcut for --optimize Debug
  --skip-deps-check     Do not preflight-check system build dependencies
  --help                Show this help

Environment:
  PREFIX=/path          Default install prefix
  BINDIR=/path          Default binary directory
  OPTIMIZE=MODE         Default Zig optimize mode

Examples:
  ./install.sh
  ./install.sh --optimize ReleaseSafe
  ./install.sh --bindir "$HOME/bin"
EOF
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

prefix="${PREFIX:-$HOME/.local}"
bindir="${BINDIR:-$prefix/bin}"
optimize="${OPTIMIZE:-ReleaseFast}"
binary="maai"
extra_zig_args=()
check_deps=true

# True if any one of the '|'-separated pkg-config names in $1 is installed.
pkg_config_any() {
  local IFS='|' name
  for name in $1; do
    if pkg-config --exists "$name"; then return 0; fi
  done
  return 1
}

check_dependencies() {
  local missing_tools=()
  local missing_pkgs=()

  for tool in pkg-config wayland-scanner install; do
    command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
  done

  if command -v pkg-config >/dev/null 2>&1; then
    # Alternatives, '|'-separated, for the packages whose pkg-config name is not
    # settled across distributions: utf8proc installs libutf8proc.pc upstream (so
    # that is what Debian/Ubuntu and Homebrew ship), but some distributions and
    # vendored builds name it utf8proc.pc. Checking only one name reported
    # libutf8proc-dev as missing when it was installed all along.
    for pkg in \
      wayland-protocols \
      wayland-client \
      wayland-egl \
      egl \
      glesv2 \
      fcft \
      pixman-1 \
      xkbcommon \
      'libutf8proc|utf8proc'
    do
      pkg_config_any "$pkg" || missing_pkgs+=("$pkg")
    done
  fi

  if ((${#missing_tools[@]} || ${#missing_pkgs[@]})); then
    echo "error: missing build dependencies" >&2
    ((${#missing_tools[@]})) && echo "  tools: ${missing_tools[*]}" >&2
    ((${#missing_pkgs[@]})) && echo "  pkg-config packages: ${missing_pkgs[*]}" >&2
    cat >&2 <<'EOF'

Install the corresponding development packages for your distribution, then rerun
./install.sh. On Debian/Ubuntu, they are typically named like:
  pkg-config libwayland-bin wayland-protocols libwayland-dev libegl1-mesa-dev \
  libgles2-mesa-dev libfcft-dev libpixman-1-dev libxkbcommon-dev libutf8proc-dev
EOF
    exit 1
  fi
}

while (($#)); do
  case "$1" in
    --prefix)
      [[ $# -ge 2 ]] || { echo "error: --prefix requires a value" >&2; exit 2; }
      prefix="${2%/}"
      bindir="$prefix/bin"
      shift 2
      ;;
    --prefix=*)
      prefix="${1#--prefix=}"
      prefix="${prefix%/}"
      bindir="$prefix/bin"
      shift
      ;;
    --bindir)
      [[ $# -ge 2 ]] || { echo "error: --bindir requires a value" >&2; exit 2; }
      bindir="${2%/}"
      shift 2
      ;;
    --bindir=*)
      bindir="${1#--bindir=}"
      bindir="${bindir%/}"
      shift
      ;;
    --optimize)
      [[ $# -ge 2 ]] || { echo "error: --optimize requires a value" >&2; exit 2; }
      optimize="$2"
      shift 2
      ;;
    --optimize=*)
      optimize="${1#--optimize=}"
      shift
      ;;
    -Doptimize=*)
      optimize="${1#-Doptimize=}"
      shift
      ;;
    --debug)
      optimize="Debug"
      shift
      ;;
    --skip-deps-check)
      check_deps=false
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      extra_zig_args+=("$@")
      break
      ;;
    *)
      echo "error: unknown option: $1" >&2
      echo "Run './install.sh --help' for usage." >&2
      exit 2
      ;;
  esac
done

if command -v zig >/dev/null 2>&1; then
  zig_cmd=(zig)
elif command -v mise >/dev/null 2>&1; then
  zig_cmd=(mise exec -- zig)
else
  echo "error: 'zig' was not found in PATH." >&2
  echo "Install Zig 0.16.0, or install mise and run 'mise install' in this repo." >&2
  exit 127
fi

if [[ "$check_deps" == true ]]; then
  check_dependencies
fi

echo "==> Building $binary (-Doptimize=$optimize)"
"${zig_cmd[@]}" build -Doptimize="$optimize" "${extra_zig_args[@]}"

src="zig-out/bin/$binary"
if [[ ! -x "$src" ]]; then
  echo "error: expected build output '$src' was not created" >&2
  exit 1
fi

echo "==> Installing $binary to $bindir"
install -d "$bindir"
install -m 0755 "$src" "$bindir/$binary"

cat <<EOF
==> Done: $bindir/$binary
EOF

case ":${PATH:-}:" in
  *":$bindir:"*) ;;
  *)
    cat <<EOF

Note: '$bindir' is not currently in PATH.
Add this to your shell config if needed:
  export PATH="$bindir:\$PATH"
EOF
    ;;
esac
