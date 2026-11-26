#!/bin/sh
# Installs the prebuilt zqjs CLI from GitHub Releases (macOS / Linux).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ngnsr/zqjs/main/install.sh | sh
#
# Environment variables:
#   ZQJS_VERSION  Release tag to install (e.g. v0.2.0). Defaults to latest release.
#   ZQJS_INSTALL  Destination directory. Defaults to $HOME/.local/bin.

set -eu

REPO="ngnsr/zqjs"
INSTALL_DIR="${ZQJS_INSTALL:-$HOME/.local/bin}"

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

need_cmd curl
need_cmd tar
need_cmd awk

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Darwin) OS_NAME="macos" ;;
    Linux)  OS_NAME="linux" ;;
    *)      fail "unsupported OS '$OS' — download a release archive from https://github.com/$REPO/releases" ;;
esac

case "$ARCH" in
    arm64|aarch64) ARCH_NAME="arm64" ;;
    x86_64|amd64)  ARCH_NAME="x86_64" ;;
    *)             fail "unsupported architecture '$ARCH' — download a release archive from https://github.com/$REPO/releases" ;;
esac

TARGET="${OS_NAME}-${ARCH_NAME}"

if [ -n "${ZQJS_VERSION:-}" ]; then
    TAG="$ZQJS_VERSION"
    case "$TAG" in
        v*) ;;
        *)  TAG="v$TAG" ;;
    esac
else
    LATEST_URL="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")"
    TAG="${LATEST_URL##*/}"
    case "$TAG" in
        v*) ;;
        *)  fail "could not determine latest release tag from $LATEST_URL" ;;
    esac
fi

PKG="zqjs-${TAG}-${TARGET}"
ARCHIVE="${PKG}.tar.gz"
BASE_URL="https://github.com/$REPO/releases/download/$TAG"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

printf 'Downloading zqjs %s (%s)...\n' "$TAG" "$TARGET"
curl -fsSL "$BASE_URL/$ARCHIVE" -o "$TMPDIR/$ARCHIVE"
curl -fsSL "$BASE_URL/SHA256SUMS.txt" -o "$TMPDIR/SHA256SUMS.txt"

EXPECTED="$(awk -v f="$ARCHIVE" '$2 == f || $2 == "*" f { print $1; exit }' "$TMPDIR/SHA256SUMS.txt")"
[ -n "$EXPECTED" ] || fail "checksum entry for $ARCHIVE not found in SHA256SUMS.txt"

if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "$TMPDIR/$ARCHIVE" | awk '{ print $1 }')"
elif command -v shasum >/dev/null 2>&1; then
    ACTUAL="$(shasum -a 256 "$TMPDIR/$ARCHIVE" | awk '{ print $1 }')"
else
    fail "neither sha256sum nor shasum found; cannot verify download"
fi

[ "$ACTUAL" = "$EXPECTED" ] || fail "SHA-256 mismatch for $ARCHIVE (expected $EXPECTED, got $ACTUAL)"

tar -C "$TMPDIR" -xzf "$TMPDIR/$ARCHIVE"
[ -f "$TMPDIR/$PKG/bin/zqjs" ] || fail "archive did not contain $PKG/bin/zqjs"

mkdir -p "$INSTALL_DIR"
cp "$TMPDIR/$PKG/bin/zqjs" "$INSTALL_DIR/zqjs.tmp.$$"
chmod 755 "$INSTALL_DIR/zqjs.tmp.$$"
mv "$INSTALL_DIR/zqjs.tmp.$$" "$INSTALL_DIR/zqjs"

printf 'Installed zqjs %s to %s/zqjs\n' "$TAG" "$INSTALL_DIR"
# shellcheck disable=SC2016
case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *) printf 'Note: add %s to your PATH, e.g.:\n  export PATH="%s:$PATH"\n' "$INSTALL_DIR" "$INSTALL_DIR" ;;
esac
