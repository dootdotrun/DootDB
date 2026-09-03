#!/usr/bin/env bash
# Install the pinned Zig toolchain for Doot and verify its hash.
# Idempotent: safe to re-run.
#
# Usage: toolchain/setup.sh [install-prefix]      (default: /projects/toolchain)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${1:-/projects/toolchain}"
ZIG_DIR="$PREFIX/zig"

# shellcheck disable=SC1091
source "$HERE/zig.lock"

echo "==> Doot toolchain: Zig $ZIG_VERSION -> $ZIG_DIR"

if [ -x "$ZIG_DIR/zig" ] && [ "$("$ZIG_DIR/zig" version)" = "$ZIG_VERSION" ]; then
  echo "    already installed"
else
  mkdir -p "$PREFIX/dl" "$ZIG_DIR"
  cd "$PREFIX/dl"

  echo "==> downloading $ZIG_TARBALL_URL"
  curl -fsSLo zig.tar.xz "$ZIG_TARBALL_URL"

  actual="$(sha256sum zig.tar.xz | cut -d' ' -f1)"
  if [ "$actual" != "$ZIG_TARBALL_SHA256" ]; then
    echo "!!! sha256 mismatch" >&2
    echo "    expected $ZIG_TARBALL_SHA256" >&2
    echo "    actual   $actual" >&2
    exit 1
  fi
  echo "    sha256 verified"

  # xz is not present on every image; python's lzma always is.
  if command -v xz >/dev/null 2>&1; then
    tar -xJf zig.tar.xz -C "$ZIG_DIR" --strip-components=1
  else
    python3 -c "
import lzma, shutil
with lzma.open('zig.tar.xz') as f, open('zig.tar','wb') as o:
    shutil.copyfileobj(f, o)
"
    tar -xf zig.tar -C "$ZIG_DIR" --strip-components=1
    rm -f zig.tar
  fi
  rm -f zig.tar.xz
  echo "    extracted $("$ZIG_DIR/zig" version)"
fi

# ---------------------------------------------------------------------------
# Prove the toolchain works: the repo's actual stdlib use is std.Io.Threaded
# (outbound HTTPS, Argon2id), which must compile and run.
# ---------------------------------------------------------------------------
echo "==> verifying"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/verify.zig" <<'EOF'
const std = @import("std");
pub fn main() !void {
    var t: std.Io.Threaded = .init_single_threaded;
    const io = t.io();
    try io.sleep(.fromMilliseconds(1), .awake);
    std.debug.print("std.Io.Threaded compiles and runs\n", .{});
}
EOF
(cd "$work" && "$ZIG_DIR/zig" build-exe verify.zig -O ReleaseFast && ./verify)

if [ -w /usr/local/bin ]; then
  ln -sf "$ZIG_DIR/zig" /usr/local/bin/zig
  echo "==> linked /usr/local/bin/zig"
fi

echo "==> Zig $("$ZIG_DIR/zig" version) ready"
