#!/bin/sh
set -eu

REPOSITORY="balim-eu/tek"
RELEASES_URL="${TEK_RELEASES_URL:-https://github.com/$REPOSITORY/releases}"
API_URL="${TEK_API_URL:-https://api.github.com/repos/$REPOSITORY}"
INSTALL_DIR="${TEK_INSTALL_DIR:-$HOME/.local/bin}"

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'tek-install: %s\n' "$*" >&2
  exit 1
}

detect_target() {
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Linux) os="linux" ;;
    Darwin) os="macos" ;;
    *) fail "unsupported operating system: $os. Download tek manually from $RELEASES_URL" ;;
  esac

  case "$arch" in
    x86_64 | amd64) arch="x64" ;;
    arm64 | aarch64) arch="arm64" ;;
    *) fail "unsupported CPU architecture: $arch. Download tek manually from $RELEASES_URL" ;;
  esac

  if [ "$os" = "macos" ] && [ "$arch" = "x64" ] && [ "$(sysctl -n sysctl.proc_translated 2> /dev/null || echo 0)" = "1" ]; then
    arch="arm64"
  fi

  printf '%s-%s' "$os" "$arch"
}

download() {
  if command -v curl > /dev/null 2>&1; then
    curl -fsSL --retry 3 "$1" -o "$2"
  elif command -v wget > /dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    fail "curl or wget is required"
  fi
}

sha256() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  elif command -v shasum > /dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  else
    fail "sha256sum or shasum is required"
  fi
}

print_path_help() {
  case "$(basename "${SHELL:-sh}")" in
    zsh)
      profile="$HOME/.zshrc"
      line="export PATH=\"$INSTALL_DIR:\$PATH\""
      ;;
    bash)
      if [ "$(uname -s)" = "Darwin" ]; then profile="$HOME/.bash_profile"; else profile="$HOME/.bashrc"; fi
      line="export PATH=\"$INSTALL_DIR:\$PATH\""
      ;;
    fish)
      profile="$HOME/.config/fish/config.fish"
      line="fish_add_path $INSTALL_DIR"
      ;;
    *)
      profile="$HOME/.profile"
      line="export PATH=\"$INSTALL_DIR:\$PATH\""
      ;;
  esac

  say ""
  say "$INSTALL_DIR is not on your PATH. Add it by running:"
  say ""
  say "  echo '$line' >> $profile"
  say "  source $profile"
}

main() {
  version="${1:-latest}"
  target="$(detect_target)"
  asset="tek-$target.tar.gz"

  command -v tar > /dev/null 2>&1 || fail "tar is required"

  tmp="$(mktemp -d 2> /dev/null || mktemp -d -t tek)"
  trap 'rm -rf "$tmp"' EXIT INT TERM

  if [ "$version" = "pre-release" ] || [ "$version" = "--pre-release" ]; then
    download "$API_URL/releases?per_page=1" "$tmp/releases.json" || fail "unable to look up the newest release"
    version="$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$tmp/releases.json" | head -n 1)"
    [ -n "$version" ] || fail "no release found at $RELEASES_URL"
  fi

  if [ "$version" = "latest" ]; then
    base="$RELEASES_URL/latest/download"
  else
    base="$RELEASES_URL/download/$version"
  fi

  say "Downloading tek $version for $target..."
  download "$base/$asset" "$tmp/$asset" || fail "unable to download $base/$asset"
  download "$base/SHA256SUMS" "$tmp/SHA256SUMS" || fail "unable to download $base/SHA256SUMS"

  expected="$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1 }' "$tmp/SHA256SUMS")"
  [ -n "$expected" ] || fail "SHA256SUMS does not list $asset"
  actual="$(sha256 "$tmp/$asset")"
  [ "$expected" = "$actual" ] || fail "checksum mismatch for $asset (expected $expected, got $actual)"

  tar -xzf "$tmp/$asset" -C "$tmp"
  [ -f "$tmp/tek" ] || fail "$asset does not contain the tek binary"

  mkdir -p "$INSTALL_DIR"
  staged="$INSTALL_DIR/.tek.tmp"
  trap 'rm -rf "$tmp"; rm -f "$staged"' EXIT INT TERM
  cp "$tmp/tek" "$staged"
  chmod 755 "$staged"
  installed="$("$staged" --version 2> /dev/null)" || fail "the downloaded tek binary does not run on this system"
  mv -f "$staged" "$INSTALL_DIR/tek"

  say "Installed $installed to $INSTALL_DIR/tek"

  found="$(command -v tek 2> /dev/null || true)"
  if [ -n "$found" ] && [ "$found" != "$INSTALL_DIR/tek" ]; then
    say ""
    say "Warning: another tek at $found comes first on your PATH. Remove it with 'rm $found'."
  fi

  case ":$PATH:" in
    *":$INSTALL_DIR:"*) say "Run 'tek --help' to get started." ;;
    *) print_path_help ;;
  esac
}

main "$@"
