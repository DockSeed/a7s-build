#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only OR MIT
#
# The steps of build-mesa that run inside its build chroot (scripts/stages/mesa.sh
# copies this file to /build and runs one step at a time, as root of the chroot).
# Not sourced by the stage loader and never run on the builder itself: it
# changes the apt configuration and /opt of the system it runs on.
#
#   build-in-chroot.sh deps    cross: arm64 as foreign architecture; the build
#                              dependencies (cross: native and :arm64),
#                              wayland-scanner from <suite>-backports unpacked
#                              to /opt/a7s-wl, wayland-protocols from /build/dl,
#                              debian/control generated from debian/control.in
#   build-in-chroot.sh clc     mesa_clc, vtn_bindgen2, pco_clc and pdsc_precomp
#                              built for the build machine from /build/clc-src
#                              into /opt/a7s-clc
#   build-in-chroot.sh llvm    cross only: llvm-config of the arm64 LLVM, run
#                              through qemu-user, and the meson cross file
#   build-in-chroot.sh build   dpkg-buildpackage -b in /build/src (cross:
#                              -a arm64)
#
# Environment: A7S_SUITE, MESA_LLVM (LLVM major version), MESA_JOBS, MESA_CROSS
# (1: cross build on a non-arm64 machine, 0: native build on arm64).
#
# Why the pieces are as they are:
#   - mesa_clc and vtn_bindgen2 must run on the build machine; Mesa's cross
#     build takes them from the system (-Dmesa-clc=system,
#     -Dprecomp-compiler=system). pco_clc compiles the USC library that goes
#     into the PowerVR driver, so it is built from the patched tree. The
#     native build takes them the same way, so both builds differ only in
#     the compiler and the target of dpkg-buildpackage.
#   - llvm-19-dev and llvm-19-dev:arm64 conflict, so the arm64 LLVM is only
#     unpacked, and its llvm-config runs under qemu-user with the build
#     machine's root as sysroot (-L /).
#   - wayland-protocols 1.50 needs wayland-scanner >= 1.26 (trixie has 1.23).
#     The scanner is only unpacked: an installed libwayland-bin from backports
#     would pull libwayland-client0 1.26 and, through Multi-Arch, the arm64
#     libraries along, and the packages would then depend on
#     libwayland-client0 (>= 1.24), which trixie does not have.
#   - spirv-tools is not Multi-Arch: same and conflicts with glslang-tools in
#     a cross build; debian/rules builds without it (-Dspirv-tools=disabled).
set -euo pipefail

: "${A7S_SUITE:?}" "${MESA_LLVM:?}" "${MESA_JOBS:?}" "${MESA_CROSS:?}"
case "${MESA_CROSS}" in 0|1) ;; *) printf '::error:: MESA_CROSS must be 0 or 1\n' >&2; exit 1 ;; esac
LLVM="${MESA_LLVM}"
CLC_PREFIX=/opt/a7s-clc
LLVMARM=/opt/a7s-llvm-arm64
WL=/opt/a7s-wl
export DEBIAN_FRONTEND=noninteractive

log() { printf '=== %s\n' "$*"; }
die() { printf '::error:: %s\n' "$*" >&2; exit 1; }

step_deps() {
  local build_arch suffix=""
  build_arch="$(dpkg --print-architecture)"
  if [ "${MESA_CROSS}" = 1 ]; then
    dpkg --add-architecture arm64
    suffix=":arm64"
  fi
  apt-get update -q
  local native=(
    build-essential fakeroot dpkg-dev debhelper patch curl ca-certificates
    xz-utils gnupg gpgv debian-archive-keyring
    meson ninja-build pkgconf python3 python3-mako python3-yaml python3-setuptools python3-packaging
    bison flex glslang-tools
    "clang-${LLVM}" "llvm-${LLVM}-dev" "libclang-${LLVM}-dev" "libclang-cpp${LLVM}-dev" "libclc-${LLVM}" "libclc-${LLVM}-dev"
    "libllvmspirvlib-${LLVM}-dev" "llvm-spirv-${LLVM}" spirv-tools
    libexpat1-dev zlib1g-dev libzstd-dev libelf-dev libdrm-dev libvulkan-dev
    x11proto-dev
  )
  [ "${MESA_CROSS}" = 0 ] || native+=(crossbuild-essential-arm64 qemu-user-static)
  apt-get install -y -q --no-install-recommends "${native[@]}"
  local host=(
    libdrm-dev libexpat1-dev zlib1g-dev libzstd-dev libelf-dev libvulkan-dev
    "libllvm${LLVM}" libwayland-dev libwayland-egl-backend-dev libx11-dev libx11-xcb-dev
    libxcb-dri2-0-dev libxcb-dri3-dev libxcb-glx0-dev libxcb-present-dev libxcb-randr0-dev
    libxcb-shm0-dev libxcb-sync-dev libxext-dev libxrandr-dev libxshmfence-dev libxxf86vm-dev
    libglvnd-core-dev
  )
  apt-get install -y -q --no-install-recommends "${host[@]/%/${suffix}}"

  local wd=/build/wl-debs
  rm -rf "${wd}"; mkdir -p "${wd}"
  ( cd "${wd}" && apt-get download -t "${A7S_SUITE}-backports" "libwayland-bin:${build_arch}" ) \
    || die "no libwayland-bin in ${A7S_SUITE}-backports: wayland-protocols 1.50 needs wayland-scanner >= 1.26, which the archive has there from 20261112 on (A7S_SNAPSHOT older?)"
  rm -rf "${WL}"; install -d "${WL}"
  dpkg-deb -x "${wd}"/libwayland-bin_*_"${build_arch}".deb "${WL}"
  local wlver
  wlver="$("${WL}/usr/bin/wayland-scanner" --version 2>&1 | sed -n 's/^wayland-scanner //p')" \
    || die "the unpacked wayland-scanner does not run"
  [ -n "${wlver}" ] || die "the unpacked wayland-scanner reports no version"
  dpkg --compare-versions "${wlver}" ge 1.26 || die "wayland-scanner ${wlver} from ${A7S_SUITE}-backports is older than 1.26"
  cat > /usr/share/pkgconfig/wayland-scanner.pc <<EOF
prefix=${WL}/usr
wayland_scanner=\${prefix}/bin/wayland-scanner

Name: Wayland Scanner
Description: Wayland scanner (a7s-build: from ${A7S_SUITE}-backports, build only)
Version: ${wlver}
EOF
  pkg-config --variable=wayland_scanner wayland-scanner
  dpkg -i /build/dl/wayland-protocols_*_all.deb
  pkg-config --modversion wayland-protocols
  ( cd /build/src && make -f debian/rules regen_control >/dev/null ) || die "debian/rules regen_control failed"
  log "binary packages in debian/control: $(grep -c '^Package:' /build/src/debian/control)"
}

step_clc() {
  local cs=/build/clc-src b=/build/build-clc t f
  rm -rf "${b}"
  meson setup "${b}" "${cs}" --buildtype=release \
    -Dmesa-clc=enabled -Dinstall-mesa-clc=true -Dvulkan-drivers=imagination -Dgallium-drivers= \
    -Dplatforms= -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dgles1=disabled -Dgles2=disabled \
    -Dopengl=false -Dllvm=enabled -Dshared-llvm=enabled -Dvalgrind=disabled -Dlibunwind=disabled \
    -Dvideo-codecs= -Dgallium-va=disabled -Dgallium-rusticl=false -Dbuild-tests=false -Dtools= \
    -Dvulkan-layers=
  meson compile -C "${b}" -j "${MESA_JOBS}" mesa_clc vtn_bindgen2 pco_clc src/imagination/pdsc/pdsc_precomp:executable
  install -d "${CLC_PREFIX}/bin"
  for t in mesa_clc vtn_bindgen2 pco_clc pdsc_precomp; do
    f="$(find "${b}" -name "${t}" -type f -perm -u+x | head -1)"
    [ -n "${f}" ] || die "clc: ${t} was not built"
    install -m0755 "${f}" "${CLC_PREFIX}/bin/${t}"
    ! ldd "${CLC_PREFIX}/bin/${t}" | grep 'not found' || die "clc: ${t} misses a library"
  done
  log "mesa_clc, vtn_bindgen2, pco_clc, pdsc_precomp -> ${CLC_PREFIX}/bin"
}

step_llvm() {
  [ "${MESA_CROSS}" = 1 ] || die "step llvm is for the cross build only"
  local d=/build/llvm-debs f
  rm -rf "${d}"; mkdir -p "${d}"
  ( cd "${d}" && apt-get download "llvm-${LLVM}:arm64" "llvm-${LLVM}-dev:arm64" )
  rm -rf "${LLVMARM}"; install -d "${LLVMARM}/root/usr/lib"
  for f in "${d}"/*.deb; do dpkg-deb -x "${f}" "${LLVMARM}/root"; done
  ln -sfn /usr/lib/aarch64-linux-gnu "${LLVMARM}/root/usr/lib/aarch64-linux-gnu"
  cat > "${LLVMARM}/llvm-config" <<EOF
#!/bin/sh
exec qemu-aarch64-static -L / ${LLVMARM}/root/usr/lib/llvm-${LLVM}/bin/llvm-config "\$@"
EOF
  # pkgconf ships no aarch64-linux-gnu-pkg-config.
  cat > "${LLVMARM}/pkg-config" <<'EOF'
#!/bin/sh
unset PKG_CONFIG_PATH
export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig
exec /usr/bin/pkg-config "$@"
EOF
  chmod 0755 "${LLVMARM}/llvm-config" "${LLVMARM}/pkg-config"
  cat > "${LLVMARM}/cross-llvm.ini" <<EOF
[binaries]
llvm-config = '${LLVMARM}/llvm-config'
pkg-config = '${LLVMARM}/pkg-config'
EOF
  "${LLVMARM}/llvm-config" --version --host-target --libdir --includedir --shared-mode --link-shared --libs engine \
    || die "llvm-config (arm64, through qemu-user) does not run"
}

# SOURCE_DATE_EPOCH is unset on purpose: dpkg-buildpackage takes it from the
# changelog entry build-mesa wrote (see MESA_CHANGELOG_DATE). noautodbgsym: no
# -dbgsym packages. nocheck: no test run. -d: the build dependencies are the
# lists of step_deps, not debian/control's (that names Debian's full driver set).
step_build() {
  local meson_args="-Dmesa-clc=system -Dprecomp-compiler=system" arch_opt=()
  [ -x "${CLC_PREFIX}/bin/mesa_clc" ] || die "no mesa_clc (step clc)"
  if [ "${MESA_CROSS}" = 1 ]; then
    [ -f "${LLVMARM}/cross-llvm.ini" ] || die "no meson cross file (step llvm)"
    meson_args+=" --cross-file=${LLVMARM}/cross-llvm.ini"
    arch_opt=(-a arm64)
  else
    [ "$(dpkg --print-architecture)" = arm64 ] || die "a native build must run on arm64"
  fi
  rm -f /build/*.deb /build/*.buildinfo /build/*.changes
  cd /build/src
  env -u SOURCE_DATE_EPOCH \
    PATH="${CLC_PREFIX}/bin:${PATH}" \
    A7S_MESON_ARGS="${meson_args}" \
    DEB_BUILD_OPTIONS="nocheck noautodbgsym parallel=${MESA_JOBS}" \
    dpkg-buildpackage "${arch_opt[@]}" -d -b -uc -us
}

case "${1:-}" in
  deps)  step_deps ;;
  clc)   step_clc ;;
  llvm)  step_llvm ;;
  build) step_build ;;
  *) die "usage: build-in-chroot.sh deps|clc|llvm|build" ;;
esac
