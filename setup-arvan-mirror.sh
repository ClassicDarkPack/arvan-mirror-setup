#!/usr/bin/env bash
set -Eeuo pipefail

# Arvan Mirror Setup: safely switch supported Ubuntu APT sources.
APP_VERSION="1.4.0"
DEFAULT_MIRROR="https://mirror.arvancloud.ir/ubuntu"
SECURITY_MIRROR="https://security.ubuntu.com/ubuntu"
MIRROR="$DEFAULT_MIRROR"
ACTION="apply"
ALL_MIRROR=0
AUTO_SELECT=0
MIRROR_EXPLICIT=0

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

#!/usr/bin/env bash
# Sourced by setup-arvan-mirror.sh; candidates are not presumed healthy.
mirror_url() {
  case "$1" in
    arvan) printf '%s\n' 'https://mirror.arvancloud.ir/ubuntu' ;;
    iranserver) printf '%s\n' 'https://mirror.iranserver.com/ubuntu' ;;
    pishgaman) printf '%s\n' 'https://ubuntu.pishgaman.net/ubuntu' ;;
    ubuntu) printf '%s\n' 'https://archive.ubuntu.com/ubuntu' ;;
    *) return 1 ;;
  esac
}
list_mirrors() {
  local name
  printf 'Mirror candidates (NOT pre-verified):\n'
  for name in arvan iranserver pishgaman ubuntu; do
    printf '  %-12s %s\n' "$name" "$(mirror_url "$name")"
  done
}
probe_pocket() {
  local url="$1" suite="$2" output="$3" speed
  speed="$(curl --fail --location --silent --show-error \
    --proto '=https' --proto-redir '=https' --connect-timeout 4 --max-time 12 \
    --output "$output" --write-out '%{speed_download}' \
    "$url/dists/$suite/InRelease")" || return 1
  [[ -s "$output" ]] || return 1
  gpgv --quiet --keyring /usr/share/keyrings/ubuntu-archive-keyring.gpg \
    "$output" 2>/dev/null || return 1
  PROBE_SPEED="${speed%%.*}"
  [[ "$PROBE_SPEED" =~ ^[0-9]+$ ]] || PROBE_SPEED=0
}
# Benchmark a real compressed package index (bounded transfer).
benchmark_mirror() {
  local url="$1" output="$2" rate bytes
  rate="$(curl --fail --location --silent --show-error \
    --proto '=https' --proto-redir '=https' \
    --connect-timeout 5 --max-time 20 \
    --range 0-1048575 --max-filesize 8388608 \
    --output "$output" --write-out '%{speed_download}' \
    "$url/dists/$CODENAME-updates/main/binary-amd64/Packages.xz")" || return 1
  bytes="$(wc -c < "$output")"
  ((bytes >= 65536 && bytes <= 8388608)) || return 1
  BENCHMARK_SPEED="${rate%%.*}"
  [[ "$BENCHMARK_SPEED" =~ ^[0-9]+$ ]] || return 1
}

release_epoch() {
  local timestamp
  timestamp="$(awk '/^Date: / { sub(/^Date: /, ""); print; exit }' "$1")"
  [[ -n "$timestamp" ]] || return 1
  date -u -d "$timestamp" +%s
}
evaluate_mirrors() {
  command -v curl >/dev/null && command -v gpgv >/dev/null \
    && [[ -r /usr/share/keyrings/ubuntu-archive-keyring.gpg ]] \
    || die "Mirror checks need curl, gpgv and ubuntu-keyring"
  local temp official_date now name url candidate_date speed best_speed=-1
  local security_ref="" security_date=""
  temp="$(mktemp -d "${TMPDIR:-/tmp}/arvan-mirror-check.XXXXXXXX")"
  if ! probe_pocket "$(mirror_url ubuntu)" "$CODENAME-updates" "$temp/reference"; then
    rm -rf -- "$temp"
    die "Cannot authenticate the official Ubuntu -updates reference"
  fi
  official_date="$(release_epoch "$temp/reference")" || {
    rm -rf -- "$temp"
    die "Official Ubuntu InRelease has invalid Date metadata"
  }
  now="$(date -u +%s)"
  if ((official_date > now + 86400)); then
    rm -rf -- "$temp"
    die "Official Ubuntu metadata is dated in the future"
  fi
  if ((ALL_MIRROR)); then
    if ! probe_pocket "$SECURITY_MIRROR" "$CODENAME-security" "$temp/security-reference"; then
      rm -rf -- "$temp"
      die "Cannot authenticate official Ubuntu security metadata"
    fi
    security_ref="$(release_epoch "$temp/security-reference")" || {
      rm -rf -- "$temp"
      die "Official Ubuntu security metadata has invalid Date"
    }
  fi
  BEST_MIRROR=""
  printf 'Signed metadata / freshness checks for Ubuntu %s:\n' "$CODENAME"
  for name in arvan iranserver pishgaman ubuntu; do
    url="$(mirror_url "$name")"
    if ! probe_pocket "$url" "$CODENAME-updates" "$temp/updates"; then
      printf '  %-12s FAIL (unreachable/unsigned)\n' "$name"
      continue
    fi
    candidate_date="$(release_epoch "$temp/updates")" || {
      printf '  %-12s FAIL (invalid Date)\n' "$name"
      continue
    }
    if ((candidate_date > now + 86400 || candidate_date + 43200 < official_date)); then
      printf '  %-12s STALE (more than 12h behind official)\n' "$name"
      continue
    fi
    if ! probe_pocket "$url" "$CODENAME" "$temp/base" ||
       ! probe_pocket "$url" "$CODENAME-backports" "$temp/backports"; then
      printf '  %-12s FAIL (base/backports unavailable or unsigned)\n' "$name"
      continue
    fi
    if ((ALL_MIRROR)); then
      if ! probe_pocket "$url" "$CODENAME-security" "$temp/security"; then
        printf '  %-12s FAIL (security unavailable or unsigned)\n' "$name"
        continue
      fi
      security_date="$(release_epoch "$temp/security")" || continue
      if ((security_date + 43200 < security_ref)); then
        printf '  %-12s STALE (security updates)\n' "$name"
        continue
      fi
    fi
    if ! benchmark_mirror "$url" "$temp/package-index"; then
      printf '  %-12s FAIL (package-index download benchmark)\n' "$name"
      continue
    fi
    speed="$BENCHMARK_SPEED"
    printf '  %-12s VERIFIED (%s KiB/s package index)\n' "$name" "$((speed / 1024))"
    if ((speed > best_speed)); then
      best_speed="$speed"
      BEST_MIRROR="$url"
    fi
  done
  rm -rf -- "$temp"
  [[ -n "$BEST_MIRROR" ]] || die "No sufficiently fresh signed Ubuntu mirror is available"
  printf 'Best verified candidate: %s\n' "$BEST_MIRROR"
}

usage() {
  cat <<'USAGE'
Usage: sudo ./setup-arvan-mirror.sh [options]

Options:
  --menu              Open an interactive terminal menu (default with a TTY)
  --list-mirrors      List candidate mirror URLs (offline)
  --check-mirrors     Verify freshness and benchmark package-index download speed
  --auto              Automatically select a verified, fresh mirror
  --mirror NAME|URL   Use arvan, iranserver, pishgaman, ubuntu, or HTTPS URL
  --apply             Update supported Ubuntu APT source entries
  --dry-run           Show proposed changes without changing files or using APT
  --status            Show configured source files and Arvan references
  --restore           Restore the latest saved pre-change backup
  --all-mirror        Include Ubuntu security updates in the Arvan mirror
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
      --menu) ACTION="menu" ;;
      --list-mirrors) ACTION="list-mirrors" ;;
      --check-mirrors) ACTION="check-mirrors" ;;
      --auto) AUTO_SELECT=1 ;;
      --dry-run) ACTION="dry-run" ;;
      --status) ACTION="status" ;;
      --restore) ACTION="restore" ;;
      --all-mirror) ALL_MIRROR=1 ;;
      --mirror)
        (($# >= 2)) || die "--mirror requires an HTTPS URL"
        MIRROR="$2"
        MIRROR_EXPLICIT=1
        if mirror_url "$MIRROR" >/dev/null; then
          MIRROR="$(mirror_url "$MIRROR")"
        fi
        shift
        ;;
      --help|-h) usage; exit 0 ;;
      --version) printf 'arvan-mirror-setup %s\n' "$APP_VERSION"; exit 0 ;;
      *) die "Unknown argument: $1 (see --help)" ;;
    esac
    shift
  done
  (( ! AUTO_SELECT || ! MIRROR_EXPLICIT )) || die "--auto and --mirror cannot be combined"
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

  if [[ "$ACTION" == "apply" || "$ACTION" == "dry-run" || "$ACTION" == "check-mirrors" ]]; then
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
              uri ~ /^https?:\/\/mirror\.arvancloud\.ir\/ubuntu\/?$/ ||
              uri ~ /^https?:\/\/mirror\.iranserver\.com\/ubuntu\/?$/ ||
              uri ~ /^https?:\/\/ubuntu\.pishgaman\.net\/ubuntu\/?$/)
    }
    function is_arvan(uri) {
      return uri ~ /^https?:\/\/(mirror\.arvancloud\.ir|mirror\.iranserver\.com|ubuntu\.pishgaman\.net)(\/|$)/
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
              uri ~ /^https?:\/\/mirror\.arvancloud\.ir\/ubuntu\/?$/ ||
              uri ~ /^https?:\/\/mirror\.iranserver\.com\/ubuntu\/?$/ ||
              uri ~ /^https?:\/\/ubuntu\.pishgaman\.net\/ubuntu\/?$/)
    }
    function is_arvan(uri) { return uri ~ /^https?:\/\/(mirror\.arvancloud\.ir|mirror\.iranserver\.com|ubuntu\.pishgaman\.net)(\/|$)/ }
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


# An interactive front-end to the existing CLI. All privileged operations run
# through a fresh process so the backup and rollback state cannot leak between
# successive menu actions.
menu_pause() {
  printf '\nPress Enter to return to the main menu...'
  IFS= read -r || :
}

menu_run() {
  local args=("$@")
  if [[ -n "${ARVAN_TEST_ROOT:-}" || "$EUID" -eq 0 ]]; then
    bash "$0" "${args[@]}"
  elif command -v sudo >/dev/null 2>&1; then
    sudo bash "$0" "${args[@]}"
  else
    printf 'This action requires root (sudo is not available).\n' >&2
    return 1
  fi
}

menu_colors() {
  C_RESET='' C_TITLE='' C_ACCENT='' C_SUCCESS='' C_MUTED='' C_WARN=''
  if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\e[0m'
    C_TITLE=$'\e[1;36m'
    C_ACCENT=$'\e[1;32m'
    C_SUCCESS=$'\e[1;34m'
    C_MUTED=$'\e[2m'
    C_WARN=$'\e[1;33m'
  fi
}

menu_preview_and_apply() {
  local mode="$1" selected_mirror="${2:-}" reply
  local args=(--apply) preview=(--dry-run)
  if [[ "$mode" == "auto" ]]; then
    evaluate_mirrors || return
    [[ -n "$BEST_MIRROR" ]] || die "No validated mirror selected"
    selected_mirror="$BEST_MIRROR"
  fi
  if [[ -n "$selected_mirror" ]]; then
    args+=(--mirror "$selected_mirror")
    preview+=(--mirror "$selected_mirror")
    printf 'Selected mirror: %s\n' "$selected_mirror"
  fi
  if [[ "$mode" == "all" ]]; then
    args+=(--all-mirror)
    preview+=(--all-mirror)
  fi
  printf '\n%s--- Preview: no files are changed ---%s\n\n' "$C_TITLE" "$C_RESET"
  bash "$0" "${preview[@]}" || return
  printf '\n%sApply exactly these settings? [y/N]: %s' "$C_WARN" "$C_RESET"
  IFS= read -r reply || return
  case "$reply" in
    y|Y|yes|YES) menu_run "${args[@]}" ;;
    *) printf 'Cancelled. No settings changed.\n' ;;
  esac
}

menu_choose_mirror() {
  local mode="$1" answer mirror
  printf '\n%sSelect mirror (%s):%s\n\n' "$C_TITLE" \
    "$([[ "$mode" == all ]] && printf 'all Ubuntu pockets' || printf 'official security retained')" "$C_RESET"
  printf '  1) ArvanCloud     2) IranServer\n'
  printf '  3) Pishgaman      4) Official Ubuntu\n'
  printf '  0) Cancel\n\n'
  printf '%sManual choice does not pre-check freshness. Use Check Mirrors first.%s\n' "$C_WARN" "$C_RESET"
  printf 'Choice [0-4]: '
  IFS= read -r answer || return
  case "$answer" in
    1) mirror=arvan ;;
    2) mirror=iranserver ;;
    3) mirror=pishgaman ;;
    4) mirror=ubuntu ;;
    0|'') printf 'Cancelled.\n'; return 0 ;;
    *) printf 'Invalid choice.\n'; return 1 ;;
  esac
  menu_preview_and_apply "$mode" "$(mirror_url "$mirror")"
}

menu_restore() {
  local reply
  printf '\nRestore the latest saved APT sources backup? [y/N]: '
  IFS= read -r reply || return
  case "$reply" in
    y|Y|yes|YES) menu_run --restore ;;
    *) printf 'Cancelled. No settings changed.\n' ;;
  esac
}

MENU_ITEMS=(
  "Select mirror  [official security updates]"
  "Select mirror  [all Ubuntu pockets]"
  "Auto Select Best Mirror"
  "Check freshness and real download speed"
  "Show mirror list"
  "Preview default (Arvan) changes"
  "Preview all-mirror changes"
  "Show APT source status"
  "Restore latest backup"
  "Help and options"
  "Exit"
)

menu_draw() {
  local selected="$1" idx marker
  printf '\033[H\033[2J'
  printf '%s' "$C_TITLE"
  printf '  +--------------------------------------------------+\n'
  printf '  |           ARVAN MIRROR MANAGER v%-16s|\n' "$APP_VERSION"
  printf '  +--------------------------------------------------+\n'
  printf '%s' "$C_RESET"
  printf '  Ubuntu: %s  |  SSH / Terminal\n' "$CODENAME"
  printf '  %sChanges require confirmation; security stays official by default.%s\n' "$C_MUTED" "$C_RESET"
  printf '\n  %sMIRROR MANAGEMENT%s\n' "$C_SUCCESS" "$C_RESET"
  for idx in "${!MENU_ITEMS[@]}"; do
    if ((idx == 5)); then
      printf '\n  %sTOOLS & RECOVERY%s\n' "$C_SUCCESS" "$C_RESET"
    fi
    marker=' '
    if ((idx == selected)); then marker='>'; fi
    if ((idx == selected)); then
      printf '%s %s %2d. %-44s%s\n' "$C_ACCENT" "$marker" "$((idx+1))" "${MENU_ITEMS[idx]}" "$C_RESET"
    else
      printf ' %s %2d. %s\n' "$marker" "$((idx+1))" "${MENU_ITEMS[idx]}"
    fi
  done
  printf '\n  %sUp/Down + Enter | 1-11 + Enter | 0/q = Exit%s\n' "$C_MUTED" "$C_RESET"
}

menu_read_choice() {
  local key extra selected="$1"
  IFS= read -rsn1 key || return 1
  case "$key" in
    $'\e')
      extra=''
      IFS= read -rsn2 -t 0.3 extra || :
      case "$extra" in
        '[A') MENU_CHOICE=$(((selected + ${#MENU_ITEMS[@]} - 1) % ${#MENU_ITEMS[@]})) ;;
        '[B') MENU_CHOICE=$(((selected + 1) % ${#MENU_ITEMS[@]})) ;;
        *) MENU_CHOICE="$selected" ;;
      esac
      MENU_ACTIVATE=0
      ;;
    q|Q|0) MENU_CHOICE=10; MENU_ACTIVATE=1 ;;
    '') MENU_CHOICE="$selected"; MENU_ACTIVATE=1 ;;
    [1-9])
      extra=''
      if [[ "$key" == 1 ]]; then
        IFS= read -rsn1 -t 0.35 extra || :
      fi
      case "$key$extra" in
        10) MENU_CHOICE=9 ;;
        11) MENU_CHOICE=10 ;;
        *) MENU_CHOICE=$((key - 1)) ;;
      esac
      MENU_ACTIVATE=1
      ;;
    *) MENU_CHOICE="$selected"; MENU_ACTIVATE=0 ;;
  esac
}

interactive_menu() {
  [[ -t 0 && -t 1 ]] || die "Interactive menu requires a terminal (TTY). Use --help for CLI options."
  local selected=0 choice
  menu_colors
  while :; do
    menu_draw "$selected"
    menu_read_choice "$selected" || return 0
    selected="$MENU_CHOICE"
    ((MENU_ACTIVATE)) || continue
    choice=$((selected + 1))
    printf '\n'
    case "$choice" in
      1) menu_choose_mirror default || printf 'Action failed.\n' ;;
      2) menu_choose_mirror all || printf 'Action failed.\n' ;;
      3) menu_preview_and_apply auto || printf 'Auto selection failed.\n' ;;
      4) bash "$0" --check-mirrors || printf 'Check failed.\n' ;;
      5) bash "$0" --list-mirrors || printf 'List failed.\n' ;;
      6) bash "$0" --dry-run || printf 'Preview failed.\n' ;;
      7) bash "$0" --dry-run --all-mirror || printf 'Preview failed.\n' ;;
      8) bash "$0" --status || printf 'Status failed.\n' ;;
      9) menu_restore || printf 'Restore failed.\n' ;;
      10) usage ;;
      11) printf 'Goodbye!\n'; return 0 ;;
    esac
    menu_pause
  done
}

main() {
  if (($# == 0)) && [[ -t 0 && -t 1 ]]; then
    ACTION="menu"
  else
    parse_args "$@"
  fi
  check_system
  if [[ "$ACTION" == "list-mirrors" ]]; then
    list_mirrors
    return
  fi
  if [[ "$ACTION" == "check-mirrors" ]]; then
    evaluate_mirrors
    return
  fi
  if ((AUTO_SELECT)) && [[ "$ACTION" == "apply" || "$ACTION" == "dry-run" ]]; then
    evaluate_mirrors
    MIRROR="$BEST_MIRROR"
  fi
  case "$ACTION" in
    menu)
      interactive_menu
      ;;
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
