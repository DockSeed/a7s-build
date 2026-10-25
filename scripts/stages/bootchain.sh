# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# Boot-chain stages: bootchain (= fetch-bootchain + build-bootchain),
# fetch-bootchain, build-bootchain, bootchain-key. Sourced by scripts/inner.sh
# after scripts/lib/common.sh; defines functions and pins only.
#
# This repository holds no boot-chain source. The chain (U-Boot SPL with the
# vendor DRAM blob, BL31 built from TF-A, U-Boot, packed into one
# u-boot-sunxi-with-spl.bin) is the stand-alone recipe a733-bootchain, pinned
# here to a commit. docs/bootchain.md says what it builds.
#
# Output: OUT_DIR/bootchain/{u-boot-sunxi-with-spl.bin,BOOTCHAIN-ID}.

# The recipe, pinned to a COMMIT (main moves). To bump it: build,
# compare the sha256 in docs/bootchain.md, test on a board, then change it here.
BOOTCHAIN_URL="https://github.com/DockSeed/a733-bootchain.git"
BOOTCHAIN_COMMIT="03418865bde96de2640a2910724c5a93106950fc"

# Where the pinned recipe is checked out; its own work tree (the U-Boot package
# clone) lives beside it in WORK_DIR.
bootchain_dir() { printf '%s\n' "${WORK_DIR}/a733-bootchain"; }

pins_bootchain() {
  log "bootchain: ${BOOTCHAIN_URL} @ ${BOOTCHAIN_COMMIT} (its own pins: build.sh pins in that checkout)"
}

# Fetch the recipe at the pinned commit (git_fetch_pinned proves HEAD).
stage_fetch_bootchain() {
  git_fetch_pinned "${BOOTCHAIN_URL}" "${BOOTCHAIN_COMMIT}" "$(bootchain_dir)"
}

# The recipe's own key (upstream commit + overlay hash), a function of the
# checkout alone. Needs the checkout.
stage_bootchain_key() {
  local dir; dir="$(bootchain_dir)"
  [ -x "${dir}/scripts/build.sh" ] || die "boot chain recipe missing -- run fetch-bootchain first"
  "${dir}/scripts/build.sh" key
}

# Run the recipe's scripts/build.sh (the stage that runs in its own container)
# here, in this builder: it needs the packages of container/packages.d/bootchain.txt,
# which the recipe lists in its container/packages.txt. It fetches U-Boot and
# TF-A itself, builds, asserts, and writes OUT_DIR/bootchain/. Its SOURCE_DATE_EPOCH
# is derived from the pinned package commit and replaces any ambient value.
stage_build_bootchain() {
  local dir; dir="$(bootchain_dir)"
  [ -x "${dir}/scripts/build.sh" ] || die "boot chain recipe missing -- run fetch-bootchain first"
  [ "$(git -C "${dir}" rev-parse HEAD 2>/dev/null)" = "${BOOTCHAIN_COMMIT}" ] \
    || die "${dir} is not at ${BOOTCHAIN_COMMIT} -- run fetch-bootchain again"
  WORK_DIR="${WORK_DIR}" OUT_DIR="${OUT_DIR}" "${dir}/scripts/build.sh" all \
    || die "build-bootchain failed (reason above)"
}

# Used by the image stage: the chain in OUT_DIR/bootchain must come from the
# pinned recipe commit. BOOTCHAIN-ID carries `upstream=` and `overlay=`; the
# recipe's `key` is <upstream 12>-<overlay 12> of the checkout. Also sources the
# recipe's layout check, so the offsets have one source.
bootchain_verify_output() {
  local dir id key want
  dir="$(bootchain_dir)"; id="${OUT_DIR}/bootchain/BOOTCHAIN-ID"
  [ -s "${OUT_DIR}/bootchain/u-boot-sunxi-with-spl.bin" ] && [ -s "${id}" ] \
    || die "boot chain missing in ${OUT_DIR}/bootchain -- run the bootchain stage"
  [ -f "${dir}/scripts/lib/bootchain-layout.sh" ] \
    || die "boot chain recipe missing in ${dir} -- run fetch-bootchain"
  [ "$(git -C "${dir}" rev-parse HEAD 2>/dev/null)" = "${BOOTCHAIN_COMMIT}" ] \
    || die "${dir} is not at ${BOOTCHAIN_COMMIT} -- run fetch-bootchain again"
  want="$("${dir}/scripts/build.sh" key)" || die "bootchain key failed"
  key="$(sed -n 's/^upstream=\(.\{12\}\).*/\1/p' "${id}")-$(sed -n 's/^overlay=\(.\{12\}\).*/\1/p' "${id}")"
  [ "${key}" = "${want}" ] \
    || die "the boot chain in ${OUT_DIR}/bootchain (${key}) was not built by the pinned recipe commit (${want}) -- run the bootchain stage again"
  # shellcheck source=/dev/null
  . "${dir}/scripts/lib/bootchain-layout.sh"
  bootchain_layout_check "${OUT_DIR}/bootchain/u-boot-sunxi-with-spl.bin" \
    || die "the boot chain does not fit the image layout (${dir}/scripts/lib/bootchain-layout.sh)"
}

# Group stage run by the full chain (inner.sh all).
stage_bootchain() { stage_fetch_bootchain && stage_build_bootchain; }
