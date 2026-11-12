#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/setup-arvan-mirror.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf -- "$ROOT"' EXIT
PASS=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "Expected '$2' in $1"; }
assert_not_contains() { if grep -Fq -- "$2" "$1"; then fail "Unexpected '$2' in $1"; fi; }
assert_same() { cmp -s -- "$1" "$2" || fail "Files differ: $1, $2"; }
pass() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }

reset_root() {
  rm -rf -- "$ROOT/sandbox"
  mkdir -p "$ROOT/sandbox/etc/apt/sources.list.d" "$ROOT/sandbox/etc"
  cat > "$ROOT/sandbox/etc/os-release" <<'OS'
ID=ubuntu
VERSION_CODENAME=noble
OS
  cat > "$ROOT/fake-apt-get" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == update && "$2" == --error-on=any ]] || exit 10
if [[ -f "${ARVAN_TEST_ROOT}/fail-apt" ]]; then exit 99; fi
printf 'update\n' >> "${ARVAN_TEST_ROOT}/apt-calls"
MOCK
  chmod +x "$ROOT/fake-apt-get"
}

run_script() {
  ARVAN_TEST_ROOT="$ROOT/sandbox" ARVAN_TEST_APT_GET="$ROOT/fake-apt-get" \
    bash "$SCRIPT" "$@"
}

reset_root
cat > "$ROOT/sandbox/etc/apt/sources.list.d/ubuntu.sources" <<'SOURCES'
# Ubuntu with custom settings
Types: deb deb-src
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates noble-backports
Components: main restricted
Architectures: amd64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main restricted universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Signed-By: /etc/apt/keyrings/docker.gpg
SOURCES
SOURCE="$ROOT/sandbox/etc/apt/sources.list.d/ubuntu.sources"
cp "$SOURCE" "$ROOT/original"
run_script --dry-run > "$ROOT/diff-output"
assert_same "$SOURCE" "$ROOT/original"
assert_contains "$ROOT/diff-output" 'https://mirror.arvancloud.ir/ubuntu/'
[[ ! -d "$ROOT/sandbox/var/backups" ]] || fail 'dry-run wrote backups'
[[ ! -e "$ROOT/sandbox/apt-calls" ]] || fail 'dry-run called apt-get'
pass 'dry-run displays diff without modifications'

run_script --apply > /dev/null
assert_contains "$SOURCE" 'URIs: https://mirror.arvancloud.ir/ubuntu/'
assert_contains "$SOURCE" 'URIs: http://security.ubuntu.com/ubuntu/'
assert_contains "$SOURCE" 'Architectures: amd64'
assert_contains "$SOURCE" 'Types: deb deb-src'
assert_contains "$SOURCE" 'URIs: https://download.docker.com/linux/ubuntu'
[[ $(wc -l < "$ROOT/sandbox/apt-calls") == 1 ]] || fail 'Expected one update'
pass 'deb822 edit preserves options, security, and third-party stanzas'

run_script --apply > /dev/null
[[ $(wc -l < "$ROOT/sandbox/apt-calls") == 1 ]] || fail 'Second application should be a no-op'
[[ $(find "$ROOT/sandbox/var/backups/arvan-mirror-setup" -maxdepth 1 -name 'snapshot-*' -type d | wc -l) == 1 ]] \
  || fail 'Idempotence: unexpected extra snapshot'
pass 'second apply is idempotent'

run_script --restore > /dev/null
assert_same "$SOURCE" "$ROOT/original"
[[ $(wc -l < "$ROOT/sandbox/apt-calls") == 2 ]] || fail 'Restore did not validate apt'
pass 'restore retrieves latest backup'

reset_root
cat > "$ROOT/sandbox/etc/apt/sources.list" <<'LEGACY'
# deb http://archive.ubuntu.com/ubuntu noble main
deb [arch=amd64 signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://archive.ubuntu.com/ubuntu noble main restricted
deb http://archive.ubuntu.com/ubuntu noble-updates main
deb http://security.ubuntu.com/ubuntu noble-security main
deb-src http://archive.ubuntu.com/ubuntu noble-backports main
deb https://download.docker.com/linux/ubuntu noble stable
LEGACY
LEGACY_FILE="$ROOT/sandbox/etc/apt/sources.list"
run_script --apply > /dev/null
assert_contains "$LEGACY_FILE" 'deb [arch=amd64 signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] https://mirror.arvancloud.ir/ubuntu/ noble main restricted'
assert_contains "$LEGACY_FILE" 'deb-src https://mirror.arvancloud.ir/ubuntu/ noble-backports main'
assert_contains "$LEGACY_FILE" 'deb http://security.ubuntu.com/ubuntu noble-security main'
assert_contains "$LEGACY_FILE" 'deb https://download.docker.com/linux/ubuntu noble stable'
assert_contains "$LEGACY_FILE" '# deb http://archive.ubuntu.com/ubuntu noble main'
pass 'legacy format preserves options and unrelated repositories'

reset_root
cat > "$ROOT/sandbox/etc/apt/sources.list.d/ubuntu.sources" <<'MIXED'
# Existing configuration from the original installer
Types: deb
URIs: http://mirror.arvancloud.ir/ubuntu/
Suites: noble noble-updates noble-backports noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
MIXED
MIXED_FILE="$ROOT/sandbox/etc/apt/sources.list.d/ubuntu.sources"
run_script --apply > /dev/null
assert_contains "$MIXED_FILE" 'Suites: noble noble-updates noble-backports'
assert_contains "$MIXED_FILE" 'Suites: noble-security'
assert_contains "$MIXED_FILE" 'URIs: https://security.ubuntu.com/ubuntu/'
assert_contains "$MIXED_FILE" 'URIs: https://mirror.arvancloud.ir/ubuntu/'
run_script --dry-run > "$ROOT/empty-diff"
assert_contains "$ROOT/empty-diff" 'Nothing to change'
pass 'migration splits old mixed deb822 suites and stays idempotent'

reset_root
cat > "$ROOT/sandbox/etc/apt/sources.list" <<'FAILSOURCE'
deb http://archive.ubuntu.com/ubuntu noble main
FAILSOURCE
cp "$ROOT/sandbox/etc/apt/sources.list" "$ROOT/pre-failure"
touch "$ROOT/sandbox/fail-apt"
if run_script --apply > "$ROOT/failure-output" 2>&1; then fail 'Expected apt update to fail'; fi
assert_same "$ROOT/sandbox/etc/apt/sources.list" "$ROOT/pre-failure"
pass 'failed apt update restores the old configuration'

reset_root
cat > "$ROOT/sandbox/etc/apt/sources.list" <<'ALLMIRROR'
deb http://archive.ubuntu.com/ubuntu noble main
deb http://security.ubuntu.com/ubuntu noble-security main
ALLMIRROR
run_script --all-mirror > /dev/null
assert_contains "$ROOT/sandbox/etc/apt/sources.list" 'deb https://mirror.arvancloud.ir/ubuntu/ noble-security main'
pass '--all-mirror includes security sources when explicitly requested'

reset_root
cat > "$ROOT/sandbox/etc/apt/sources.list" <<'NONUBUNTU'
deb http://archive.ubuntu.com/ubuntu noble main
NONUBUNTU
sed -i 's/ID=ubuntu/ID=debian/' "$ROOT/sandbox/etc/os-release"
if run_script --apply > "$ROOT/nonubuntu-output" 2>&1; then fail 'Expected Debian to be rejected'; fi
assert_contains "$ROOT/sandbox/etc/apt/sources.list" 'http://archive.ubuntu.com/ubuntu'
pass 'rejects unsupported distributions without writing'

reset_root
cat > "$ROOT/sandbox/etc/apt/sources.list" <<'UNSAFE'
deb http://archive.ubuntu.com/ubuntu noble main
UNSAFE
if ARVAN_TEST_ROOT="$ROOT/sandbox" ARVAN_TEST_ARCH=arm64 ARVAN_TEST_APT_GET="$ROOT/fake-apt-get" \
   bash "$SCRIPT" --dry-run > "$ROOT/arch-output" 2>&1; then
  fail 'Expected arm64 to be rejected'
fi
pass 'unsupported architectures fail safely'

reset_root
cat > "$ROOT/sandbox/etc/apt/sources.list" <<'CUSTOM'
deb http://archive.ubuntu.com/ubuntu noble main
CUSTOM
run_script --mirror https://mirror.example.net/ubuntu > /dev/null
assert_contains "$ROOT/sandbox/etc/apt/sources.list" 'https://mirror.example.net/ubuntu/'
pass 'custom mirror option is honored'

reset_root
cat > "$ROOT/sandbox/etc/apt/sources.list.d/ubuntu.sources" <<'DISABLED'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble
Components: main
Enabled: no

Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble
  noble-updates
  noble-backports
Components: main
DISABLED
run_script --apply > /dev/null
DISABLED_FILE="$ROOT/sandbox/etc/apt/sources.list.d/ubuntu.sources"
assert_contains "$DISABLED_FILE" 'URIs: http://archive.ubuntu.com/ubuntu/'
assert_contains "$DISABLED_FILE" 'URIs: https://mirror.arvancloud.ir/ubuntu/'
assert_contains "$DISABLED_FILE" 'Suites: noble noble-updates noble-backports'
pass 'disabled stanzas are skipped and folded Suites are preserved semantically'

reset_root
cat > "$ROOT/sandbox/etc/apt/sources.list" <<'BOTH'
deb http://archive.ubuntu.com/ubuntu noble main
BOTH
cat > "$ROOT/sandbox/etc/apt/sources.list.d/ubuntu.sources" <<'BOTHDEB822'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates
Components: main
BOTHDEB822
cp "$ROOT/sandbox/etc/apt/sources.list" "$ROOT/original-legacy"
cp "$ROOT/sandbox/etc/apt/sources.list.d/ubuntu.sources" "$ROOT/original-deb822"
touch "$ROOT/sandbox/fail-apt"
if run_script --apply > "$ROOT/two-file-failure" 2>&1; then fail 'Expected failure with two source files'; fi
assert_same "$ROOT/sandbox/etc/apt/sources.list" "$ROOT/original-legacy"
assert_same "$ROOT/sandbox/etc/apt/sources.list.d/ubuntu.sources" "$ROOT/original-deb822"
pass 'rollback restores multiple files together'


reset_root
cat > "$ROOT/sandbox/etc/apt/sources.list" <<'RESTORE_FAIL'
deb http://archive.ubuntu.com/ubuntu noble main
RESTORE_FAIL
run_script --apply > /dev/null
cp "$ROOT/sandbox/etc/apt/sources.list" "$ROOT/applied-state"
touch "$ROOT/sandbox/fail-apt"
if run_script --restore > "$ROOT/restore-fail-output" 2>&1; then fail 'Expected restore validation failure'; fi
assert_same "$ROOT/sandbox/etc/apt/sources.list" "$ROOT/applied-state"
pass 'failed restore validation rolls back to its pre-restore state'

reset_root
cat > "$ROOT/sandbox/etc/apt/sources.list" <<'UNKNOWN'
deb https://archive.ubuntu.com/not-an-ubuntu-repo noble main
deb https://packages.example.com/ubuntu noble main
UNKNOWN
run_script --apply > "$ROOT/unknown-output"
assert_contains "$ROOT/unknown-output" 'Nothing to change'
assert_contains "$ROOT/sandbox/etc/apt/sources.list" 'https://archive.ubuntu.com/not-an-ubuntu-repo'
pass 'unrecognized repository paths are not modified'

printf 'Final result: %d integration tests passed.\n' "$PASS"
