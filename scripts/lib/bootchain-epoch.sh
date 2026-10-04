# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# The time every timestamp in the boot chain is built with. Sourced, never run;
# `build-bootchain` exports the result as SOURCE_DATE_EPOCH.
#
# Why it exists: boot_package.fex carries the time it was built: three U-Boot
# banners (`... (Sep 26 2026 - 18:10:30 +0000)`), TF-A's `Built :` string
# twice, two FIT `timestamp` properties. Built twice with one SOURCE_DATE_EPOCH
# the chain is byte-identical, so the clock is the only input left, and without
# pinning it no rebuild can be compared byte for byte with an earlier chain.
#
# What honours the variable (read in the pinned trees):
#   U-Boot banner   src/Makefile `filechk_timestamp.h`: `date -u -d @$epoch`,
#                   U_BOOT_DATE / U_BOOT_TIME / U_BOOT_TZ (always +0000)
#   FIT timestamp   src/tools/image-host.c and fit_image.c, through
#                   `imagetool_get_source_date`; src/Makefile `fit-dtb.blob`
#                   (touch -d @$epoch)
#   TF-A `Built :`  atf/Makefile `BUILD_MESSAGE_TIMESTAMP ?= __TIME__", "__DATE__`;
#                   GCC takes __TIME__/__DATE__ from SOURCE_DATE_EPOCH (GCC >= 7,
#                   UTC)
# The two other words that change with the banners are derived, not clocks: the
# sunxi-package check_sum (header +0x14) and the eGON.BT0 check_sum of the SPL,
# both a sum over content the banners are part of. build-bootchain reads the
# result back out of boot_package.fex, so a tool that stops honouring the
# variable fails the stage instead of shipping a chain that cannot be reproduced.
#
# THE CHOICE: the committer date of the pinned package commit.
#   - It is a function of BOOTCHAIN_COMMIT alone. Every other input of the chain
#     is pinned by that commit (the submodule pins) or by bootchain/ (the TF-A
#     base commit, the patches), so an unchanged chain gets an unchanged epoch
#     and a moved pin moves the epoch.
#   - It is the same in every clone and every machine. Not used, on purpose: a
#     date out of THIS repository's history (a squash merge gives the same
#     overlay a different date), the newest date of the five submodule pins
#     (more code, the same answer class), and the wall clock (the bug).
#   - The banner therefore says when the pinned package was committed, not when
#     the chain was built. What says which chain it is: BOOTCHAIN-ID (upstream,
#     overlay hash, `source_date_epoch`, the sha256 of both files). It carries
#     no build time either, so a rebuild gives the same stamp.
#
# This file is part of the chain's identity: `bootchain_overlay_id`
# (scripts/stages/bootchain.sh) hashes it with the overlay, so editing the
# derivation changes the identity stamped into BOOTCHAIN-ID.
#
# API
#   bootchain_source_date_epoch <package-clone-dir>
#       prints the epoch (seconds) on stdout; returns 1 when the pinned commit is
#       not in the clone or its date is not a number. Needs BOOTCHAIN_COMMIT.
bootchain_source_date_epoch() {
  local dir="$1" ct
  ct="$(git -C "${dir}" log -1 --format=%ct "${BOOTCHAIN_COMMIT}" 2>/dev/null)" || return 1
  case "${ct}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "${ct}"
}
