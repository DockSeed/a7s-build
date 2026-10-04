#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only OR MIT
#
# a7s-build: build a bootable Debian image for the Radxa Cubie A7S.
#
# This is the only script that runs on the host. It needs bash, coreutils, git
# and podman or docker; everything else happens in a builder container defined
# by container/ (see docs/building.md). Run ./build.sh --help for usage.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${REPO}/config/defaults.conf"
# Read by this script only; never passed into the container.
HOST_ONLY=" A7S_ENGINE A7S_WORK A7S_OUT A7S_CACHE "
IMAGE_REPO="localhost/a7s-builder"

die() { printf 'build.sh: error: %s\n' "$*" >&2; exit 1; }
log() { printf '=== %s\n' "$*" >&2; }

# --- help -------------------------------------------------------------------

# Print every switch of config/defaults.conf with its default and comment.
print_switches() {
  local line doc="" name def
  while IFS= read -r line; do
    case "${line}" in
      '# --- derived'*) break ;;
      '# ---'*)
        line="${line#'# --- '}"; printf '\n  [%s]\n' "${line%% -*}"; doc="" ;;
      '#'*) doc+="${line#'#'}"$'\n' ;;
      A7S_*=*)
        name="${line%%=*}"
        def="$(sed -n 's/^[^=]*="\${[A-Z0-9_]*:-\(.*\)}"$/\1/p' <<<"${line}")"
        printf '  %s=%s\n' "${name}" "${def:-<empty>}"
        printf '%s' "${doc}" | sed 's/^ */        /'
        doc="" ;;
      *) doc="" ;;
    esac
  done < <(sed -n '/^# --- host/,$p' "${CONF}")
}

print_stages() {
  local f
  shopt -s nullglob
  for f in "${REPO}"/scripts/stages/*.sh "${REPO}"/scripts/distro/*/*.sh; do
    sed -n 's/^\(stage_[a-z0-9_]*\)[[:space:]]*()[[:space:]]*{.*/\1/p' "${f}"
  done | sed 's/^stage_//; s/_/-/g' | sort -u | tr '\n' ' '
  shopt -u nullglob
}

usage() {
  cat <<EOF
Usage:
  ./build.sh [<stage>...]          run stages in the builder container (default: all)
  ./build.sh shell [<cmd> [<arg>...]]
                                   interactive shell (or one command) in the builder
  ./build.sh --help                this text

Built-in stages:
  all     the whole chain: bootchain kernel wifi gpu-firmware orc
          xfwm4(A7S_DESKTOP=1) rootfs image compress
  pins    print the pinned inputs
  clean   delete everything under the work directory
Stages defined in scripts/: $(print_stages)

Switches are environment variables (e.g. A7S_DESKTOP=1 ./build.sh); the
defaults live in config/defaults.conf:
EOF
  print_switches
  cat <<EOF

Requirements, disk space and the reproducibility contract: docs/building.md,
docs/reproducibility.md.
EOF
}

# --- engine -----------------------------------------------------------------

pick_engine() {
  ENGINE="${A7S_ENGINE:-}"
  if [ -z "${ENGINE}" ]; then
    if command -v podman >/dev/null 2>&1; then ENGINE=podman
    elif command -v docker >/dev/null 2>&1; then ENGINE=docker
    else die "neither podman nor docker is installed (see docs/building.md)"; fi
  fi
  case "${ENGINE}" in podman|docker) ;; *) die "A7S_ENGINE must be podman or docker, not '${ENGINE}'" ;; esac
  command -v "${ENGINE}" >/dev/null 2>&1 || die "A7S_ENGINE=${ENGINE}, but ${ENGINE} is not installed"
  # Rootless engines map the container's root to the invoking user, so what the
  # build writes is the user's anyway. A rootful engine writes as the host's
  # root; the container then hands the artefacts back (scripts/inner.sh).
  ROOTLESS=false
  case "${ENGINE}" in
    podman) [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = true ] && ROOTLESS=true ;;
    docker) docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless && ROOTLESS=true ;;
  esac
  return 0
}

# The builder image tag is a hash over everything in container/: any change to
# the Containerfile, a package list or the lock gives a new tag and a rebuild.
builder_tag() {
  local h
  h="$(cd "${REPO}/container" \
       && find . -type f ! -name '*~' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum \
       | sha256sum | cut -c1-16)"
  printf '%s:%s' "${IMAGE_REPO}" "${h}"
}

ensure_builder() {
  TAG="$(builder_tag)"
  if "${ENGINE}" image inspect "${TAG}" >/dev/null 2>&1; then
    return 0
  fi
  log "building the builder image ${TAG} (once per change to container/)"
  local opts=()
  # podman: the RUN containers get the same SELinux treatment as the build
  # container (docker's BuildKit has no such option and needs none).
  [ "${ENGINE}" != podman ] || opts+=(--security-opt label=disable)
  "${ENGINE}" build "${opts[@]}" -t "${TAG}" -f "${REPO}/container/Containerfile" "${REPO}/container" \
    || die "building the builder image failed"
}

# --- paths and identity -------------------------------------------------------

abs_dir() {  # <path relative to the repository or absolute>
  local p="$1"
  case "${p}" in /*) ;; *) p="${REPO}/${p}" ;; esac
  mkdir -p "${p}" || die "cannot create ${p}"
  (cd "${p}" && pwd)
}

build_identity() {
  if git -C "${REPO}" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    [ -n "${A7S_SOURCE_DATE_EPOCH:-}" ] || A7S_SOURCE_DATE_EPOCH="$(git -C "${REPO}" log -1 --format=%ct)"
    if [ -z "${A7S_BUILD_COMMIT:-}" ]; then
      A7S_BUILD_COMMIT="$(git -C "${REPO}" rev-parse HEAD)"
      [ -z "$(git -C "${REPO}" status --porcelain 2>/dev/null)" ] || A7S_BUILD_COMMIT+="-dirty"
    fi
  fi
  export A7S_SOURCE_DATE_EPOCH="${A7S_SOURCE_DATE_EPOCH:-}" A7S_BUILD_COMMIT="${A7S_BUILD_COMMIT:-}"
}

# Close every inherited file descriptor above stderr (a lock held by the caller,
# say), so none of them leaks into the engine and its helpers: SELinux denies a
# confined helper such as podman's network helper access to foreign fds, and a
# leaked lock would be held for as long as the container runs. Bash's own fd 255
# is close-on-exec already.
close_inherited_fds() {
  local fd n
  for fd in "/proc/$$/fd/"*; do
    n="${fd##*/}"
    case "${n}" in 0|1|2|255) continue ;; esac
    eval "exec ${n}>&-" 2>/dev/null || true
  done
}

# --- main -------------------------------------------------------------------

main() {
  local a
  close_inherited_fds
  for a in "$@"; do
    case "${a}" in -h|--help|help) usage; exit 0 ;; esac
  done
  [ "$#" -gt 0 ] || set -- all

  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) die "host architecture $(uname -m) is not supported (x86_64 or aarch64)" ;;
  esac

  pick_engine
  build_identity
  local work out cache
  work="$(abs_dir "${A7S_WORK:-work}")"
  out="$(abs_dir "${A7S_OUT:-out}")"
  cache="$(abs_dir "${A7S_CACHE:-cache}")"
  ensure_builder

  local run=(run --rm --init
    # binfmt_misc and the build's own user namespace need CAP_SYS_ADMIN inside
    # the container (scripts/inner.sh explains what it does with it).
    --cap-add SYS_ADMIN
    # SELinux: no relabeling of the user's directories (:z would rewrite their
    # labels for good); the container runs without SELinux separation instead.
    --security-opt label=disable
    # AppArmor's default container profile forbids every mount, including
    # binfmt_misc; on hosts without AppArmor this has no effect.
    --security-opt apparmor=unconfined
    -v "${REPO}:/src:ro"
    -v "${work}:/work"
    -v "${out}:/out"
    -v "${cache}:/cache"
    -e SRC=/src -e WORK_DIR=/work -e OUT_DIR=/out -e CACHE_DIR=/cache
    -w /src)
  if [ -t 0 ] && [ -t 1 ]; then run+=(-it); elif [ "$1" = shell ]; then run+=(-i); fi
  if [ "${ROOTLESS}" = false ] && [ "$(id -u)" != 0 ]; then
    run+=(-e "_A7S_HOST_UID=$(id -u)" -e "_A7S_HOST_GID=$(id -g)")
  fi

  # Pass through the documented switches that are set, and nothing else.
  local name
  for name in $(sed -n 's/^\(A7S_[A-Z0-9_]*\)=.*/\1/p' "${CONF}"); do
    case "${HOST_ONLY}" in *" ${name} "*) continue ;; esac
    [ -n "${!name+x}" ] || continue
    run+=(-e "${name}=${!name}")
  done

  log "${ENGINE} ($([ "${ROOTLESS}" = true ] && echo rootless || echo rootful)), builder ${TAG}, stages: $*"
  exec "${ENGINE}" "${run[@]}" "${TAG}" bash /src/scripts/inner.sh "$@"
}

main "$@"
