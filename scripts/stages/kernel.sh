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
# Output: OUT_DIR/{Image,<dtb>,config,System.map,modules/,KERNEL-ID}. The modules
# include the AIC8800 WLAN/BT driver, which the recipe builds with the kernel;
# the wifi stage supplies its firmware.

# The recipe, pinned to a COMMIT (main moves). To bump it: build, compare the
# result, test on a board, then change it here.
KERNEL_RECIPE_URL="https://github.com/DockSeed/a7s-linux-lts.git"
KERNEL_RECIPE_COMMIT="4127264cc76def428efd3dcdc4f9f4b3487c494f"

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

pins_kernel() {
  log "kernel   : ${KERNEL_RECIPE_URL} @ ${KERNEL_RECIPE_COMMIT} (its own pins: build.sh pins in that checkout)"
}

# Fetch the recipe at the pinned commit (git_fetch_pinned proves HEAD).
stage_fetch_kernel() {
  git_fetch_pinned "${KERNEL_RECIPE_URL}" "${KERNEL_RECIPE_COMMIT}" "$(kernel_dir)"
}

# The recipe's own key (version, tarball sha256 and inputs hash), a function of
# the checkout alone. Needs the checkout.
stage_kernel_key() {
  local r; r="$(kernel_recipe)" || exit 1
  "${r}" key
}

# Run the recipe's scripts/build.sh here, in this builder: it needs the packages
# of container/packages.d/kernel.txt (the recipe's container/packages.txt). It
# fetches and verifies the kernel tarball and the driver source itself, applies
# the series, builds, asserts, and writes OUT_DIR/{Image,<dtb>,config,System.map,
# modules/,KERNEL-ID}. Its build time is the commit time of the pinned recipe
# commit; an ambient SOURCE_DATE_EPOCH does not reach the kernel.
stage_build_kernel() {
  local recipe; recipe="$(kernel_recipe)"
  WORK_DIR="${WORK_DIR}" OUT_DIR="${OUT_DIR}" CACHE_DIR="${CACHE_DIR}" "${recipe}" all \
    || die "build-kernel failed (reason above)"
}

# The recipe's fast compile gate (the A733 driver directories only). Needs the
# tree of an earlier build-kernel.
stage_compile_check() {
  local recipe; recipe="$(kernel_recipe)"
  WORK_DIR="${WORK_DIR}" OUT_DIR="${OUT_DIR}" CACHE_DIR="${CACHE_DIR}" "${recipe}" compile-check \
    || die "compile-check failed (reason above)"
}

# Used by the image stage: the kernel in OUT_DIR must come from the pinned
# recipe commit, unmodified. KERNEL-ID carries the recipe's key (a hash over
# scripts/, kernel/, pins/, out-of-tree/, container/packages.txt and the build
# time, which is the commit time of the pinned commit) and the sha256 of Image
# and the dtb; a variant build (developer switches) is refused.
kernel_verify_output() {
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
