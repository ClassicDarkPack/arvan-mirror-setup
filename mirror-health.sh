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
    --proto '=https' --connect-timeout 4 --max-time 12 \
    --output "$output" --write-out '%{speed_download}' \
    "$url/dists/$suite/InRelease")" || return 1
  [[ -s "$output" ]] || return 1
  gpgv --quiet --keyring /usr/share/keyrings/ubuntu-archive-keyring.gpg \
    "$output" 2>/dev/null || return 1
  PROBE_SPEED="${speed%%.*}"
  [[ "$PROBE_SPEED" =~ ^[0-9]+$ ]] || PROBE_SPEED=0
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
    speed="$PROBE_SPEED"
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
    printf '  %-12s VERIFIED (%s KiB/s metadata)\n' "$name" "$((speed / 1024))"
    if ((speed > best_speed)); then
      best_speed="$speed"
      BEST_MIRROR="$url"
    fi
  done
  rm -rf -- "$temp"
  [[ -n "$BEST_MIRROR" ]] || die "No sufficiently fresh signed Ubuntu mirror is available"
  printf 'Best verified candidate: %s\n' "$BEST_MIRROR"
}
