#!/usr/bin/env bash
set -Eeuo pipefail

# Arvan Mirror Setup: safely switch supported Ubuntu APT sources.
VERSION="1.1.0"
DEFAULT_MIRROR="https://mirror.arvancloud.ir/ubuntu"
SECURITY_MIRROR="https://security.ubuntu.com/ubuntu"
MIRROR="$DEFAULT_MIRROR"
ACTION="apply"
ALL_MIRROR=0

# The test root keeps integration tests away from the host's /etc/apt.
# Never set this environment variable for a normal installation.
if [[ -n "${ARVAN_TEST_ROOT:-}" ]]; then
  APT_DIR="${ARVAN_TEST_ROOT%/}/etc/apt"
  OS_RELEASE_FILE="${ARVAN_TEST_ROOT%/}/etc/os-release"
  BACKUP_BASE="${ARVAN_TEST_ROOT%/}/var/backups/arvan-mirror-setup"
  APT_GET="${ARVAN_TEST_APT_GET:-apt-get}"
else
  APT_DIR="/etc/apt"
  OS_RELEASE_FILE="/etc/os-release"
  BACKUP_BASE="/var/backups/arvan-mirror-setup"
  APT_GET="apt-get"
fi

CODENAME=""
SOURCE_FILES=()
CHANGED_FILES=()
STAGED_FILES=()
ROLLBACK_DIR=""
ROLLBACK_ACTIVE=0
TRANSIENT_ROLLBACK=""

usage() {
  cat <<'USAGE'
Usage: sudo ./setup-arvan-mirror.sh [options]

Options:
  --apply             Update supported Ubuntu APT source entries (default)
  --dry-run           Show proposed changes without changing files or using APT
  --status            Show configured source files and Arvan references
  --restore           Restore the latest saved pre-change backup
  --all-mirror        Include Ubuntu security updates in the Arvan mirror
  --mirror URL        Use a custom HTTPS mirror instead of Arvan
  --help              Show this help
  --version           Show version

By default, Ubuntu security updates continue to use the official security
repository. Only /etc/apt/sources.list and sources.list.d/ubuntu.sources are
managed. Other sources, including third-party repositories, are untouched.
USAGE
}

log() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

parse_args() {
  while (($#)); do
    case "$1" in
      --apply) ACTION="apply" ;;
      --dry-run) ACTION="dry-run" ;;
      --status) ACTION="status" ;;
      --restore) ACTION="restore" ;;
      --all-mirror) ALL_MIRROR=1 ;;
      --mirror)
        (($# >= 2)) || die "--mirror requires an HTTPS URL"
        MIRROR="$2"
        shift
        ;;
      --help|-h) usage; exit 0 ;;
      --version) printf 'arvan-mirror-setup %s\n' "$VERSION"; exit 0 ;;
      *) die "Unknown argument: $1 (see --help)" ;;
    esac
    shift
  done
  # Avoid URLs containing whitespace, shell metacharacters or awk separators.
  [[ "$MIRROR" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]{1,5})?(/[a-zA-Z0-9._~/%+-]*)?$ ]] \
    || die "--mirror must be a simple HTTPS URL (without query or credentials)"
  MIRROR="${MIRROR%/}"
}

check_system() {
  [[ -r "$OS_RELEASE_FILE" ]] || die "Cannot read $OS_RELEASE_FILE"
  # shellcheck disable=SC1090
  source "$OS_RELEASE_FILE"
  [[ "${ID:-}" == "ubuntu" ]] || die "Only Ubuntu is supported (found ${ID:-unknown})"
  CODENAME="${VERSION_CODENAME:-}"
  [[ "$CODENAME" =~ ^[a-z][a-z0-9]+$ ]] || die "Invalid or missing Ubuntu codename"

  if [[ "$ACTION" == "apply" || "$ACTION" == "dry-run" ]]; then
    local arch
    if [[ -n "${ARVAN_TEST_ROOT:-}" ]]; then
      arch="${ARVAN_TEST_ARCH:-amd64}"
    else
      command -v dpkg >/dev/null || die "dpkg is required"
      arch="$(dpkg --print-architecture)"
    fi
    [[ "$arch" == "amd64" ]] || die "Only Ubuntu amd64 is currently supported; found $arch"
  fi
}

check_privileges() {
  if [[ -z "${ARVAN_TEST_ROOT:-}" && "$EUID" -ne 0 ]]; then
    die "Run with sudo: sudo ./setup-arvan-mirror.sh $ACTION"
  fi
}

find_sources() {
  SOURCE_FILES=()
  local path
  for path in "$APT_DIR/sources.list" "$APT_DIR/sources.list.d/ubuntu.sources"; do
    if [[ -e "$path" || -L "$path" ]]; then
      [[ -f "$path" && ! -L "$path" ]] || die "Unsafe or non-regular source file: $path"
      SOURCE_FILES+=("$path")
    fi
  done
  ((${#SOURCE_FILES[@]})) || die "Neither sources.list nor ubuntu.sources was found under $APT_DIR"
}

# A conservative editor: only active lines for well-known Ubuntu or Arvan
# repositories, with a recognized Ubuntu suite, are rewritten.
rewrite_legacy() {
  local input="$1" output="$2"
  awk -v mirror="${MIRROR}/" -v security="${SECURITY_MIRROR}/" \
      -v codename="$CODENAME" -v all_mirror="$ALL_MIRROR" '
    function is_managed(uri) {
      return (uri ~ /^https?:\/\/([a-zA-Z0-9-]+\.)?archive\.ubuntu\.com\/ubuntu\/?$/ ||
              uri ~ /^https?:\/\/security\.ubuntu\.com\/ubuntu\/?$/ ||
              uri ~ /^https?:\/\/ports\.ubuntu\.com\/ubuntu-ports\/?$/ ||
              uri ~ /^https?:\/\/old-releases\.ubuntu\.com\/ubuntu\/?$/ ||
              uri ~ /^https?:\/\/mirror\.arvancloud\.ir\/ubuntu\/?$/)
    }
    function is_arvan(uri) {
      return uri ~ /^https?:\/\/mirror\.arvancloud\.ir(\/|$)/
    }
    {
      line=$0
      if (line !~ /^[ \t]*deb(-src)?[ \t]+/) { print line; next }
      match(line, /^[ \t]*deb(-src)?[ \t]+/)
      pos=RLENGTH+1
      if (substr(line,pos,1)=="[") {
        closing=index(substr(line,pos), "]")
        if (!closing) { print line; next }
        pos+=closing
        while (substr(line,pos,1) ~ /[ \t]/ && pos <= length(line)) pos++
      }
      start=pos
      while (pos <= length(line) && substr(line,pos,1) !~ /[ \t]/) pos++
      uri=substr(line,start,pos-start)
      tail=substr(line,pos)
      sub(/^[ \t]+/, "", tail)
      split(tail, fields, /[ \t]+/)
      suite=fields[1]
      if (!is_managed(uri)) { print line; next }
      if (suite != codename && suite != codename "-updates" &&
          suite != codename "-backports" && suite != codename "-security") {
        print line; next
      }
      if (suite == codename "-security" && !all_mirror) {
        # Leave upstream security URLs as-is; migrate old all-Arvan installs.
        if (!is_arvan(uri)) { print line; next }
        target=security
      } else target=mirror
      print substr(line,1,start-1) target substr(line,pos)
    }
  ' "$input" > "$output"
}

# Process deb822 stanzas, retaining all unrelated fields, comments, options,
# component lists and Signed-By settings. Mixed normal/security suites are
# split only when security should remain on the official repository.
rewrite_deb822() {
  local input="$1" output="$2"
  awk -v mirror="${MIRROR}/" -v security="${SECURITY_MIRROR}/" \
      -v codename="$CODENAME" -v all_mirror="$ALL_MIRROR" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function is_managed(uri) {
      return (uri ~ /^https?:\/\/([a-zA-Z0-9-]+\.)?archive\.ubuntu\.com\/ubuntu\/?$/ ||
              uri ~ /^https?:\/\/security\.ubuntu\.com\/ubuntu\/?$/ ||
              uri ~ /^https?:\/\/ports\.ubuntu\.com\/ubuntu-ports\/?$/ ||
              uri ~ /^https?:\/\/old-releases\.ubuntu\.com\/ubuntu\/?$/ ||
              uri ~ /^https?:\/\/mirror\.arvancloud\.ir\/ubuntu\/?$/)
    }
    function is_arvan(uri) { return uri ~ /^https?:\/\/mirror\.arvancloud\.ir(\/|$)/ }
    function emit(uri, suites,    i) {
      for (i=1; i<=n; i++) {
        if (i==uri_index) { print "URIs: " uri; continue }
        if (i==suite_index) { print "Suites: " suites; continue }
        if (i>uri_index && i<=uri_end && lines[i] ~ /^[ \t]+[^# \t]/) continue
        if (i>suite_index && i<=suite_end && lines[i] ~ /^[ \t]+[^# \t]/) continue
        print lines[i]
      }
    }
    function flush(    i,name,value,field,lower,ns,j,parts,suite,norm,sec,valid,uri,types,enabled,
                      normal_suites,security_suites,target) {
      if (!n) return
      delete fields
      uri_index=0; suite_index=0; uri_end=0; suite_end=0
      field=""
      for (i=1; i<=n; i++) {
        if (lines[i] ~ /^[^# \t][^:]*:/) {
          name=lines[i]
          sub(/:.*/, "", name)
          field=tolower(name)
          value=lines[i]
          sub(/^[^:]*:/, "", value)
          fields[field]=trim(value)
          if (field=="uris") { uri_index=i; uri_end=i }
          if (field=="suites") { suite_index=i; suite_end=i }
        } else if (lines[i] ~ /^[ \t]+[^# \t]/ && field!="") {
          fields[field]=fields[field] " " trim(lines[i])
          if (field=="uris") uri_end=i
          if (field=="suites") suite_end=i
        }
      }
      uri=trim(fields["uris"])
      types=" " trim(fields["types"]) " "
      enabled=tolower(trim(fields["enabled"]))
      if (!uri_index || !suite_index || !is_managed(uri) ||
          uri ~ /[ \t]/ || types !~ / deb(-src)? / || enabled=="no") {
        for (i=1; i<=n; i++) print lines[i]
        n=0; return
      }
      ns=split(trim(fields["suites"]), parts, /[ \t]+/)
      norm=0; sec=0; valid=(ns>0)
      normal_suites=""; security_suites=""
      for (j=1; j<=ns; j++) {
        suite=parts[j]
        if (suite==codename || suite==codename "-updates" || suite==codename "-backports") {
          norm++
          normal_suites=normal_suites (normal_suites ? " " : "") suite
        } else if (suite==codename "-security") {
          sec++
          security_suites=security_suites (security_suites ? " " : "") suite
        } else valid=0
      }
      if (!valid) {
        for (i=1; i<=n; i++) print lines[i]
      } else if (norm && sec && !all_mirror) {
        emit(mirror, normal_suites)
        print ""
        emit(security, security_suites)
      } else if (sec && !norm && !all_mirror) {
        if (is_arvan(uri)) emit(security, security_suites)
        else for (i=1; i<=n; i++) print lines[i]
      } else {
        emit(mirror, trim(fields["suites"]))
      }
      n=0
    }
    /^[ \t]*$/ { flush(); print; next }
    { lines[++n]=$0 }
    END { flush() }
  ' "$input" > "$output"
}

relative_path() { printf '%s' "${1#"$APT_DIR"/}"; }

cleanup() {
  local status=$? file rel
  trap - EXIT
  set +e
  if ((ROLLBACK_ACTIVE)); then
    printf 'Update failed; restoring the previous APT sources...\n' >&2
    for file in "${CHANGED_FILES[@]}"; do
      rel="$(relative_path "$file")"
      if [[ -f "$ROLLBACK_DIR/$rel" ]]; then
        cp -p -- "$ROLLBACK_DIR/$rel" "$file" || printf 'Restore failed: %s\n' "$file" >&2
      else
        rm -f -- "$file"
      fi
    done
  fi
  for file in "${STAGED_FILES[@]}"; do rm -f -- "$file"; done
  if [[ -n "$TRANSIENT_ROLLBACK" ]]; then rm -rf -- "$TRANSIENT_ROLLBACK"; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Only the relative paths supported by this script may occur in a manifest.
validate_relative_path() {
  case "$1" in
    sources.list|sources.list.d/ubuntu.sources) ;;
    *) die "Invalid backup manifest path: $1" ;;
  esac
}

backup_changes() {
  local destination="$1" file rel
  mkdir -p -- "$destination"
  : > "$destination/.manifest.pending"
  for file in "${CHANGED_FILES[@]}"; do
    rel="$(relative_path "$file")"
    validate_relative_path "$rel"
    mkdir -p -- "$destination/$(dirname "$rel")"
    if [[ -f "$file" ]]; then cp -p -- "$file" "$destination/$rel"; fi
    printf '%s\n' "$rel" >> "$destination/.manifest.pending"
  done
  mv -- "$destination/.manifest.pending" "$destination/manifest"
}

run_apt_update() {
  log "Validating APT package lists..."
  "$APT_GET" update --error-on=any
}

show_status() {
  log "Ubuntu: $CODENAME"
  log "Managed files:"
  local file
  for file in "${SOURCE_FILES[@]}"; do
    log "  $file"
    awk '/mirror\.arvancloud\.ir/ && $0 !~ /^[ \t]*#/ { found++ }
         END { printf "    Active-looking Arvan references: %d\n", found+0 }' "$file"
  done
  log "Note: --status examines source text; it does not test network health."
}

apply_changes() {
  local file stage snapshot
  for file in "${SOURCE_FILES[@]}"; do
    if [[ "$ACTION" == "dry-run" ]]; then
      stage="$(mktemp "${TMPDIR:-/tmp}/arvan-mirror-dry-run.XXXXXXXX")"
    else
      stage="$(mktemp "${file}.arvan.XXXXXXXX")"
    fi
    STAGED_FILES+=("$stage")
    cp -p -- "$file" "$stage"
    if [[ "$file" == *.sources ]]; then
      rewrite_deb822 "$file" "$stage"
    else
      rewrite_legacy "$file" "$stage"
    fi
    if ! cmp -s -- "$file" "$stage"; then CHANGED_FILES+=("$file"); fi
  done

  if ((${#CHANGED_FILES[@]} == 0)); then
    log "Nothing to change. No backup or APT update needed."
    return
  fi

  if [[ "$ACTION" == "dry-run" ]]; then
    log "Dry run: no files will be modified."
    local idx result
    for idx in "${!SOURCE_FILES[@]}"; do
      if ! cmp -s -- "${SOURCE_FILES[idx]}" "${STAGED_FILES[idx]}"; then
        if diff -u -- "${SOURCE_FILES[idx]}" "${STAGED_FILES[idx]}"; then
          :
        else
          result=$?
          ((result == 1)) || die "diff failed for ${SOURCE_FILES[idx]}"
        fi
      fi
    done
    return
  fi

  mkdir -p -- "$BACKUP_BASE" && chmod 700 -- "$BACKUP_BASE"
  snapshot="$(mktemp -d "$BACKUP_BASE/snapshot-$(date +%Y%m%dT%H%M%S)-XXXXXXXX")"
  backup_changes "$snapshot"
  ROLLBACK_DIR="$snapshot"
  ROLLBACK_ACTIVE=1
  local idx
  for idx in "${!SOURCE_FILES[@]}"; do
    if ! cmp -s -- "${SOURCE_FILES[idx]}" "${STAGED_FILES[idx]}"; then
      mv -f -- "${STAGED_FILES[idx]}" "${SOURCE_FILES[idx]}"
    fi
  done
  run_apt_update
  ROLLBACK_ACTIVE=0
  log "APT sources updated. Backup: $snapshot"
}

restore_latest() {
  [[ -d "$BACKUP_BASE" ]] || die "No backups exist"
  local snapshot rel file stage
  snapshot="$(find "$BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d -name 'snapshot-*' \
    -exec test -f '{}/manifest' \; -print | LC_ALL=C sort -r | head -n 1)"
  [[ -n "$snapshot" ]] || die "No valid backups found"
  [[ -f "$snapshot/manifest" ]] || die "Missing backup manifest"

  CHANGED_FILES=()
  while IFS= read -r rel; do
    validate_relative_path "$rel"
    [[ -f "$snapshot/$rel" ]] || die "Missing source backup: $snapshot/$rel"
    file="$APT_DIR/$rel"
    [[ ! -L "$file" && ( ! -e "$file" || -f "$file" ) ]] || die "Unsafe restore destination: $file"
    [[ -d "$(dirname "$file")" ]] || die "Missing restore directory for $file"
    CHANGED_FILES+=("$file")
  done < "$snapshot/manifest"
  ((${#CHANGED_FILES[@]})) || die "Empty backup manifest"

  # A temporary pre-restore snapshot allows rollback if verification fails.
  mkdir -p -- "$BACKUP_BASE" && chmod 700 -- "$BACKUP_BASE"
  TRANSIENT_ROLLBACK="$(mktemp -d "$BACKUP_BASE/.restore-XXXXXXXX")"
  backup_changes "$TRANSIENT_ROLLBACK"
  ROLLBACK_DIR="$TRANSIENT_ROLLBACK"
  local idx
  for idx in "${!CHANGED_FILES[@]}"; do
    file="${CHANGED_FILES[idx]}"
    rel="$(relative_path "$file")"
    stage="$(mktemp "${file}.arvan.XXXXXXXX")"
    STAGED_FILES+=("$stage")
    cp -p -- "$snapshot/$rel" "$stage"
  done
  ROLLBACK_ACTIVE=1
  for idx in "${!CHANGED_FILES[@]}"; do
    mv -f -- "${STAGED_FILES[idx]}" "${CHANGED_FILES[idx]}"
  done
  run_apt_update
  ROLLBACK_ACTIVE=0
  log "Restored APT sources from $snapshot"
}

main() {
  parse_args "$@"
  check_system
  case "$ACTION" in
    status)
      find_sources
      show_status
      ;;
    dry-run)
      find_sources
      apply_changes
      ;;
    apply)
      check_privileges
      command -v "$APT_GET" >/dev/null || die "apt-get is required"
      find_sources
      apply_changes
      ;;
    restore)
      check_privileges
      command -v "$APT_GET" >/dev/null || die "apt-get is required"
      restore_latest
      ;;
  esac
}

main "$@"
