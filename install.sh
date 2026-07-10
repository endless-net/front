#!/bin/sh
set -eu

name="endlessnet-client"
install_dir="${ENDLESSNET_INSTALL_DIR:-/usr/local/bin}"
server_url="${ENDLESSNET_SERVER_URL:-}"
auth_token="${ENDLESSNET_AUTH_TOKEN:-}"
network="${ENDLESSNET_NETWORK:-}"
hostname_value="${ENDLESSNET_HOSTNAME:-$(hostname)}"
release_base="${ENDLESSNET_RELEASE_BASE_URL:-}"
download_url="${ENDLESSNET_DOWNLOAD_URL:-}"
go_package="${ENDLESSNET_GO_PACKAGE:-}"
apt_repo="${ENDLESSNET_APT_REPO:-https://apt.unng.ru/apt}"
apt_key_url="${ENDLESSNET_APT_KEY_URL:-https://apt.unng.ru/apt/unng.gpg}"
apt_keyring="${ENDLESSNET_APT_KEYRING:-/etc/apt/keyrings/unng.gpg}"
apt_source="${ENDLESSNET_APT_SOURCE_LIST:-/etc/apt/sources.list.d/unng.list}"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"

case "$os" in
  linux|darwin) ;;
  *) echo "Unsupported OS: $os" >&2; exit 1 ;;
esac

case "$arch" in
  x86_64|amd64) arch="amd64" ;;
  aarch64|arm64) arch="arm64" ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac

tmp="${TMPDIR:-/tmp}/endlessnet-install.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

bin="$tmp/$name"

fetch() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    echo "curl or wget is required" >&2
    exit 1
  fi
}

as_root() {
  if [ "$(id -u)" = "0" ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "Root privileges or sudo are required" >&2
    exit 1
  fi
}

install_bin() {
  src="$1"
  mkdir -p "$install_dir" 2>/dev/null || true
  if [ -w "$install_dir" ]; then
    install -m 0755 "$src" "$install_dir/$name"
  elif command -v sudo >/dev/null 2>&1; then
    sudo install -m 0755 "$src" "$install_dir/$name"
  else
    echo "Cannot write to $install_dir and sudo is not available" >&2
    exit 1
  fi
}

install_apt_package() {
  command -v apt-get >/dev/null 2>&1 || { echo "apt-get is required for APT installs" >&2; exit 1; }

  key_tmp="$tmp/unng.gpg"
  source_tmp="$tmp/unng.list"
  fetch "$apt_key_url" "$key_tmp"
  printf 'deb [signed-by=%s] %s stable main\n' "$apt_keyring" "$apt_repo" > "$source_tmp"

  as_root install -d -m 0755 "$(dirname "$apt_keyring")"
  as_root install -m 0644 "$key_tmp" "$apt_keyring"
  as_root install -d -m 0755 "$(dirname "$apt_source")"
  as_root install -m 0644 "$source_tmp" "$apt_source"
  as_root apt-get update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$name"
}

installed_path="$install_dir/$name"

if [ -n "$download_url" ]; then
  archive="$tmp/endlessnet-download"
  fetch "$download_url" "$archive"
  case "$download_url" in
    *.tar.gz|*.tgz)
      tar -xzf "$archive" -C "$tmp"
      found="$(find "$tmp" -type f -name "$name" | head -n 1)"
      [ -n "$found" ] || { echo "$name not found in archive" >&2; exit 1; }
      [ "$found" = "$bin" ] || cp "$found" "$bin"
      ;;
    *)
      cp "$archive" "$bin"
      ;;
  esac
elif [ -n "$release_base" ]; then
  archive="$tmp/endlessnet.tar.gz"
  fetch "$release_base/${name}_${os}_${arch}.tar.gz" "$archive"
  tar -xzf "$archive" -C "$tmp"
  found="$(find "$tmp" -type f -name "$name" | head -n 1)"
  [ -n "$found" ] || { echo "$name not found in release archive" >&2; exit 1; }
  [ "$found" = "$bin" ] || cp "$found" "$bin"
elif [ -n "$go_package" ]; then
  command -v go >/dev/null 2>&1 || { echo "go is required for ENDLESSNET_GO_PACKAGE installs" >&2; exit 1; }
  GOBIN="$tmp" go install "$go_package"
elif [ "$os" = "linux" ] && command -v apt-get >/dev/null 2>&1; then
  install_apt_package
  installed_path="$(command -v "$name" || printf '%s' "$name")"
else
  cat >&2 <<'EOF'
EndlessNet install source is not configured.

On Debian/Ubuntu, the installer uses the UNNG APT repository by default.

Set one of:
  ENDLESSNET_DOWNLOAD_URL      direct binary or tar.gz URL
  ENDLESSNET_RELEASE_BASE_URL  release directory with endlessnet-client_<os>_<arch>.tar.gz
  ENDLESSNET_GO_PACKAGE        Go package, for example github.com/<owner>/<repo>/cmd/endlessnet-client@latest
EOF
  exit 1
fi

if [ -f "$bin" ]; then
  chmod +x "$bin"
  install_bin "$bin"
fi

cat <<EOF
EndlessNet client installed:
  $installed_path

Next:
  Create a one-time join token in the HttpOnly-cookie admin console, then run:
  $name up --server "${server_url:-<server-url>}" --join-token-file <owner-only-token-file> --network "${network:-<network>}" --hostname "$hostname_value" --output ./wg-endlessnet.conf
EOF

if [ "${ENDLESSNET_AUTO_LOGIN:-0}" = "1" ] && [ -n "$server_url" ] && [ -n "$auth_token" ]; then
  printf '%s\n' "$auth_token" | "$installed_path" login --server "$server_url" --token-file -
fi

if [ "${ENDLESSNET_AUTO_UP:-0}" = "1" ] && [ -n "$network" ]; then
  "$installed_path" up --network "$network" --hostname "$hostname_value" --output ./wg-endlessnet.conf
fi
