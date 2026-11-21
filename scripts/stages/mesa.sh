# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# Mesa stages: fetch-mesa, build-mesa, check-mesa-debs. Sourced by
# scripts/inner.sh. Part of every image: kmscon needs libgbm1, and the GPU's
# Vulkan driver and zink are in the same packages.
#
# The image carries our Mesa instead of Debian's: Mesa 26.3.0 with
# userspace/mesa/patches/ (backports from Mesa's staging/26.3 and main
# branches, then changes of our own to the PowerVR driver and compiler, zink,
# NIR, the GL state tracker and the dril target), packaged from Debian's own mesa source 26.2.6-1 with
# userspace/mesa/debian.diff on top. The diff cuts the driver set down to what
# this board uses (softpipe, llvmpipe, zink, the PowerVR Vulkan driver,
# lavapipe, the device-select layer), builds against trixie's LLVM 19, names
# our maintainer and bug tracker and keeps Debian's as XSBC-Original-*, and adds
# the copyright notices of the shipped sources. Every binary package built
# from the mesa source carries MESA_DEB_VERSION, and the image installs those
# packages instead of Debian's (scripts/distro/debian/distro.sh): there is one
# Mesa in the image, never ours beside Debian's.
#
# Inputs, each pinned by sha256 (the sha256 decides, whichever URL delivers).
# The build checks only these sums, no signature; the signatures were checked
# once, when the sums were written here:
#   - the release tarball mesa-26.3.0.tar.xz, signed by the Mesa release key
#     71C4B75620BC75708B4BDB254C95FAAB3EB073EC (mesa-26.3.0.tar.xz.sig beside it);
#   - Debian's mesa_26.2.6-1.debian.tar.xz and wayland-protocols_1.50-1_all.deb,
#     both listed with these sums in the signed index of unstable at
#     snapshot.debian.org 20261115T000000Z (InRelease, checked with gpgv
#     against the Debian archive key).
# The patches and debian.diff are pinned by content as well (patches.sha256,
# MESA_DEBIAN_DIFF_SHA256): a changed file is a different artefact from the
# one tested.
#
# The build runs in a Debian chroot of its own like build-xfwm4's, for the
# same reason: the build dependencies (LLVM, clang, libclc, the -dev packages,
# on an amd64 builder their :arm64 versions) would change the shared builder.
# On an amd64 builder it is a cross build (-a arm64), on an arm64 builder a
# native one with the same steps minus the arm64 LLVM under qemu-user.
#
# The version sorts above Debian's and trixie-backports' Mesa of the same or an
# older upstream release (26.3.0-1+a7s2 > 26.1.6-1~bpo13+1 > 25.0.7-2+deb13u1).
# The image pins it at 990 (preferences.d/mesa-a7s), so apt keeps it whatever
# Debian publishes: a Mesa security fix has to be built here.
MESA_VERSION="26.3.0"
MESA_DEB_VERSION="26.3.0-1+a7s2"
MESA_TARBALL="mesa-${MESA_VERSION}.tar.xz"
MESA_TARBALL_SHA256="91d729aa68bb89e4ec857841300bbe922bcb3e52b1f97566ca83930d3b28343a"
MESA_TARBALL_URLS=(
  "https://archive.mesa3d.org/${MESA_TARBALL}"
  "https://archive.mesa3d.org/older-versions/${MESA_VERSION%%.*}.x/${MESA_TARBALL}"
)
MESA_DEBIAN_SOURCE_VERSION="26.2.6-1"
MESA_DEBIAN_TAR="mesa_${MESA_DEBIAN_SOURCE_VERSION}.debian.tar.xz"
MESA_DEBIAN_TAR_SHA256="c70cdc39e77f45af38688f6d2131956b607fd476d1afafcb00136c6e3fa91f91"
MESA_WLP_DEB="wayland-protocols_1.50-1_all.deb"
MESA_WLP_SHA256="ea24430b820a4563a7879428d1cdd57afec5f5da13dbde743649d199e9559dbf"
MESA_DEBIAN_SNAPSHOT_URL="https://snapshot.debian.org/archive/debian/20261115T000000Z"
MESA_DEBIAN_DIFF_SHA256="24ddbc89c40eca280c67e65fb9162fd7c7952cdda2a1adf97d7661a467abc187"
MESA_LLVM="19"
# The one changelog entry build-mesa puts on top of Debian's, fixed text and
# fixed date. The date becomes SOURCE_DATE_EPOCH of the package build (see
# XFWM4_CHANGELOG_DATE for why it must lie before any build).
MESA_CHANGELOG_DATE="Tue, 17 Nov 2026 00:00:00 +0000"
# debian.diff sets these in debian/control.in; build-mesa checks every package.
MESA_ORIG_MAINTAINER="Debian X Strike Force <debian-x@lists.debian.org>"
MESA_BUGS_URL="https://github.com/DockSeed/a7s-build/issues"
# What the build makes, and what of it the image installs. The runtime set is
# scripts/distro/debian/packages.sh's MESA_IMAGE_PACKAGES; the -dev packages
# are build artefacts only (OUT_DIR/mesa-dev), never in the image.
MESA_RUNTIME_PACKAGES=(
  libgbm1 libegl-mesa0 libglx-mesa0 libgl1-mesa-dri
  mesa-libgallium mesa-va-drivers mesa-vdpau-drivers mesa-vulkan-drivers
)
MESA_DEV_PACKAGES=(libgbm-dev libegl1-mesa-dev libgles2-mesa-dev libgl1-mesa-dev mesa-common-dev)

# shellcheck source=../lib/series.sh
. "${SRC}/scripts/lib/series.sh"

pins_mesa() {
  log "mesa     : ${MESA_DEB_VERSION} (Mesa ${MESA_VERSION}, sha256 ${MESA_TARBALL_SHA256}; Debian ${MESA_DEBIAN_SOURCE_VERSION}'s debian/, sha256 ${MESA_DEBIAN_TAR_SHA256}), + userspace/mesa/debian.diff, + $(grep -c . "${SRC}/userspace/mesa/patches.sha256") patch(es) in userspace/mesa/patches/"
}

# --- checks of a built package (also run by build-mesa) --------------------------

# Reads <deb>'s control fields and fails unless it is one of ours: built from
# the mesa source at MESA_DEB_VERSION, for arm64, with our Maintainer and Bugs
# and Debian's maintainer kept as Original-Maintainer.
mesa_check_deb() {  # <deb>
  local deb="$1" f v
  [ -f "${deb}" ] || die "mesa check: no such file ${deb}"
  for f in Package Version Architecture; do
    log "mesa check: ${deb##*/}: ${f}: $(dpkg-deb -f "${deb}" "${f}")"
  done
  v="$(dpkg-deb -f "${deb}" Version)"
  [ "${v}" = "${MESA_DEB_VERSION}" ] \
    || die "mesa check: ${deb##*/} is version ${v}, not ${MESA_DEB_VERSION} -- Debian's package, not ours"
  [ "$(dpkg-deb -f "${deb}" Source)" = "mesa" ] \
    || die "mesa check: ${deb##*/} names the source '$(dpkg-deb -f "${deb}" Source)', not mesa"
  [ "$(dpkg-deb -f "${deb}" Architecture)" = arm64 ] || die "mesa check: ${deb##*/} is not an arm64 package"
  [ "$(dpkg-deb -f "${deb}" Maintainer)" = "${A7S_MAINTAINER}" ] \
    && [ "$(dpkg-deb -f "${deb}" Original-Maintainer)" = "${MESA_ORIG_MAINTAINER}" ] \
    || die "mesa check: ${deb##*/} has Maintainer '$(dpkg-deb -f "${deb}" Maintainer)', Original-Maintainer '$(dpkg-deb -f "${deb}" Original-Maintainer)'"
  [ "$(dpkg-deb -f "${deb}" Bugs)" = "${MESA_BUGS_URL}" ] || die "mesa check: ${deb##*/} has Bugs '$(dpkg-deb -f "${deb}" Bugs)'"
  [ -z "$(dpkg-deb -f "${deb}" Uploaders)" ] || die "mesa check: ${deb##*/} names Uploaders (Debian's belong in XSBC-Original-Uploaders)"
}

# The set in <dir>: exactly MESA_RUNTIME_PACKAGES + MESA_DEV_PACKAGES, each
# passing mesa_check_deb, and the content the image relies on: one libgallium,
# the PowerVR Vulkan driver and its ICD manifest, zink's drirc defaults, the
# sun60i-kms entry of the dril target with the symbol AIGLX looks up, and the
# copyright notices debian.diff adds.
mesa_check_debs() {  # <dir>
  local dir="$1" p deb n want x all syms
  local -a expect=("${MESA_RUNTIME_PACKAGES[@]}" "${MESA_DEV_PACKAGES[@]}")
  n="$(find "${dir}" -maxdepth 1 -name '*.deb' | wc -l)"
  [ "${n}" = "${#expect[@]}" ] || die "mesa check: ${dir} holds ${n} packages, expected ${#expect[@]} (${expect[*]})"
  for p in "${expect[@]}"; do
    deb="${dir}/${p}_${MESA_DEB_VERSION}_arm64.deb"
    [ -f "${deb}" ] || die "mesa check: no ${deb##*/}"
    mesa_check_deb "${deb}"
  done
  all="$(for p in "${expect[@]}"; do dpkg-deb -c "${dir}/${p}_${MESA_DEB_VERSION}_arm64.deb"; done)"
  n="$(grep -cE '/libgallium-[^/]*\.so$' <<<"${all}" || true)"
  [ "${n}" = 1 ] || die "mesa check: ${n} libgallium-*.so in the packages, expected exactly one"
  for want in 'usr/lib/aarch64-linux-gnu/libvulkan_powervr_mesa\.so$' 'usr/share/vulkan/icd\.d/powervr_mesa_icd.*\.json$' \
              'usr/lib/aarch64-linux-gnu/dri/sun60i-kms_dri\.so' 'usr/share/drirc\.d/00-zink-defaults\.conf$'; do
    grep -qE "${want}" <<<"${all}" || die "mesa check: no file matching ${want} in the packages"
  done
  x="$(mktemp -d)"
  dpkg-deb -x "${dir}/libgl1-mesa-dri_${MESA_DEB_VERSION}_arm64.deb" "${x}"
  # Into a variable first: under pipefail, grep -q leaving early can kill
  # readelf with SIGPIPE and fail the check although the symbol is there.
  syms="$(readelf -W --dyn-syms "${x}/usr/lib/aarch64-linux-gnu/dri/libdril_dri.so" 2>/dev/null || true)"
  grep -Eq '[[:space:]]__driDriverGetExtensions_sun60i_kms(@|$)' <<<"${syms}" \
    || { rm -rf "${x:?}"; die "mesa check: libdril_dri.so does not export __driDriverGetExtensions_sun60i_kms -- AIGLX could not load sun60i-kms"; }
  for want in 'License: BSD-3-clause-softfloat' 'License: BSD-2-clause-xxhash' 'Imagination Technologies Ltd' 'Collabora, Ltd.'; do
    grep -qF "${want}" "${x}/usr/share/doc/libgl1-mesa-dri/copyright" \
      || { rm -rf "${x:?}"; die "mesa check: debian/copyright lacks '${want}'"; }
  done
  rm -rf "${x:?}"
  log "mesa check: ${#expect[@]} packages ${MESA_DEB_VERSION}, one libgallium, PowerVR Vulkan driver + ICD, sun60i-kms dril entry, zink drirc defaults"
}

stage_check_mesa_debs() {
  [ -n "${1:-}" ] || die "usage: inner.sh check-mesa-debs <directory with the 13 Mesa .debs>"
  command -v dpkg-deb >/dev/null && command -v readelf >/dev/null || die "check-mesa-debs needs dpkg-deb and readelf"
  mesa_check_debs "$1"
}

# --- fetch ------------------------------------------------------------------------

# The three pinned downloads into WORK_DIR/mesa/dl; the tarball unpacked into
# WORK_DIR/mesa/src with Debian's debian/ on top and userspace/mesa/debian.diff
# applied; the patch series checked by content, count and order, applied in
# order at fuzz 0 to a copy (WORK_DIR/mesa/clc-src, which build-mesa compiles
# mesa_clc and pco_clc from), and put into debian/patches as the quilt series,
# which dpkg-buildpackage applies itself, at fuzz 0; a changelog entry for
# MESA_DEB_VERSION on top.
stage_fetch_mesa() {
  local dir="${WORK_DIR}/mesa" dl="${WORK_DIR}/mesa/dl" src="${WORK_DIR}/mesa/src" clc="${WORK_DIR}/mesa/clc-src"
  local pdir="${SRC}/userspace/mesa/patches" sums="${SRC}/userspace/mesa/patches.sha256" diff="${SRC}/userspace/mesa/debian.diff"
  local p n i pinned top
  for p in patch tar xz dpkg-parsechangelog; do
    command -v "${p}" >/dev/null || die "fetch-mesa needs '${p}' (container/packages.d/mesa.txt)"
  done
  mkdir -p "${dl}"
  fetch_verified "${MESA_TARBALL_SHA256}" "${dl}/${MESA_TARBALL}" "${MESA_TARBALL_URLS[@]}"
  fetch_verified "${MESA_DEBIAN_TAR_SHA256}" "${dl}/${MESA_DEBIAN_TAR}" \
    "https://deb.debian.org/debian/pool/main/m/mesa/${MESA_DEBIAN_TAR}" \
    "${MESA_DEBIAN_SNAPSHOT_URL}/pool/main/m/mesa/${MESA_DEBIAN_TAR}"
  fetch_verified "${MESA_WLP_SHA256}" "${dl}/${MESA_WLP_DEB}" \
    "https://deb.debian.org/debian/pool/main/w/wayland-protocols/${MESA_WLP_DEB}" \
    "${MESA_DEBIAN_SNAPSHOT_URL}/pool/main/w/wayland-protocols/${MESA_WLP_DEB}"

  # debian.diff and the patches: content, count and order pinned.
  printf '%s  %s\n' "${MESA_DEBIAN_DIFF_SHA256}" "${diff}" | sha256sum -c --quiet - \
    || die "userspace/mesa/debian.diff differs from its pinned sha256 (MESA_DEBIAN_DIFF_SHA256)"
  ( cd "${pdir}" && sha256sum -c --quiet "${sums}" ) \
    || die "mesa patches: a patch differs from its sha256 in userspace/mesa/patches.sha256 -- a changed patch is a different artefact from the one tested"
  local -a pins=()
  mapfile -t pins < <(awk 'NF {print $2}' "${sums}")
  n="$(find "${pdir}" -name '*.patch' | wc -l)"
  [ "${n}" = "${#pins[@]}" ] || die "userspace/mesa/patches holds ${n} patches, ${#pins[@]} are pinned"
  series_load "${pdir}" || die "userspace/mesa/patches/series is missing, empty or malformed"
  [ "${#SERIES[@]}" = "${#pins[@]}" ] || die "mesa patch series lists ${#SERIES[@]} patches, ${#pins[@]} are pinned"
  for i in "${!SERIES[@]}"; do
    pinned="${pins[$i]}"
    [ "${SERIES[$i]}" = "${pinned}" ] || die "mesa patch series entry $((i + 1)) is ${SERIES[$i]}, patches.sha256 says ${pinned}"
  done

  rm -rf "${src:?}" "${clc:?}"
  mkdir -p "${src}"
  tar -xf "${dl}/${MESA_TARBALL}" -C "${src}" --strip-components=1 || die "unpacking ${MESA_TARBALL} failed"
  [ ! -e "${src}/debian" ] || die "${MESA_TARBALL} carries a debian/ directory"
  tar -xf "${dl}/${MESA_DEBIAN_TAR}" -C "${src}" || die "unpacking ${MESA_DEBIAN_TAR} failed"
  [ -f "${src}/debian/rules" ] || die "${MESA_DEBIAN_TAR} has no debian/rules"
  top="$(dpkg-parsechangelog -l "${src}/debian/changelog" -SVersion)"
  [ "${top}" = "${MESA_DEBIAN_SOURCE_VERSION}" ] || die "Debian's debian/ is ${top}, the pin says ${MESA_DEBIAN_SOURCE_VERSION}"
  patch -d "${src}" -p1 --fuzz=0 -s < "${diff}" \
    || die "userspace/mesa/debian.diff does not apply at --fuzz=0 to Debian's ${MESA_DEBIAN_SOURCE_VERSION}"
  [ ! -e "${src}/debian/patches" ] \
    || die "debian/patches still exists after debian.diff -- our series would have to be merged into Debian's"

  # The series in order on a copy: each patch must apply on top of the ones
  # before it. The copy is the source of the native mesa_clc/pco_clc build.
  cp -a "${src}" "${clc}"
  for p in "${SERIES[@]}"; do
    patch -d "${clc}" -p1 --fuzz=0 -s < "${pdir}/${p}" \
      || die "mesa: ${p} does not apply at --fuzz=0 on top of the patches before it"
  done
  install -d "${src}/debian/patches"
  for p in "${SERIES[@]}"; do install -m0644 "${pdir}/${p}" "${src}/debian/patches/${p}"; done
  printf '%s\n' "${SERIES[@]}" > "${src}/debian/patches/series"

  {
    printf 'mesa (%s) %s; urgency=medium\n\n' "${MESA_DEB_VERSION}" "${A7S_SUITE}"
    printf '  * Mesa %s for the Radxa Cubie A7S (PowerVR BXM-4-64), board-minimal\n' "${MESA_VERSION}"
    printf '    driver set: softpipe, llvmpipe, zink, imagination, swrast,\n'
    printf '    device-select; without AMD, rusticl, teflon, NVK, gfxstream, d3d12,\n'
    printf '    drm-shim, VA-API.\n'
    printf "  * debian/ from Debian's %s, adapted; LLVM %s; %s patches in\n" "${MESA_DEBIAN_SOURCE_VERSION}" "${MESA_LLVM}" "${#SERIES[@]}"
    printf '    debian/patches/series.\n'
    printf "  * debian/control: Maintainer %s, Debian's maintainer kept as\n" "${A7S_MAINTAINER%% <*}"
    printf '    XSBC-Original-Maintainer. debian/copyright: BSD notices (SoftFloat,\n'
    printf '    xxHash) and further MIT copyright holders.\n\n'
    printf ' -- %s  %s\n\n' "${A7S_MAINTAINER}" "${MESA_CHANGELOG_DATE}"
    cat "${src}/debian/changelog"
  } > "${src}/debian/changelog.new"
  mv "${src}/debian/changelog.new" "${src}/debian/changelog"
  top="$(dpkg-parsechangelog -l "${src}/debian/changelog" -SVersion)"
  [ "${top}" = "${MESA_DEB_VERSION}" ] || die "debian/changelog starts with ${top}, expected ${MESA_DEB_VERSION}"
  [ "$(sed -n '1,/^$/s/^Maintainer: //p' "${src}/debian/control.in")" = "${A7S_MAINTAINER}" ] \
    || die "debian/control.in does not name ${A7S_MAINTAINER} as maintainer (userspace/mesa/debian.diff)"
  log "mesa: ${MESA_TARBALL} + Debian's ${MESA_DEBIAN_SOURCE_VERSION} debian/ + debian.diff + ${#SERIES[@]} patches -> ${src} (${MESA_DEB_VERSION})"
}

# --- build chroot -----------------------------------------------------------------

# A Debian chroot under WORK_DIR for the build, from the same archive as the
# image (DEBIAN_MIRROR, the snapshot A7S_SNAPSHOT), with <suite>-backports in
# its sources for wayland-scanner only (userspace/mesa/build-in-chroot.sh says
# why; it needs a snapshot from 20261112 on). .a7s-ready records the archive; a
# chroot from another one is made again.
mesa_chroot() {
  local root="${WORK_DIR}/mesa/chroot" host_arch
  host_arch="$(dpkg --print-architecture)"
  if [ "$(cat "${root}/.a7s-ready" 2>/dev/null)" != "${DEBIAN_MIRROR} ${A7S_SUITE} ${host_arch}" ]; then
    command -v mmdebstrap >/dev/null || die "build-mesa needs mmdebstrap (container/packages.d/mesa.txt)"
    rm -rf "${root:?}"
    mkdir -p "${WORK_DIR}/mesa"
    log "mesa: creating the build chroot (${host_arch}, ${A7S_SUITE}, ${DEBIAN_MIRROR})" >&2
    TMPDIR="${WORK_DIR}" mmdebstrap --mode=root --variant=minbase --format=directory \
      --architectures="${host_arch}" --include=ca-certificates,dpkg-dev \
      --aptopt='Acquire::Check-Valid-Until "false"' --aptopt='APT::Install-Recommends "false"' \
      "${A7S_SUITE}" "${root}" "deb ${DEBIAN_MIRROR} ${A7S_SUITE} main" \
      >"${WORK_DIR}/mesa/mmdebstrap.log" 2>&1 \
      || { tail -30 "${WORK_DIR}/mesa/mmdebstrap.log" >&2; die "mesa: creating the build chroot failed"; }
    printf 'Acquire::Check-Valid-Until "false";\nAPT::Install-Recommends "false";\nAcquire::Retries "5";\n' \
      > "${root}/etc/apt/apt.conf.d/99a7s"
    printf 'deb %s %s main\ndeb %s %s-backports main\n' "${DEBIAN_MIRROR}" "${A7S_SUITE}" "${DEBIAN_MIRROR}" "${A7S_SUITE}" \
      > "${root}/etc/apt/sources.list"
    printf '%s\n' "${DEBIAN_MIRROR} ${A7S_SUITE} ${host_arch}" > "${root}/.a7s-ready"
  fi
  printf '%s' "${root}"
}

# Run a command in the build chroot with /dev, /proc and /sys bound in, and
# unbound again whatever the command does (as xfwm4_in_chroot).
mesa_in_chroot() {  # <root> <command...>
  local root="$1" rc=0 d; shift
  for d in dev proc sys; do
    mkdir -p "${root}/${d}"
    mount --rbind "/${d}" "${root}/${d}" || die "mesa: cannot bind /${d} into the build chroot"
  done
  "$@" || rc=$?
  for d in sys proc dev; do umount -R "${root}/${d}" || true; done
  return "${rc}"
}

mesa_chroot_step() {  # <root> <step>
  local root="$1" step="$2" logf="${WORK_DIR}/mesa/chroot-$2.log"
  log "mesa: build step '${step}' in the chroot (log ${logf})"
  mesa_in_chroot "${root}" chroot "${root}" env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LC_ALL=C.UTF-8 \
      A7S_SUITE="${A7S_SUITE}" MESA_LLVM="${MESA_LLVM}" MESA_JOBS="${A7S_JOBS}" MESA_CROSS="${MESA_CROSS}" \
      /bin/bash /build/build-in-chroot.sh "${step}" >"${logf}" 2>&1 \
    || { tail -60 "${logf}" >&2; die "build-mesa: step '${step}' failed (log: ${logf})"; }
}

# --- build ------------------------------------------------------------------------

# Mesa MESA_DEB_VERSION for arm64: dpkg-buildpackage -b on the tree fetch-mesa
# prepared, in the build chroot; cross (-a arm64) on an amd64 builder, native
# on an arm64 builder, as build-xfwm4. What lands in OUT_DIR:
#   OUT_DIR/mesa      the runtime packages (MESA_RUNTIME_PACKAGES) and MESA-ID;
#                     the image installs exactly these
#   OUT_DIR/mesa-dev  the -dev packages, .buildinfo and .changes; build
#                     artefacts, never in the image
stage_build_mesa() {
  local dir="${WORK_DIR}/mesa" dst="${OUT_DIR}/mesa" dev="${OUT_DIR}/mesa-dev" root p f host_arch how MESA_CROSS
  local -a steps=(deps clc build)
  host_arch="$(dpkg --print-architecture)"
  case "${host_arch}" in
    arm64) MESA_CROSS=0; how="native" ;;
    amd64) MESA_CROSS=1; how="cross from ${host_arch}"; steps=(deps clc llvm build) ;;
    *) die "build-mesa: builds on an amd64 (cross) or arm64 (native) builder, not on ${host_arch}" ;;
  esac
  for p in dpkg-deb readelf chroot mount; do
    command -v "${p}" >/dev/null || die "build-mesa needs '${p}'"
  done
  stage_fetch_mesa
  root="$(mesa_chroot)"
  rm -rf "${root:?}/build"
  install -d "${root}/build/dl"
  cp -a "${dir}/src" "${root}/build/src"
  cp -a "${dir}/clc-src" "${root}/build/clc-src"
  install -m0644 "${dir}/dl/${MESA_WLP_DEB}" "${root}/build/dl/"
  install -m0755 "${SRC}/userspace/mesa/build-in-chroot.sh" "${root}/build/build-in-chroot.sh"
  for p in "${steps[@]}"; do mesa_chroot_step "${root}" "${p}"; done

  # Exactly the packages expected, nothing besides.
  for f in "${root}"/build/*.deb; do
    p="${f##*/}"; p="${p%%_*}"
    case " ${MESA_RUNTIME_PACKAGES[*]} ${MESA_DEV_PACKAGES[*]} " in
      *" ${p} "*) ;;
      *) die "build-mesa: the build also produced ${f##*/}, which is neither a runtime nor a -dev package of ours" ;;
    esac
  done
  rm -rf "${dir:?}/debs"
  install -d "${dir}/debs"
  cp "${root}"/build/*.deb "${dir}/debs/"
  mesa_check_debs "${dir}/debs"

  rm -rf "${dst:?}" "${dev:?}"
  install -d -m0755 "${dst}" "${dev}"
  for p in "${MESA_RUNTIME_PACKAGES[@]}"; do install -m0644 "${dir}/debs/${p}_${MESA_DEB_VERSION}_arm64.deb" "${dst}/"; done
  for p in "${MESA_DEV_PACKAGES[@]}"; do install -m0644 "${dir}/debs/${p}_${MESA_DEB_VERSION}_arm64.deb" "${dev}/"; done
  for f in "${root}"/build/*.buildinfo "${root}"/build/*.changes; do
    [ -f "${f}" ] && install -m0644 "${f}" "${dev}/"
  done
  {
    echo "version=${MESA_DEB_VERSION}"
    echo "mesa=${MESA_TARBALL} ${MESA_TARBALL_SHA256}"
    echo "debian_source=${MESA_DEBIAN_TAR} ${MESA_DEBIAN_TAR_SHA256}"
    echo "debian_diff=userspace/mesa/debian.diff ${MESA_DEBIAN_DIFF_SHA256}"
    echo "wayland_protocols=${MESA_WLP_DEB} ${MESA_WLP_SHA256}"
    echo "wayland_scanner=$(sed -n 's/^Version: //p' "${root}/usr/share/pkgconfig/wayland-scanner.pc") (${A7S_SUITE}-backports, build only)"
    awk 'NF {print "patch=" $2 " " $1}' "${SRC}/userspace/mesa/patches.sha256"
    echo "build=dpkg-buildpackage -b for arm64, ${how}, in a dedicated ${A7S_SUITE} chroot from ${DEBIAN_MIRROR}, LLVM ${MESA_LLVM}"
    for p in "${MESA_RUNTIME_PACKAGES[@]}"; do
      f="${p}_${MESA_DEB_VERSION}_arm64.deb"
      echo "deb=${f} $(sha256sum "${dst}/${f}" | cut -d' ' -f1)"
    done
  } > "${dst}/MESA-ID"
  chmod 0644 "${dst}/MESA-ID"
  log "mesa ${MESA_DEB_VERSION}: ${#MESA_RUNTIME_PACKAGES[@]} runtime packages -> ${dst}, ${#MESA_DEV_PACKAGES[@]} -dev packages -> ${dev}"
}

# Group stage run by the full chain (inner.sh all).
stage_mesa() { stage_build_mesa; }
