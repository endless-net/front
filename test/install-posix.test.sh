#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/endlessnet-install-only-test.XXXXXXXX")"
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

artifact="$test_root/client"
install_dir="$test_root/bin"
commands="$test_root/commands"
systemctl_log="$test_root/systemctl.log"
client_log="$test_root/client.log"
output_log="$test_root/output.log"
mkdir -p "$commands"

cat > "$artifact" <<'EOF'
#!/bin/sh
echo "client must not run during installation" >&2
exit 97
EOF

cat > "$commands/id" <<'EOF'
#!/bin/sh
echo 0
EOF

cat > "$commands/curl" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    cp "$ENDLESSNET_TEST_ARTIFACT" "$2"
    exit 0
  fi
  shift
done
exit 1
EOF

cat > "$commands/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ENDLESSNET_TEST_SYSTEMCTL_LOG"
EOF

cat > "$commands/systemd-tmpfiles" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$commands/endlessnet" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ENDLESSNET_TEST_CLIENT_LOG"
exit 97
EOF

chmod 0755 "$artifact" "$commands/id" "$commands/curl" "$commands/systemctl" "$commands/systemd-tmpfiles" "$commands/endlessnet"
artifact_sha256="$(sha256sum "$artifact" | awk '{print $1}')"

PATH="$commands:$PATH" \
ENDLESSNET_INSTALL_DIR="$install_dir" \
ENDLESSNET_DOWNLOAD_URL="https://example.test/endlessnet-client" \
ENDLESSNET_ARTIFACT_SHA256="$artifact_sha256" \
ENDLESSNET_TEST_ARTIFACT="$artifact" \
ENDLESSNET_TEST_SYSTEMCTL_LOG="$systemctl_log" \
ENDLESSNET_TEST_CLIENT_LOG="$client_log" \
  sh "$repo_root/install.sh" > "$output_log" 2>&1

grep -Fqx 'enable --now endlessnet-client.service' "$systemctl_log"
test ! -e "$client_log"
grep -Fqx 'To connect this device to EndlessNet, run:' "$output_log"
grep -Fqx '  endlessnet up' "$output_log"
if grep -Eiq 'service enroll|enrollment request|client must not run' "$output_log"; then
  echo "installer unexpectedly started enrollment" >&2
  exit 1
fi
