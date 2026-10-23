# SPDX-License-Identifier: GPL-2.0-only OR MIT
#
# Shared helpers for every stage. Sourced by scripts/inner.sh inside the build
# container; stage files (scripts/stages/*.sh, scripts/distro/<distro>/*.sh) can
# rely on everything defined and exported here.
#
# Paths (exported):
#   SRC        repository root, read-only
#   WORK_DIR   scratch (host: A7S_WORK)
#   OUT_DIR    artefacts (host: A7S_OUT)
#   CACHE_DIR  verified downloads (host: A7S_CACHE)
#   TMPDIR     ${WORK_DIR}/tmp, so large temporary files never land in the
#              container's own storage
# Also exported: SOURCE_DATE_EPOCH, A7S_JOBS (a number), A7S_BUILD_COMMIT,
# DEBIAN_MIRROR / DEBIAN_SECURITY_MIRROR (snapshot or live archive, from
# A7S_SNAPSHOT), and every switch of config/defaults.conf.
#
# Helpers: log, warn, die, have_stage, run_stage, fetch_cached, fetch_verified,
# git_fetch_pinned.

log()  { printf '=== %s\n' "$*"; }
warn() { printf '::warning:: %s\n' "$*" >&2; }
die()  { printf '::error:: %s\n' "$*" >&2; exit 1; }

# --- environment ------------------------------------------------------------

a7s_env_setup() {
  : "${SRC:?SRC must name the repository root}"
  export SRC
  export WORK_DIR="${WORK_DIR:-/work}"
  export OUT_DIR="${OUT_DIR:-/out}"
  export CACHE_DIR="${CACHE_DIR:-/cache}"

  # shellcheck source=../../config/defaults.conf
  . "${SRC}/config/defaults.conf"
  local v
  for v in $(sed -n 's/^\(A7S_[A-Z0-9_]*\)=.*/\1/p' "${SRC}/config/defaults.conf"); do
    export "${v?}"
  done

  mkdir -p "${WORK_DIR}" "${OUT_DIR}" "${CACHE_DIR}" "${WORK_DIR}/tmp"
  export TMPDIR="${WORK_DIR}/tmp"

  [ -n "${A7S_JOBS}" ] || A7S_JOBS="$(nproc)"
  case "${A7S_JOBS}" in ''|*[!0-9]*) die "A7S_JOBS must be a number, not '${A7S_JOBS}'" ;; esac
  export A7S_JOBS

  case "${A7S_SNAPSHOT}" in
    '')
      export DEBIAN_MIRROR="http://deb.debian.org/debian"
      export DEBIAN_SECURITY_MIRROR="http://security.debian.org/debian-security" ;;
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z)
      export DEBIAN_MIRROR="http://snapshot.debian.org/archive/debian/${A7S_SNAPSHOT}"
      export DEBIAN_SECURITY_MIRROR="http://snapshot.debian.org/archive/debian-security/${A7S_SNAPSHOT}" ;;
    *) die "A7S_SNAPSHOT must look like 20261002T000000Z (or be empty), not '${A7S_SNAPSHOT}'" ;;
  esac

  # SOURCE_DATE_EPOCH: explicit switch > commit time of HEAD > snapshot time.
  # build.sh reads HEAD on the host and passes A7S_SOURCE_DATE_EPOCH; the git
  # lookup here only matters when inner.sh runs without build.sh.
  local sde="${A7S_SOURCE_DATE_EPOCH}"
  if [ -z "${sde}" ]; then
    sde="$(git -C "${SRC}" log -1 --format=%ct 2>/dev/null)" || sde=""
  fi
  if [ -z "${sde}" ] && [ -n "${A7S_SNAPSHOT}" ]; then
    local s="${A7S_SNAPSHOT}"
    sde="$(date -u -d "${s:0:4}-${s:4:2}-${s:6:2}T${s:9:2}:${s:11:2}:${s:13:2}Z" +%s)"
  fi
  [ -n "${sde}" ] || die "no SOURCE_DATE_EPOCH: no git metadata and A7S_SNAPSHOT is empty -- set A7S_SOURCE_DATE_EPOCH"
  case "${sde}" in *[!0-9]*) die "SOURCE_DATE_EPOCH must be a number, not '${sde}'" ;; esac
  export SOURCE_DATE_EPOCH="${sde}"

  if [ -z "${A7S_BUILD_COMMIT}" ]; then
    A7S_BUILD_COMMIT="$(git -C "${SRC}" rev-parse HEAD 2>/dev/null)" || A7S_BUILD_COMMIT=unknown
  fi
  export A7S_BUILD_COMMIT

  export LC_ALL=C.UTF-8 TZ=UTC
  umask 022
}

# --- stages -----------------------------------------------------------------

# Stage name (as typed: build-kernel) -> function name (stage_build_kernel).
stage_fn() { printf 'stage_%s' "${1//-/_}"; }
have_stage() { declare -F "$(stage_fn "$1")" >/dev/null; }
run_stage() {
  local fn; fn="$(stage_fn "$1")"
  have_stage "$1" || die "stage '$1' does not exist (no ${fn}() in scripts/stages/*.sh or scripts/distro/${A7S_DISTRO}/*.sh)"
  log "stage $1 (SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH})"
  "${fn}"
}

# --- downloads ----------------------------------------------------------------

_sha256_ok() {  # <sha256> <file>
  [ -f "$2" ] && printf '%s  %s\n' "$1" "$2" | sha256sum -c --status - 2>/dev/null
}

# fetch_cached <sha256> <url> [<url>...]
# Make sure the cache holds the file with this sha256 and print its path. Tries
# A7S_DOWNLOAD_MIRROR/<sha256> first when set, then every URL in order, each
# with retries. A download lands under a temporary name and enters the cache
# only after it matched the sha256; a cached copy is verified again on every
# call and dropped when it no longer matches.
fetch_cached() {
  local sha="$1"; shift
  case "${sha}" in
    [0-9a-f]*) [ "${#sha}" = 64 ] && [ -z "${sha//[0-9a-f]/}" ] || die "fetch: '${sha}' is not a sha256" ;;
    *) die "fetch: '${sha}' is not a sha256" ;;
  esac
  [ "$#" -gt 0 ] || die "fetch: no URL for ${sha}"
  local dir="${CACHE_DIR}/sha256" f part src
  f="${dir}/${sha}"
  mkdir -p "${dir}"
  if [ -e "${f}" ]; then
    if _sha256_ok "${sha}" "${f}"; then printf '%s\n' "${f}"; return 0; fi
    warn "cached ${f} no longer matches its sha256 -- dropped"
    rm -f "${f}"
  fi
  part="${f}.part.$$"
  for src in ${A7S_DOWNLOAD_MIRROR:+"${A7S_DOWNLOAD_MIRROR%/}/${sha}"} "$@"; do
    rm -f "${part}"
    if ! curl -fsSL --retry 4 --retry-all-errors --retry-delay 5 \
         --connect-timeout 30 --max-time "${A7S_FETCH_MAX_TIME:-3600}" \
         -o "${part}" "${src}" >&2; then
      warn "download failed: ${src}"
      continue
    fi
    if _sha256_ok "${sha}" "${part}"; then
      mv -f "${part}" "${f}"
      log "fetched ${src} (sha256 ${sha:0:16}... verified)" >&2
      printf '%s\n' "${f}"
      return 0
    fi
    warn "sha256 mismatch, discarded: ${src} (got $(sha256sum "${part}" | cut -c1-16)..., want ${sha:0:16}...)"
  done
  rm -f "${part}"
  die "no source delivered sha256 ${sha} (tried: ${A7S_DOWNLOAD_MIRROR:+mirror }$*)"
}

# fetch_verified <sha256> <dest> <url> [<url>...]
# Put the file with this sha256 at <dest>. The copy is verified again before it
# is renamed into place, so <dest> never exists with other content.
fetch_verified() {
  local sha="$1" dest="$2" f; shift 2
  [ -n "${dest}" ] || die "fetch_verified: no destination"
  f="$(fetch_cached "${sha}" "$@")" || exit 1
  mkdir -p "$(dirname "${dest}")"
  cp --reflink=auto "${f}" "${dest}.part.$$"
  _sha256_ok "${sha}" "${dest}.part.$$" || { rm -f "${dest}.part.$$"; die "fetch_verified: copy of ${f} does not match ${sha}"; }
  mv -f "${dest}.part.$$" "${dest}"
}

# git_fetch_pinned <url> <commit> <dest>
# Check out exactly <commit> (a full commit id) of <url> at <dest>, without
# history. Objects are kept in a bare repository under CACHE_DIR/git/ so a second
# build does not fetch again; <dest> is recreated from it and is self-contained.
# Git verifies every object against its id while fetching (transfer.fsckObjects),
# and HEAD is checked against <commit> at the end.
git_fetch_pinned() {
  local url="$1" commit="$2" dest="$3" cache try
  case "${#commit}" in
    40|64) [ -z "${commit//[0-9a-f]/}" ] || die "git_fetch_pinned: '${commit}' is not a full commit id" ;;
    *) die "git_fetch_pinned: '${commit}' is not a full commit id (need all 40 hex digits)" ;;
  esac
  [ -n "${dest}" ] || die "git_fetch_pinned: no destination"
  cache="${CACHE_DIR}/git/$(printf '%s' "${url}" | sha256sum | cut -c1-16).git"
  [ -d "${cache}" ] || git init -q --bare "${cache}"
  if ! git -C "${cache}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
    for try in 1 2 3 4; do
      if git -C "${cache}" -c transfer.fsckObjects=true fetch -q --no-tags --depth 1 "${url}" "${commit}"; then
        break
      fi
      [ "${try}" = 4 ] && die "git_fetch_pinned: ${url} did not deliver ${commit}"
      warn "git fetch of ${commit} from ${url} failed (attempt ${try}), retrying"
      sleep $((try * 5))
    done
    git -C "${cache}" cat-file -e "${commit}^{commit}" \
      || die "git_fetch_pinned: ${url} answered, but ${commit} is not a commit"
  fi
  git -C "${cache}" update-ref "refs/a7s/${commit}" "${commit}"
  rm -rf "${dest}"
  mkdir -p "$(dirname "${dest}")"
  git init -q "${dest}"
  git -C "${dest}" fetch -q --no-tags --depth 1 "file://${cache}" "refs/a7s/${commit}"
  git -C "${dest}" checkout -q --detach FETCH_HEAD
  [ "$(git -C "${dest}" rev-parse HEAD)" = "${commit}" ] \
    || die "git_fetch_pinned: ${dest} is at $(git -C "${dest}" rev-parse HEAD), not ${commit}"
  log "${url} @ ${commit:0:12} -> ${dest}"
}
