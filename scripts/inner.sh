#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only OR MIT
#
# Runs inside the build container; ../build.sh starts it. Usage:
#
#   inner.sh <stage> [<stage>...]   run the stages in this order
#   inner.sh all                    the whole chain (see ALL_CHAIN below)
#   inner.sh pins                   print the pinned inputs
#   inner.sh clean                  delete everything under WORK_DIR
#   inner.sh shell [<cmd> [<arg>...]]
#                                   an interactive shell (or one command) in the
#                                   build environment
#
# Every stage is a function stage_<name> (dashes become underscores) defined by
# scripts/stages/*.sh or scripts/distro/${A7S_DISTRO}/*.sh.
#
# arm64 emulation. The root filesystem is arm64, so a build on another
# architecture has to run arm64 programs. This script never registers anything
# with the host: it starts the build in a child user namespace of the
# container, mounts a private binfmt_misc instance there (Linux >= 6.7 gives
# every user namespace its own) and registers the builder's qemu-aarch64 in it.
# The handler is visible only to the build's processes and disappears with
# them; the host's /proc/sys/fs/binfmt_misc and the container engine's are left
# alone. This works the same under rootless podman and rootful docker (where the
# container shares the host's user namespace, so a mount there would reach the
# host's global instance -- the child namespace is what keeps it private).
# Fallback: a handler that is already active (registered on the host with the F
# flag). Nothing is ever registered in the container's own user namespace (see
# emulation_plan). Without either the build stops and says how to fix it.
# The child user namespace is used on aarch64 builders too (without binfmt), so
# stages see the same privileges on every host and engine.
set -euo pipefail

SRC="${SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SRC
# shellcheck source=lib/common.sh
. "${SRC}/scripts/lib/common.sh"

# The full chain, in build order. xfwm4 runs only when switched on.
ALL_CHAIN=(bootchain kernel wifi gpu-firmware orc xfwm4 rootfs image compress)

ARM64_LDSO=/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1
QEMU_BINFMT_CONF=/usr/lib/binfmt.d/qemu-aarch64.conf
BINFMT_DIR=/proc/sys/fs/binfmt_misc
# The child user namespace maps every id of the container's namespace to
# itself (--map-users=all copies the parent's map extent by extent; one
# 0:0:65536 extent would fail under rootless podman, whose map has two extents),
# with a private mount namespace (unshare's default propagation is private).
USERNS_LAUNCHER=(unshare --user --map-users=all --map-groups=all --mount --propagation private
                 -- env _A7S_IN_CHILD_USERNS=1)

# --- arm64 emulation ----------------------------------------------------------

# An arm64 program from the builder itself (libc6:arm64's dynamic loader).
arm64_runs() { [ -x "${ARM64_LDSO}" ] && "${ARM64_LDSO}" --version >/dev/null 2>&1; }


# Mount a fresh binfmt_misc instance and register qemu-aarch64 in it. Only ever
# called in the child user namespace, whose instance is new and dies with it.
binfmt_register() {
  [ "${_A7S_IN_CHILD_USERNS:-}" = 1 ] || die "internal: refusing to register binfmt outside the build's own user namespace"
  mount -t binfmt_misc binfmt_misc "${BINFMT_DIR}" \
    || die "mounting binfmt_misc failed although the probe succeeded"
  if [ ! -e "${BINFMT_DIR}/qemu-aarch64" ]; then
    [ -r "${QEMU_BINFMT_CONF}" ] || die "${QEMU_BINFMT_CONF} missing -- the builder image lacks qemu-user-static"
    grep -v '^#' "${QEMU_BINFMT_CONF}" | grep . > "${BINFMT_DIR}/register" \
      || die "registering qemu-aarch64 in the private binfmt_misc instance failed"
  fi
  grep -qx enabled "${BINFMT_DIR}/qemu-aarch64" || die "qemu-aarch64 handler is registered but disabled"
}

no_emulation() {  # <why>
  local kv; kv="$(uname -r)"
  die "arm64 programs cannot run in this build on a $(uname -m) host (kernel ${kv}).
  A private qemu-aarch64 handler needs Linux >= 6.7 and a container allowed to create a
  user namespace and to mount (build.sh asks for that). The probe said: ${1:-nothing}
  Fix, either: run the build on Linux >= 6.7, or register qemu-aarch64 on the host once
  (the build then uses it):
    Debian/Ubuntu: sudo apt-get install qemu-user-static binfmt-support
    Fedora:        sudo dnf install qemu-user-static-aarch64
    Arch:          sudo pacman -S qemu-user-static qemu-user-static-binfmt"
}

# Outer phase: decide where the build runs and how arm64 programs run there.
# Sets _A7S_USERNS (1: the inner phase runs in a child user namespace; tried on
# every host so that every build sees the same privileges: no mknod, no fresh
# proc/sysfs, mounts and chroot allowed) and _A7S_EMULATION:
#   native         aarch64 builder, nothing to emulate
#   userns         private binfmt_misc instance in the child user namespace
#   inherited      a handler registered outside the container is already active
#                  (on the host, with the F flag); found through the user
#                  namespace's ancestors, so it works in the child namespace too
# Nothing is ever registered in the container's own user namespace: under
# rootless podman every container of the user shares that one, and its
# binfmt_misc instance outlives the container (it lives as long as podman's
# pause process), so a handler there would leak into the user's other
# containers -- and, on an SELinux host, make their arm64 programs fail with
# AVC denials on an interpreter labelled for this container.
emulation_plan() {
  local probe="child user namespace not available"
  _A7S_USERNS=0
  if "${USERNS_LAUNCHER[@]}" true 2>/dev/null; then
    _A7S_USERNS=1
  else
    warn "the container may not create a user namespace; stages run directly in the container's (mount and device rules then follow the engine)"
  fi
  if [ "$(uname -m)" = aarch64 ]; then
    _A7S_EMULATION=native; return 0
  fi
  if [ "${_A7S_USERNS}" = 1 ] \
     && probe="$("${USERNS_LAUNCHER[@]}" mount -t binfmt_misc binfmt_misc "${BINFMT_DIR}" 2>&1)"; then
    _A7S_EMULATION=userns; return 0
  fi
  if arm64_runs; then
    _A7S_EMULATION=inherited; return 0
  fi
  no_emulation "${probe}"
}

# Inner phase: register the private handler (userns mode) and prove that an
# arm64 program runs before any stage does.
emulation_setup() {
  case "${_A7S_EMULATION}" in
    native) return 0 ;;
    userns)
      binfmt_register
      log "arm64 emulation: qemu-aarch64 in a private binfmt_misc instance (child user namespace; host untouched)" ;;
    inherited)
      log "arm64 emulation: a qemu-aarch64 handler registered outside the container is active; using it" ;;
    *) die "internal: unknown emulation mode '${_A7S_EMULATION}'" ;;
  esac
  arm64_runs || die "arm64 emulation (${_A7S_EMULATION}) is set up, but ${ARM64_LDSO} does not run"
}

# --- stages -----------------------------------------------------------------

load_stages() {
  local f
  shopt -s nullglob
  [ -d "${SRC}/scripts/distro/${A7S_DISTRO}" ] || die "A7S_DISTRO=${A7S_DISTRO}: there is no scripts/distro/${A7S_DISTRO}/"
  for f in "${SRC}"/scripts/stages/*.sh "${SRC}/scripts/distro/${A7S_DISTRO}"/*.sh; do
    # shellcheck source=/dev/null
    . "${f}"
  done
  shopt -u nullglob
}

stage_list() {
  declare -F | awk '{print $3}' | sed -n 's/^stage_//p' | tr _ - | sort
}

infra_pins() {
  local base lock_ts
  base="$(sed -n 's/^FROM[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "${SRC}/container/Containerfile" | head -n1)"
  lock_ts="$(sed -n 's/^# snapshot \([0-9TZ]*\)$/\1/p' "${SRC}/container/packages.lock")"
  log "builder  : ${base}"
  log "           packages: snapshot.debian.org ${lock_ts}, $(grep -c "^$(dpkg --print-architecture) " "${SRC}/container/packages.lock") locked for $(dpkg --print-architecture) (container/packages.lock)"
  log "           qemu-user: $(dpkg-query -W -f='${Version}' qemu-user 2>/dev/null || echo none)"
  log "rootfs   : ${A7S_DISTRO} ${A7S_SUITE} from ${DEBIAN_MIRROR}"
  log "build    : commit ${A7S_BUILD_COMMIT}, SOURCE_DATE_EPOCH ${SOURCE_DATE_EPOCH} ($(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ))"
  log "switches : DESKTOP=${A7S_DESKTOP} JOBS=${A7S_JOBS} IMAGE=${A7S_IMAGE_NAME}"
  log "emulation: ${_A7S_EMULATION:-native}, child user namespace: ${_A7S_USERNS:-0}"
}

run_pins() {
  local fn
  infra_pins
  # Each stage group may print its own pins with a pins_<group> function.
  for fn in $(declare -F | awk '{print $3}' | grep '^pins_' | sort); do "${fn}"; done
}

run_all() {
  local s missing=()
  for s in "${ALL_CHAIN[@]}"; do
    case "${s}" in
      xfwm4) [ "${A7S_DESKTOP}" = 1 ] || { log "skip xfwm4 (A7S_DESKTOP=${A7S_DESKTOP})"; continue; } ;;
    esac
    if have_stage "${s}"; then
      run_stage "${s}"
    else
      warn "stage '${s}' is not implemented yet (no $(stage_fn "${s}")()) -- skipped"
      missing+=("${s}")
    fi
  done
  [ "${#missing[@]}" = 0 ] || die "chain incomplete, no stage function for: ${missing[*]}"
  log "all stages done; artefacts in ${OUT_DIR}"
}

run_clean() {
  log "removing everything under ${WORK_DIR}"
  find "${WORK_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

run_shell() {
  if [ "$#" -gt 0 ]; then exec "$@"; fi
  local rc="${TMPDIR}/a7s-shellrc"
  {
    printf '[ -r /etc/bash.bashrc ] && . /etc/bash.bashrc\n'
    printf '. %q\n' "${SRC}/scripts/lib/common.sh"
    printf 'shopt -s nullglob; for f in %q/scripts/stages/*.sh %q/scripts/distro/%q/*.sh; do . "$f"; done; shopt -u nullglob; unset f\n' \
      "${SRC}" "${SRC}" "${A7S_DISTRO}"
    printf 'PS1=%q\n' '[a7s-build \W]\$ '
  } > "${rc}"
  log "build shell: SRC=${SRC} (read-only) WORK_DIR=${WORK_DIR} OUT_DIR=${OUT_DIR} CACHE_DIR=${CACHE_DIR}; helpers and stage_* functions are defined"
  exec bash --rcfile "${rc}" -i
}

inner_main() {
  emulation_setup
  [ "$#" -gt 0 ] || set -- all
  case "$1" in
    shell) shift; run_shell "$@" ;;
  esac
  load_stages
  local s
  for s in "$@"; do
    case "${s}" in
      all)   run_all ;;
      pins)  run_pins ;;
      clean) run_clean ;;
      *)
        if ! have_stage "${s}"; then
          die "unknown stage '${s}'. Stages: all pins clean shell $(stage_list | tr '\n' ' ')"
        fi
        run_stage "${s}" ;;
    esac
  done
}

# Under a rootful engine the container's root is the host's root: hand what the
# build wrote back to the user who started it. WORK_DIR keeps its owners on
# purpose (a root filesystem must stay root's); ./build.sh clean removes it.
fix_ownership() {
  [ -n "${_A7S_HOST_UID:-}" ] || return 0
  chown -R "${_A7S_HOST_UID}:${_A7S_HOST_GID:-${_A7S_HOST_UID}}" "${OUT_DIR}" "${CACHE_DIR}" || warn "could not hand ${OUT_DIR} / ${CACHE_DIR} back to uid ${_A7S_HOST_UID}"
  chown "${_A7S_HOST_UID}:${_A7S_HOST_GID:-${_A7S_HOST_UID}}" "${WORK_DIR}" || true
}

a7s_env_setup

if [ "${_A7S_PHASE:-outer}" = inner ]; then
  inner_main "$@"
  exit 0
fi

# Outer phase: pick the emulation, then run the inner phase as a separate
# process (in the child user namespace when there is one) so its errexit and
# exit status stay its own, and fix ownership afterwards whatever happened.
emulation_plan
export _A7S_EMULATION _A7S_USERNS _A7S_PHASE=inner
launcher=()
[ "${_A7S_USERNS}" != 1 ] || launcher=("${USERNS_LAUNCHER[@]}")
rc=0
"${launcher[@]}" bash "${BASH_SOURCE[0]}" "$@" || rc=$?
fix_ownership
exit "${rc}"
