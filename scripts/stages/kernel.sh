# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# Kernel stages: kernel (= fetch-kernel + build-kernel), fetch-kernel,
# build-kernel, compile-check, kernel-key. Sourced by scripts/inner.sh after
# scripts/lib/common.sh; defines functions and pins only.
#
# This repository holds no kernel source and no kernel patches. Linux 6.18 with
# the A733 patch series is the stand-alone recipe a7s-linux-lts, pinned here to
# a commit. docs/kernel.md says what it builds.
#
# Two sources for the image's kernel, A7S_KERNEL:
#   build    the recipe builds the kernel here.
#            Output: OUT_DIR/{Image,<dtb>,config,System.map,modules/,KERNEL-ID}.
#            The modules include the AIC8800 WLAN/BT driver, which the recipe
#            builds with the kernel; the wifi stage supplies its firmware.
#   release  (default) the Debian packages (linux-image, linux-headers) of a release of the
#            recipe, downloaded from its public URL against a pinned sha256.
#            Output: OUT_DIR/kernel-release/{*.deb,RELEASE-ID}. The AIC8800
#            driver is not in them: the wifi stage packages its source for DKMS.
#            Both modes fetch the recipe (fetch-kernel): the driver's patches
#            are in it.
# Both modes put the package a7s-kernel-hook (the recipe's hooks that give a
# kernel installed on the board its extlinux entry) in OUT_DIR/kernel-hook/: in
# `release` the one of the pinned release, in `build` one the recipe builds here.

# The recipe, pinned to a COMMIT (main moves). To bump it: build, compare the
# result, test on a board, then change it here.
KERNEL_RECIPE_URL="https://github.com/DockSeed/a7s-linux-lts.git"
KERNEL_RECIPE_COMMIT="d83a34b7c47557296c72fa41e745f08b58c718dd"

# The release of that recipe the image can install instead of building the
# kernel (A7S_KERNEL=release). The packages are pinned by sha256; the release
# was built by the recipe's release workflow from KERNEL_RELEASE_COMMIT, which
# must be the recipe commit pinned above (the driver's patches come from it).
# The asset names are the ones of the release's SHA256SUMS: the recipe names
# the files of a test build without "~" (6.18.59~t4-1 is 6.18.59.t4-1); a
# release's 6.18.63-1 has none.
KERNEL_RELEASE_TAG="v6.18.63-R1"
KERNEL_RELEASE_COMMIT="d83a34b7c47557296c72fa41e745f08b58c718dd"
KERNEL_RELEASE_NAME="6.18.63-r1"
KERNEL_RELEASE_DTB="allwinner/sun60i-a733-cubie-a7s.dtb"
KERNEL_RELEASE_BASE_URL="https://github.com/DockSeed/a7s-linux-lts/releases/download/${KERNEL_RELEASE_TAG}"
KERNEL_RELEASE_IMAGE_DEB="linux-image-${KERNEL_RELEASE_NAME}_6.18.63-1_arm64.deb"
KERNEL_RELEASE_IMAGE_SHA256="3cf80cff6990ed660cc8820cb63e4931b11359b8520153b1dfff84431b6ce9ea"
KERNEL_RELEASE_HEADERS_DEB="linux-headers-${KERNEL_RELEASE_NAME}_6.18.63-1_arm64.deb"
KERNEL_RELEASE_HEADERS_SHA256="fa295b7123f925a42c2b7988288882fe6fa9e366ca4b31a920c337ad4714dcc1"
KERNEL_RELEASE_HOOK_DEB="a7s-kernel-hook_6.18.63-1_all.deb"
KERNEL_RELEASE_HOOK_SHA256="096c2eaffdaee6de2f81a7f20deb9d29a4bd4464d764779a140b7ec08e3d058c"

# Where the pinned recipe is checked out.
kernel_dir() { printf '%s\n' "${WORK_DIR}/a7s-linux-lts"; }

# The recipe's scripts/build.sh, after checking that the checkout is the pin.
kernel_recipe() {
  local dir; dir="$(kernel_dir)"
  [ -x "${dir}/scripts/build.sh" ] || die "kernel recipe missing in ${dir} -- run fetch-kernel first"
  [ "$(git -C "${dir}" rev-parse HEAD 2>/dev/null)" = "${KERNEL_RECIPE_COMMIT}" ] \
    || die "${dir} is not at ${KERNEL_RECIPE_COMMIT} -- run fetch-kernel again"
  printf '%s\n' "${dir}/scripts/build.sh"
}

# The kernel source of this build: build or release (A7S_KERNEL).
kernel_source() {
  case "${A7S_KERNEL:-release}" in
    build|release) printf '%s\n' "${A7S_KERNEL:-release}" ;;
    *) die "A7S_KERNEL must be build or release, not '${A7S_KERNEL}'" ;;
  esac
}

# Where the downloaded release packages are kept for the image stages.
kernel_release_dir() { printf '%s\n' "${OUT_DIR}/kernel-release"; }

# Where the a7s-kernel-hook package is kept for the image stages.
kernel_hook_dir() { printf '%s\n' "${OUT_DIR}/kernel-hook"; }

pins_kernel() {
  log "kernel   : ${KERNEL_RECIPE_URL} @ ${KERNEL_RECIPE_COMMIT} (its own pins: build.sh pins in that checkout)"
  log "           release ${KERNEL_RELEASE_TAG} (A7S_KERNEL=release): ${KERNEL_RELEASE_IMAGE_DEB} sha256 ${KERNEL_RELEASE_IMAGE_SHA256:0:16}..., ${KERNEL_RELEASE_HEADERS_DEB} sha256 ${KERNEL_RELEASE_HEADERS_SHA256:0:16}..., ${KERNEL_RELEASE_HOOK_DEB} sha256 ${KERNEL_RELEASE_HOOK_SHA256:0:16}..."
}

# Fetch the recipe at the pinned commit (git_fetch_pinned proves HEAD). With
# A7S_KERNEL=release also the release packages, from the public URL of the
# release: the sha256 pins decide, a cache or mirror only saves the download.
stage_fetch_kernel() {
  git_fetch_pinned "${KERNEL_RECIPE_URL}" "${KERNEL_RECIPE_COMMIT}" "$(kernel_dir)"
  [ "$(kernel_source)" = release ] || return 0
  [ "${KERNEL_RELEASE_COMMIT}" = "${KERNEL_RECIPE_COMMIT}" ] \
    || die "the pinned release ${KERNEL_RELEASE_TAG} was built from ${KERNEL_RELEASE_COMMIT}, the recipe pin is ${KERNEL_RECIPE_COMMIT} -- move the pins together"
  local d; d="$(kernel_release_dir)"
  mkdir -p "${d}"
  fetch_verified "${KERNEL_RELEASE_IMAGE_SHA256}" "${d}/${KERNEL_RELEASE_IMAGE_DEB}" \
    "${KERNEL_RELEASE_BASE_URL}/${KERNEL_RELEASE_IMAGE_DEB}"
  fetch_verified "${KERNEL_RELEASE_HEADERS_SHA256}" "${d}/${KERNEL_RELEASE_HEADERS_DEB}" \
    "${KERNEL_RELEASE_BASE_URL}/${KERNEL_RELEASE_HEADERS_DEB}"
  mkdir -p "$(kernel_hook_dir)"
  rm -f "$(kernel_hook_dir)"/a7s-kernel-hook_*_all.deb
  fetch_verified "${KERNEL_RELEASE_HOOK_SHA256}" "$(kernel_hook_dir)/${KERNEL_RELEASE_HOOK_DEB}" \
    "${KERNEL_RELEASE_BASE_URL}/${KERNEL_RELEASE_HOOK_DEB}"
}

# The recipe's own key (version, tarball sha256 and inputs hash), a function of
# the checkout alone. Needs the checkout.
stage_kernel_key() {
  local r; r="$(kernel_recipe)" || exit 1
  "${r}" key
}

# A7S_KERNEL=build: run the recipe's scripts/build.sh here, in this builder: it
# needs the packages of container/packages.d/kernel.txt (the recipe's
# container/packages.txt). It fetches and verifies the kernel tarball and the
# driver source itself, applies the series, builds, asserts, and writes
# OUT_DIR/{Image,<dtb>,config,System.map,modules/,KERNEL-ID}. Its build time is
# the commit time of the pinned recipe commit; an ambient SOURCE_DATE_EPOCH
# does not reach the kernel.
# A7S_KERNEL=release: nothing to build; check that the packages are what the
# pins say (kernel_release_check).
stage_build_kernel() {
  if [ "$(kernel_source)" = release ]; then kernel_release_check; return 0; fi
  local recipe; recipe="$(kernel_recipe)"
  WORK_DIR="${WORK_DIR}" OUT_DIR="${OUT_DIR}" CACHE_DIR="${CACHE_DIR}" "${recipe}" all \
    || die "build-kernel failed (reason above)"
  kernel_hook_build
}

# A7S_KERNEL=build: the recipe's step hook makes the a7s-kernel-hook package from
# the pinned checkout. Its version needs a revision; t0 is what the recipe's own
# manual run uses. It is set for this step only: the kernel above has none.
kernel_hook_build() {
  local recipe d out; recipe="$(kernel_recipe)"; d="$(kernel_hook_dir)"; out="${WORK_DIR}/kernel-hook-out"
  rm -rf "${d}" "${out}"
  mkdir -p "${d}"
  A7S_KERNEL_REVISION=t0 WORK_DIR="${WORK_DIR}" OUT_DIR="${out}" CACHE_DIR="${CACHE_DIR}" "${recipe}" hook \
    || die "the recipe's hook step failed (reason above)"
  [ "$(find "${out}/deb" -name 'a7s-kernel-hook_*_all.deb' | wc -l)" = 1 ] || die "the recipe's hook step left not exactly one package in ${out}/deb"
  mv "${out}"/deb/a7s-kernel-hook_*_all.deb "${d}/"
  rm -rf "${out}"
  kernel_hook_check "$(kernel_hook_dir)"/a7s-kernel-hook_*_all.deb
}

# The hook package: ours, for every architecture, with both hooks.
kernel_hook_check() {  # <hook.deb>
  local deb="$1" l
  command -v dpkg-deb >/dev/null || die "dpkg-deb is missing in the builder"
  [ "$(dpkg-deb -f "${deb}" Package)" = a7s-kernel-hook ] || die "${deb##*/} is not the package a7s-kernel-hook"
  [ "$(dpkg-deb -f "${deb}" Architecture)" = all ] || die "${deb##*/} is not an architecture independent package"
  l="$(dpkg-deb -c "${deb}")" || die "cannot list ${deb##*/}"
  grep -q ' \./usr/share/kernel/postinst.d/zz-a7s-extlinux$' <<<"${l}" && grep -q ' \./usr/share/kernel/prerm.d/a7s-extlinux$' <<<"${l}" \
    || die "${deb##*/} lacks one of its two hooks"
}

# The release packages in kernel_release_dir: the pinned bytes, the package
# names and versions of the release, the kernel and the device tree in the
# image package, the build directory link and Module.symvers in the headers
# package. Writes RELEASE-ID beside them.
kernel_release_check() {
  local d img hdr n v rel="${KERNEL_RELEASE_NAME}"
  d="$(kernel_release_dir)"; img="${d}/${KERNEL_RELEASE_IMAGE_DEB}"; hdr="${d}/${KERNEL_RELEASE_HEADERS_DEB}"
  command -v dpkg-deb >/dev/null || die "dpkg-deb is missing in the builder"
  kernel_release_verify_bytes
  for n in "${img}:linux-image-${rel}" "${hdr}:linux-headers-${rel}"; do
    [ "$(dpkg-deb -f "${n%%:*}" Package)" = "${n##*:}" ] || die "${n%%:*} is not the package ${n##*:}"
    [ "$(dpkg-deb -f "${n%%:*}" Architecture)" = arm64 ] || die "${n%%:*} is not an arm64 package"
  done
  kernel_hook_check "$(kernel_hook_dir)/${KERNEL_RELEASE_HOOK_DEB}"
  v="$(dpkg-deb -f "${img}" Version)"
  [ "$(dpkg-deb -f "$(kernel_hook_dir)/${KERNEL_RELEASE_HOOK_DEB}" Version)" = "${v}" ] \
    || die "the hook package and the kernel packages have different versions"
  [ "$(dpkg-deb -f "$(kernel_hook_dir)/${KERNEL_RELEASE_HOOK_DEB}" Maintainer)" = "$(dpkg-deb -f "${img}" Maintainer)" ] \
    || die "the hook package and the kernel packages have different maintainers (the hook acts on its maintainer's kernels only)"
  [ "$(dpkg-deb -f "${hdr}" Version)" = "${v}" ] || die "the image and the headers package have different versions"
  # The listings go into variables first: `dpkg-deb -c | grep -q` fails at
  # random under pipefail when grep leaves at its first match.
  local limg lhdr
  limg="$(dpkg-deb -c "${img}")" && lhdr="$(dpkg-deb -c "${hdr}")" || die "cannot list the release packages"
  grep -q " \./boot/vmlinuz-${rel}\$" <<<"${limg}" || die "${img##*/} has no /boot/vmlinuz-${rel}"
  grep -q " \./usr/lib/linux-image-${rel}/${KERNEL_RELEASE_DTB}\$" <<<"${limg}" \
    || die "${img##*/} has no /usr/lib/linux-image-${rel}/${KERNEL_RELEASE_DTB}"
  grep -q " \./usr/src/linux-headers-${rel}/Module.symvers\$" <<<"${lhdr}" \
    || die "${hdr##*/} has no Module.symvers"
  grep -q " \./lib/modules/${rel}/build -> /usr/src/linux-headers-${rel}\$" <<<"${lhdr}" \
    || die "${hdr##*/}: /lib/modules/${rel}/build does not point to /usr/src/linux-headers-${rel}"
  {
    echo "tag=${KERNEL_RELEASE_TAG}"
    echo "recipe=${KERNEL_RELEASE_COMMIT}"
    echo "release=${rel}"
    echo "version=${v}"
    echo "image=${KERNEL_RELEASE_IMAGE_DEB} ${KERNEL_RELEASE_IMAGE_SHA256}"
    echo "headers=${KERNEL_RELEASE_HEADERS_DEB} ${KERNEL_RELEASE_HEADERS_SHA256}"
    echo "hook=${KERNEL_RELEASE_HOOK_DEB} ${KERNEL_RELEASE_HOOK_SHA256}"
  } > "${d}/RELEASE-ID"
  log "kernel release ${KERNEL_RELEASE_TAG}: ${KERNEL_RELEASE_IMAGE_DEB}, ${KERNEL_RELEASE_HEADERS_DEB}, ${KERNEL_RELEASE_HOOK_DEB} (version ${v}, sha256 verified)"
}

# Both packages in kernel_release_dir are the pinned bytes.
kernel_release_verify_bytes() {
  local d f; d="$(kernel_release_dir)"
  for f in "${KERNEL_RELEASE_IMAGE_DEB}:${KERNEL_RELEASE_IMAGE_SHA256}" "${KERNEL_RELEASE_HEADERS_DEB}:${KERNEL_RELEASE_HEADERS_SHA256}"; do
    _sha256_ok "${f##*:}" "${d}/${f%%:*}" \
      || die "${d}/${f%%:*} is missing or does not match its pinned sha256 -- run the kernel stage (A7S_KERNEL=release)"
  done
  _sha256_ok "${KERNEL_RELEASE_HOOK_SHA256}" "$(kernel_hook_dir)/${KERNEL_RELEASE_HOOK_DEB}" \
    || die "$(kernel_hook_dir)/${KERNEL_RELEASE_HOOK_DEB} is missing or does not match its pinned sha256 -- run the kernel stage (A7S_KERNEL=release)"
}

# The recipe's fast compile gate (the A733 driver directories only). Needs the
# tree of an earlier build-kernel.
stage_compile_check() {
  local recipe; recipe="$(kernel_recipe)"
  WORK_DIR="${WORK_DIR}" OUT_DIR="${OUT_DIR}" CACHE_DIR="${CACHE_DIR}" "${recipe}" compile-check \
    || die "compile-check failed (reason above)"
}

# Used by the image stage. A7S_KERNEL=release: the packages are the pinned
# bytes (the sha256 pin replaces the key below). A7S_KERNEL=build: the kernel in
# OUT_DIR must come from the pinned
# recipe commit, unmodified. KERNEL-ID carries the recipe's key (a hash over
# scripts/, kernel/, pins/, out-of-tree/, container/packages.txt and the build
# time, which is the commit time of the pinned commit) and the sha256 of Image
# and the dtb; a variant build (developer switches) is refused.
kernel_verify_output() {
  if [ "$(kernel_source)" = release ]; then kernel_release_verify_bytes; return 0; fi
  local id="${OUT_DIR}/KERNEL-ID" f want key
  [ -s "${OUT_DIR}/Image" ] && [ -s "${OUT_DIR}/${IMAGE_DTB}" ] && [ -s "${id}" ] \
    || die "no kernel (Image, ${IMAGE_DTB}, KERNEL-ID) in ${OUT_DIR} -- run the kernel stage"
  want="$(stage_kernel_key)" || die "kernel key failed"
  key="$(sed -n 's/^key=//p' "${id}")"
  [ "${key}" = "${want}" ] \
    || die "the kernel in ${OUT_DIR} (${key}) was not built by the pinned recipe commit (${want}) -- run the kernel stage again"
  ! grep -q '^variant=' "${id}" \
    || die "the kernel in ${OUT_DIR} is a variant build ($(sed -n 's/^variant=//p' "${id}")) -- run the kernel stage without developer switches"
  for f in Image "${IMAGE_DTB}"; do
    [ "$(sed -n "s/^sha256_${f}=//p" "${id}")" = "$(sha256sum "${OUT_DIR}/${f}" | cut -d' ' -f1)" ] \
      || die "${OUT_DIR}/${f} does not match KERNEL-ID -- run the kernel stage again"
  done
}

# Group stage run by the full chain (inner.sh all).
stage_kernel() { stage_fetch_kernel && stage_build_kernel; }
