#!/bin/sh
set -eu

name="endlessnet-client"
install_dir="${ENDLESSNET_INSTALL_DIR:-/usr/local/bin}"
server_url="${ENDLESSNET_SERVER_URL:-https://api.endlessnet.ru}"
auth_token="${ENDLESSNET_AUTH_TOKEN:-}"
network="${ENDLESSNET_NETWORK:-}"
hostname_value="${ENDLESSNET_HOSTNAME:-$(hostname)}"
mode="${ENDLESSNET_MODE:-server}"
join_token="${ENDLESSNET_JOIN_TOKEN:-}"
join_token_file="${ENDLESSNET_JOIN_TOKEN_FILE:-}"
start_service=1
release_base="${ENDLESSNET_RELEASE_BASE_URL:-}"
download_url="${ENDLESSNET_DOWNLOAD_URL:-}"
go_package="${ENDLESSNET_GO_PACKAGE:-}"
apt_repo="${ENDLESSNET_APT_REPO:-https://apt.unng.ru/apt}"
apt_key_url="${ENDLESSNET_APT_KEY_URL:-https://apt.unng.ru/apt/unng.gpg}"
apt_keyring="${ENDLESSNET_APT_KEYRING:-/etc/apt/keyrings/unng.gpg}"
apt_source="${ENDLESSNET_APT_SOURCE_LIST:-/etc/apt/sources.list.d/unng.list}"

usage() {
  cat <<EOF
Usage:
  install.sh [--join-token TOKEN | --join-token-file PATH] [options]

Options:
  --join-token TOKEN       enroll this machine with a one-time node join token
  --join-token-file PATH   read the join token from PATH, or '-' for stdin
  --server URL             EndlessNet API URL (default: $server_url)
  --hostname NAME          hostname to register (default: $hostname_value)
  --mode MODE              enrollment mode tag (default: $mode)
  --no-start               install only; do not start the system service
  -h, --help               show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --join-token)
      [ "$#" -ge 2 ] || { echo "--join-token requires a value" >&2; exit 1; }
      join_token="$2"
      shift 2
      ;;
    --join-token=*)
      join_token="${1#*=}"
      shift
      ;;
    --join-token-file)
      [ "$#" -ge 2 ] || { echo "--join-token-file requires a value" >&2; exit 1; }
      join_token_file="$2"
      shift 2
      ;;
    --join-token-file=*)
      join_token_file="${1#*=}"
      shift
      ;;
    --server)
      [ "$#" -ge 2 ] || { echo "--server requires a value" >&2; exit 1; }
      server_url="$2"
      shift 2
      ;;
    --server=*)
      server_url="${1#*=}"
      shift
      ;;
    --hostname)
      [ "$#" -ge 2 ] || { echo "--hostname requires a value" >&2; exit 1; }
      hostname_value="$2"
      shift 2
      ;;
    --hostname=*)
      hostname_value="${1#*=}"
      shift
      ;;
    --mode)
      [ "$#" -ge 2 ] || { echo "--mode requires a value" >&2; exit 1; }
      mode="$2"
      shift 2
      ;;
    --mode=*)
      mode="${1#*=}"
      shift
      ;;
    --no-start)
      start_service=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

server_url="${server_url%/}"
if [ -n "$join_token" ] && [ -n "$join_token_file" ]; then
  echo "Use either --join-token or --join-token-file, not both" >&2
  exit 1
fi

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
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools iproute2 "$name"
}

start_linux_service() {
  [ "$os" = "linux" ] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  as_root systemctl daemon-reload
  if command -v systemd-tmpfiles >/dev/null 2>&1; then
    as_root systemd-tmpfiles --create /usr/lib/tmpfiles.d/$name.conf || true
  fi
  as_root systemctl enable --now $name.service
}

generate_idempotency_key() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]'
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    tr -d '-' < /proc/sys/kernel/random/uuid
  else
    date +%s%N
  fi
}

service_enroll_args() {
  token_file="$1"
  idempotency_key_arg="$2"
  set -- "$installed_path" service enroll \
    --server "$server_url" \
    --hostname "$hostname_value" \
    --mode "$mode"
  if [ -n "$token_file" ]; then
    set -- "$@" --join-token-file "$token_file"
  fi
  if [ -n "$idempotency_key_arg" ]; then
    set -- "$@" --idempotency-key "$idempotency_key_arg"
  fi
  as_root "$@"
}

client_up_args() {
  token_file="$1"
  idempotency_key_arg="$2"
  set -- "$installed_path" up \
    --server "$server_url" \
    --hostname "$hostname_value"
  if [ -n "$token_file" ]; then
    set -- "$@" --join-token-file "$token_file"
  fi
  if [ -n "$mode" ]; then
    set -- "$@" --tag "mode:$mode"
  fi
  if [ -n "$idempotency_key_arg" ]; then
    set -- "$@" --idempotency-key "$idempotency_key_arg"
  fi
  "$@"
}

enroll_installed_client() {
  [ "$start_service" = "1" ] || { echo "--no-start cannot be used with enrollment" >&2; exit 1; }

  idempotency_key=""
  if [ -n "$join_token" ] || [ -n "$join_token_file" ]; then
    idempotency_key="$(generate_idempotency_key)"
  fi
  if [ "$os" = "linux" ] && command -v systemctl >/dev/null 2>&1; then
    if [ -n "$join_token_file" ]; then
      service_enroll_args "$join_token_file" "$idempotency_key"
    elif [ -n "$join_token" ]; then
      printf '%s' "$join_token" | service_enroll_args - "$idempotency_key"
    else
      service_enroll_args "" ""
    fi
    return
  fi

  if [ -n "$join_token_file" ]; then
    client_up_args "$join_token_file" "$idempotency_key"
  elif [ -n "$join_token" ]; then
    printf '%s' "$join_token" | client_up_args - "$idempotency_key"
  else
    client_up_args "" ""
  fi
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

if [ "$start_service" = "1" ]; then
  start_linux_service
fi

if [ "$start_service" = "1" ]; then
  enroll_installed_client
elif [ -n "$join_token" ] || [ -n "$join_token_file" ]; then
  echo "--no-start cannot be used with enrollment" >&2
  exit 1
fi

cat <<EOF
EndlessNet client installed:
  $installed_path

EOF

if [ "$start_service" != "1" ] && [ -z "$join_token" ] && [ -z "$join_token_file" ]; then
  cat <<EOF
Next:
  Run $installed_path up --server "$server_url" on this host to create an interactive enrollment request.

For unattended enrollment with a join token:
  curl -fsSL https://endlessnet.ru/install.sh | sh -s -- --join-token '<join-token>'
EOF
fi

if [ "${ENDLESSNET_AUTO_LOGIN:-0}" = "1" ] && [ -n "$server_url" ] && [ -n "$auth_token" ]; then
  printf '%s\n' "$auth_token" | "$installed_path" login --server "$server_url" --token-file -
fi

if [ "${ENDLESSNET_AUTO_UP:-0}" = "1" ] && [ -n "$network" ]; then
  "$installed_path" up --network "$network" --hostname "$hostname_value" --output ./wg-endlessnet.conf
fi
