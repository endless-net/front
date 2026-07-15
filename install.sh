#!/bin/sh
set -eu

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
  --version VERSION        install an exact EndlessNet APT package version
  --sha256 HASH            expected SHA-256 for a direct or release download
  --no-start               install only; do not start the system service
  -h, --help               show this help
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "${tmp:-}" ] && [ -d "$tmp" ]; then
    rm -rf "$tmp"
  fi
}

handle_signal() {
  trap - EXIT HUP INT TERM
  cleanup
  exit 1
}

fetch() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    die "curl or wget is required"
  fi
}

as_root() {
  if [ "$(id -u)" = "0" ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  elif command -v doas >/dev/null 2>&1; then
    doas "$@"
  else
    die "Root privileges, sudo, or doas are required"
  fi
}

validate_sha256() {
  expected="$1"
  [ "${#expected}" -eq 64 ] || die "Expected SHA-256 must contain exactly 64 hexadecimal characters"
  case "$expected" in
    *[!0-9a-fA-F]*) die "Expected SHA-256 must contain exactly 64 hexadecimal characters" ;;
  esac
}

sha256_file() {
  file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    die "sha256sum, shasum, or openssl is required to verify downloaded artifacts"
  fi
}

verify_sha256() {
  file="$1"
  expected="$2"
  validate_sha256 "$expected"
  expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
  actual="$(sha256_file "$file" | tr '[:upper:]' '[:lower:]')"
  [ "$actual" = "$expected" ] || die "SHA-256 mismatch for downloaded EndlessNet artifact"
}

install_bin() {
  src="$1"
  if [ ! -d "$install_dir" ]; then
    if ! mkdir -p "$install_dir" 2>/dev/null; then
      as_root install -d -m 0755 "$install_dir"
    fi
  fi
  if [ -w "$install_dir" ]; then
    install -m 0755 "$src" "$install_dir/$name"
  else
    as_root install -m 0755 "$src" "$install_dir/$name"
  fi
}

detect_platform() {
  command -v uname >/dev/null 2>&1 || die "uname is required"
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  machine_arch="$(uname -m)"

  case "$os" in
    linux|darwin) ;;
    *) die "Unsupported OS: $os" ;;
  esac

  case "$machine_arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "Unsupported architecture: $machine_arch" ;;
  esac
}

validate_apt_platform() {
  [ "$os" = "linux" ] || die "The default APT install is supported only on Linux"
  command -v apt-get >/dev/null 2>&1 || die "apt-get is required for the default EndlessNet install"
  command -v dpkg >/dev/null 2>&1 || die "dpkg is required for the default EndlessNet install"
  [ -r /etc/os-release ] || die "/etc/os-release is required to identify a supported Debian or Ubuntu release"

  distro="$(
    . /etc/os-release
    printf '%s:%s' "${ID:-}" "${VERSION_ID:-}"
  )"
  case "$distro" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;;
    *)
      die "Unsupported Linux release: $distro. Supported releases are Debian 12/13 and Ubuntu 22.04/24.04/26.04 LTS."
      ;;
  esac

  dpkg_arch="$(dpkg --print-architecture)"
  case "$dpkg_arch" in
    amd64|arm64) ;;
    *) die "The UNNG APT repository does not publish packages for architecture: $dpkg_arch" ;;
  esac
}

validate_apt_version() {
  [ -n "$client_version" ] || return 0
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --validate-version "$client_version" >/dev/null 2>&1 || die "Invalid Debian package version: $client_version"
    return 0
  fi
  case "$client_version" in
    [0-9]*) ;;
    *) die "Invalid Debian package version: $client_version" ;;
  esac
  case "$client_version" in
    *[!0-9A-Za-z.+:~_-]*) die "Invalid Debian package version: $client_version" ;;
  esac
}

install_apt_package() {
  validate_apt_platform
  validate_apt_version

  key_tmp="$tmp/unng.gpg"
  source_tmp="$tmp/unng.list"
  fetch "$apt_key_url" "$key_tmp"
  [ -s "$key_tmp" ] || die "Downloaded UNNG APT keyring is empty"
  printf 'deb [signed-by=%s] %s stable main\n' "$apt_keyring" "$apt_repo" > "$source_tmp"

  as_root install -d -m 0755 "$(dirname "$apt_keyring")"
  as_root install -m 0644 "$key_tmp" "$apt_keyring"
  as_root install -d -m 0755 "$(dirname "$apt_source")"
  as_root install -m 0644 "$source_tmp" "$apt_source"
  as_root apt-get update

  package_spec="$name"
  if [ -n "$client_version" ]; then
    package_spec="$name=$client_version"
  fi
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    wireguard-tools iproute2 "$apt_keyring_package" "$package_spec"
}

extract_client_archive() {
  archive="$1"
  command -v tar >/dev/null 2>&1 || die "tar is required to install an EndlessNet archive"
  member_count="$(tar -tzf "$archive" | grep -Fxc "$name" || true)"
  [ "$member_count" = "1" ] || die "The release archive must contain exactly one top-level $name file"
  tar -xOzf "$archive" "$name" > "$bin"
  [ -s "$bin" ] || die "The extracted $name binary is empty"
}

start_linux_service() {
  [ "$os" = "linux" ] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  as_root systemctl daemon-reload
  if command -v systemd-tmpfiles >/dev/null 2>&1; then
    as_root systemd-tmpfiles --create "/usr/lib/tmpfiles.d/$name.conf" || true
  fi
  as_root systemctl enable --now "$name.service"
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
  [ "$start_service" = "1" ] || die "--no-start cannot be used with enrollment"

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

main() {
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
  artifact_sha256="${ENDLESSNET_ARTIFACT_SHA256:-}"
  client_version="${ENDLESSNET_VERSION:-}"
  apt_repo="${ENDLESSNET_APT_REPO:-https://apt.unng.ru/apt}"
  apt_key_url="${ENDLESSNET_APT_KEY_URL:-https://apt.unng.ru/apt/unng.gpg}"
  apt_keyring="${ENDLESSNET_APT_KEYRING:-/usr/share/keyrings/unng-archive-keyring.gpg}"
  apt_keyring_package="${ENDLESSNET_APT_KEYRING_PACKAGE:-unng-archive-keyring}"
  apt_source="${ENDLESSNET_APT_SOURCE_LIST:-/etc/apt/sources.list.d/unng.list}"
  tmp=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --join-token)
        [ "$#" -ge 2 ] || die "--join-token requires a value"
        join_token="$2"
        shift 2
        ;;
      --join-token=*)
        join_token="${1#*=}"
        shift
        ;;
      --join-token-file)
        [ "$#" -ge 2 ] || die "--join-token-file requires a value"
        join_token_file="$2"
        shift 2
        ;;
      --join-token-file=*)
        join_token_file="${1#*=}"
        shift
        ;;
      --server)
        [ "$#" -ge 2 ] || die "--server requires a value"
        server_url="$2"
        shift 2
        ;;
      --server=*)
        server_url="${1#*=}"
        shift
        ;;
      --hostname)
        [ "$#" -ge 2 ] || die "--hostname requires a value"
        hostname_value="$2"
        shift 2
        ;;
      --hostname=*)
        hostname_value="${1#*=}"
        shift
        ;;
      --mode)
        [ "$#" -ge 2 ] || die "--mode requires a value"
        mode="$2"
        shift 2
        ;;
      --mode=*)
        mode="${1#*=}"
        shift
        ;;
      --version)
        [ "$#" -ge 2 ] || die "--version requires a value"
        client_version="$2"
        shift 2
        ;;
      --version=*)
        client_version="${1#*=}"
        shift
        ;;
      --sha256)
        [ "$#" -ge 2 ] || die "--sha256 requires a value"
        artifact_sha256="$2"
        shift 2
        ;;
      --sha256=*)
        artifact_sha256="${1#*=}"
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
  release_base="${release_base%/}"
  if [ -n "$join_token" ] && [ -n "$join_token_file" ]; then
    die "Use either --join-token or --join-token-file, not both"
  fi

  source_count=0
  for source_value in "$download_url" "$release_base" "$go_package"; do
    if [ -n "$source_value" ]; then
      source_count=$((source_count + 1))
    fi
  done
  [ "$source_count" -le 1 ] || die "Configure only one EndlessNet install source"
  if [ -n "$download_url" ] || [ -n "$release_base" ]; then
    [ -n "$artifact_sha256" ] || die "--sha256 or ENDLESSNET_ARTIFACT_SHA256 is required for downloaded artifacts"
    validate_sha256 "$artifact_sha256"
  elif [ -n "$artifact_sha256" ]; then
    die "--sha256 can be used only with ENDLESSNET_DOWNLOAD_URL or ENDLESSNET_RELEASE_BASE_URL"
  fi
  if [ -n "$client_version" ] && [ "$source_count" -ne 0 ]; then
    die "--version and ENDLESSNET_VERSION apply only to the default APT install"
  fi
  if [ -n "$go_package" ]; then
    case "$go_package" in
      *@v[0-9]*) ;;
      *) die "ENDLESSNET_GO_PACKAGE must use an immutable Go module version such as @v1.2.3" ;;
    esac
  fi

  detect_platform

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/endlessnet-install.XXXXXXXX")" || die "Unable to create a secure temporary directory"
  trap cleanup EXIT
  trap handle_signal HUP INT TERM
  bin="$tmp/$name"
  installed_path="$install_dir/$name"

  if [ -n "$download_url" ]; then
    archive="$tmp/endlessnet-download"
    fetch "$download_url" "$archive"
    verify_sha256 "$archive" "$artifact_sha256"
    case "$download_url" in
      *.tar.gz|*.tgz)
        extract_client_archive "$archive"
        ;;
      *)
        cp "$archive" "$bin"
        ;;
    esac
  elif [ -n "$release_base" ]; then
    archive="$tmp/endlessnet.tar.gz"
    fetch "$release_base/${name}_${os}_${arch}.tar.gz" "$archive"
    verify_sha256 "$archive" "$artifact_sha256"
    extract_client_archive "$archive"
  elif [ -n "$go_package" ]; then
    command -v go >/dev/null 2>&1 || die "go is required for ENDLESSNET_GO_PACKAGE installs"
    GOBIN="$tmp" go install "$go_package"
  elif [ "$os" = "linux" ]; then
    install_apt_package
    installed_path="$(command -v "$name" || printf '%s' "$name")"
  else
    cat >&2 <<'EOF'
EndlessNet install source is not configured.

The default package install supports Debian 12/13 and Ubuntu 22.04/24.04/26.04 LTS.

Set one of:
  ENDLESSNET_DOWNLOAD_URL      direct binary or tar.gz URL; requires ENDLESSNET_ARTIFACT_SHA256
  ENDLESSNET_RELEASE_BASE_URL  release directory with endlessnet-client_<os>_<arch>.tar.gz; requires ENDLESSNET_ARTIFACT_SHA256
  ENDLESSNET_GO_PACKAGE        versioned Go package, for example github.com/<owner>/<repo>/cmd/endlessnet-client@v1.2.3
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
    die "--no-start cannot be used with enrollment"
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
}

main "$@"
