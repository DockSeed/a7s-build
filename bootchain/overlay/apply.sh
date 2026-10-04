#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Apply the boot-chain overlay to a fetched radxa-pkg/u-boot-dlan17 tree.
# Called by the fetch-bootchain stage (scripts/stages/bootchain.sh) after it
# has put the package and its submodules in place; it needs no network.
#
# What this does:
#   1. Rewrites Radxa's quilt patch 0019 to relocate ONLY the SCP to DRAM.
#      BL31 returns to its upstream SRAM slot 0x62000 (the source-built
#      binary fits the 56 KiB slot; the prebuilt blob did not).
#   2. Adds a release-build atf pattern rule to .github/local/Makefile.local
#      and rewrites the radxa-cubie-a7s_build target to depend on and consume
#      atf/build/sun60i_a733/release/bl31.bin (mirroring the A5E target's
#      source-build pattern).
#   3. Appends bootchain/patches/u-boot/ to Radxa's quilt series.
#   4. Applies bootchain/patches/tf-a/ to the atf tree, which the stage has put
#      at TF-A master ATF_BASE instead of Radxa's fork pin.
#
# Every assumption about the upstream tree's shape is asserted before editing:
# an upstream edit that touches the same lines fails this script loudly
# instead of silently producing a different machine.
#
# Usage: bootchain/overlay/apply.sh <path-to-fetched-u-boot-dlan17-tree>
set -euo pipefail

dir="${1:?usage: apply.sh <fetched-tree>}"
overlay_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
patches_dir="${overlay_dir}/../patches"
# The one series reader of this repo (format and what it refuses: its header).
# It is part of the overlay's identity (bootchain_overlay_id).
series_lib="${overlay_dir}/../../scripts/lib/series.sh"
[ -f "${series_lib}" ] \
  || { echo "::error:: ${series_lib} missing -- apply.sh runs from a checkout of this repo"; exit 1; }
# shellcheck source=../../scripts/lib/series.sh
. "${series_lib}"

[ -d "${dir}/.git" ] \
  || { echo "::error:: ${dir} is not a git checkout (no .git)"; exit 1; }
[ -f "${dir}/.github/local/Makefile.local" ] \
  || { echo "::error:: ${dir}/.github/local/Makefile.local missing"; exit 1; }
[ -f "${dir}/debian/patches/series" ] \
  || { echo "::error:: ${dir}/debian/patches/series missing"; exit 1; }

OLD_0019="debian/patches/u-boot/0019-sunxi-a733-relocate-BL31-SCP-base-to-DRAM.patch"
NEW_0019="debian/patches/u-boot/0019-sunxi-a733-relocate-SCP-base-to-DRAM.patch"

# Assert radxa 0019 still exists at the expected filename -- if upstream renamed
# or split it, our rewrite needs a review, not a silent skip.
[ -f "${dir}/${OLD_0019}" ] \
  || { echo "::error:: radxa 0019 not at expected path (${OLD_0019}). Upstream changed? Refusing to overlay."; exit 1; }

# Assert our NEW filename is not already taken (refuse loudly rather than
# risk overwriting an unrelated file). The `if/then/exit` form (not
# `[ test ] && { exit; } || true`) -- the latter masks failures under `set -e`
# if a future edit drops the `exit` for a `return`.
if [ -f "${dir}/${NEW_0019}" ]; then
  echo "::error:: ${NEW_0019} already exists in the tree -- overlapping overlay? Refusing."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Replace radxa 0019 with our SCP-only version.
# ---------------------------------------------------------------------------
mv "${dir}/${OLD_0019}" "${dir}/${NEW_0019}"
# Match the git-format-patch header convention used by every other radxa quilt
# patch (From <sha> Mon Sep 17 00:00:00 2001, From:, Date:, Subject:, SOB).
# `patch -p1` does not care, but `git am` and stricter dpkg-source patch
# checkers do.
cat > "${dir}/${NEW_0019}" <<'PATCH'
From 7e5e412aef94d9264c3e473cddbaacde397020b6 Mon Sep 17 00:00:00 2001
From: Feng Zhang <feng@radxa.com>
Date: Tue, 12 May 2026 15:29:17 +0800
Subject: [PATCH] sunxi: a733: relocate SCP base to DRAM

Signed-off-by: Feng Zhang <feng@radxa.com>
Link: https://github.com/radxa-pkg/u-boot-dlan17/blob/7bfda4c83180d4ab8e0f4be291a91fc839e36173/debian/patches/u-boot/0019-sunxi-a733-relocate-BL31-SCP-base-to-DRAM.patch
[ adapted: BL31 hunk removed, so BL31 stays in its upstream SRAM slot 0x62000; subject and file name say SCP instead of BL31/SCP (original subject: "sunxi: a733: relocate BL31/SCP base to DRAM"); the remaining hunks are unchanged. Radxa's 0019 relocated both BL31 and the SCP to DRAM. The BL31 built from source (upstream TF-A, release build, about 33 KiB) fits the 56 KiB SRAM A2 BL31 slot; the prebuilt blob (115 677 B) did not, which is what made the DRAM relocation necessary in the first place. The SCP (vendor arisc, ~117 KiB, built from the allwinner-arisc submodule and linking the closed libar100s.a) does not fit SRAM and stays in DRAM at 0x48100000. ]
Assisted-by: Claude

--- a/src/arch/arm/mach-sunxi/Kconfig
+++ b/src/arch/arm/mach-sunxi/Kconfig
@@ -215,7 +215,7 @@ config SUNXI_SRAM_ADDRESS
 	hex
 	default 0x10000 if MACH_SUN9I || MACH_SUN50I || MACH_SUN50I_H5
 	default 0x44000 if MACH_SUN55I_A523
-	default 0x48000640 if MACH_SUN60I_A733
+	default 0x47800640 if MACH_SUN60I_A733
 	default 0x20000 if SUN50I_GEN_H6 || SUNXI_GEN_NCAT2
 	default 0x0
 	---help---
@@ -268,6 +268,7 @@ config SUNXI_SCP_BASE
 	hex
 	default 0x00050000 if MACH_SUN50I || MACH_SUN50I_H5
 	default 0x00114000 if MACH_SUN50I_H6
+	default 0x48100000 if MACH_SUN60I_A733
 	default 0x0
 	help
 	  Address where SCP firmware is loaded, or zero if it is not used.

2.43.0
PATCH

# Update the series file to reference the new filename.
series_line_old="u-boot/0019-sunxi-a733-relocate-BL31-SCP-base-to-DRAM.patch"
series_line_new="u-boot/0019-sunxi-a733-relocate-SCP-base-to-DRAM.patch"
grep -qxF "${series_line_old}" "${dir}/debian/patches/series" \
  || { echo "::error:: series file does not contain '${series_line_old}' verbatim -- radxa reorganized the patch list? Refusing."; exit 1; }
# In-place replace (escape regex metachars by using a fixed-string tool).
python3 - "$dir/debian/patches/series" "${series_line_old}" "${series_line_new}" <<'PY'
import sys, pathlib
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(p).read_text()
pathlib.Path(p).write_text(text.replace(old, new))
PY

echo "  [overlay] radxa 0019 -> SCP-only (${NEW_0019})"

# ---------------------------------------------------------------------------
# 2. Edit .github/local/Makefile.local: add release-build atf rule + change
#    the A7S build line to consume the source-built BL31.
# ---------------------------------------------------------------------------
python3 - "${dir}/.github/local/Makefile.local" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()

# Sanity: the A5E target proves the source-build pattern works; if it changes
# shape, our mirror of it needs a review.
if "BL31=../atf/build/sun55i_a523/debug/bl31.bin" not in t:
    sys.exit("::error:: A5E source-BL31 line missing from Makefile.local -- radxa refactored the A5E target? Refusing.")

# (a) Add a release-build pattern rule next to the debug one, if missing.
DEBUG_RULE = (
    "atf/build/%/debug/bl31.bin:\n"
    "\t$(MAKE) -j$(shell nproc) -C atf CROSS_COMPILE=$(CROSS_COMPILE) PLAT=$* DEBUG=1\n"
)
RELEASE_RULE = (
    "\n"
    "atf/build/%/release/bl31.bin:\n"
    "\t$(MAKE) -j$(shell nproc) -C atf CROSS_COMPILE=$(CROSS_COMPILE) PLAT=$* DEBUG=0\n"
)
if "atf/build/%/release/bl31.bin:" not in t:
    if DEBUG_RULE not in t:
        sys.exit("::error:: debug atf pattern rule not at expected form. Refusing.")
    t = t.replace(DEBUG_RULE, DEBUG_RULE + RELEASE_RULE, 1)

# (b) Rewrite the A7S build line: depend on + consume the source BL31.
OLD = (
    "radxa-cubie-a7s_build: radxa-cubie-a7s_defconfig awbin/a733/scp.bin\n"
    "\t$(UMAKE) SCP=../awbin/a733/scp.bin BL31=../awbin/a733/bl31.bin\n"
)
NEW = (
    "radxa-cubie-a7s_build: radxa-cubie-a7s_defconfig awbin/a733/scp.bin "
    "atf/build/sun60i_a733/release/bl31.bin\n"
    "\t$(UMAKE) SCP=../awbin/a733/scp.bin BL31=../atf/build/sun60i_a733/release/bl31.bin\n"
)
if OLD not in t:
    sys.exit("::error:: radxa-cubie-a7s_build block not at expected form. Radxa changed it? Refusing.")
t = t.replace(OLD, NEW, 1)

p.write_text(t)
PY

echo "  [overlay] Makefile.local: A7S now builds + consumes atf/build/sun60i_a733/release/bl31.bin"

# ---------------------------------------------------------------------------
# 3. Add our own patches to radxa's quilt series.
#
#    Each entry of bootchain/patches/u-boot/series is copied into
#    debian/patches/u-boot/ and appended to the target tree's series, in the
#    order listed. Radxa's own series ends at 0033; ours carry no number and
#    apply after all 33 of theirs. Our names must stay flat (no `/`): they are
#    copied into radxa's single u-boot/ directory.
#
#    Two safety properties, and they are the reason this is a loop rather than
#    a `cp *`:
#      - skips what the series already names: an entry already named in the
#        target series is not added a second time (a duplicate series line
#        would make `quilt push -a` fail). That is a property of this loop
#        alone: apply.sh as a whole does not re-run on an overlaid tree, step 1
#        refuses it (radxa's 0019 is gone from its old path).
#      - refuses to clobber: if the target file exists but the series does NOT
#        name it, something else put it there. That is an overlapping overlay
#        or a radxa addition colliding with our name, and it fails LOUD.
#
#    Only *additions* live here. The two rewrites above -- radxa's 0019 and
#    .github/local/Makefile.local -- are not expressible as "append a patch"
#    and stay as bespoke code.
#
#    What `sunxi-cubie-a7s-watchdog-autostart` is for: the A733 watchdog
#    hardware, the sunxi_wdt driver and a DT node for it all exist, but the
#    watchdog never starts -- drivers/watchdog/Kconfig sets WATCHDOG_AUTOSTART
#    default n if ARCH_SUNXI and the A7S defconfig enables none of the
#    CONFIG_WDT knobs. Enabling them lets U-Boot run the 16s watchdog during
#    its own phase, including at the prompt, and hand it to Linux still
#    running: U-Boot has no stop-before-Linux path. The kernel keeps it running
#    (sunxi_wdt, upstream since 6.18.53: the probe finds the watchdog U-Boot
#    armed -- WDT_CPUS since `sunxi-cubie-a7s-watchdog-on-wdt-cpus` -- enabled
#    and sets WDOG_HW_RUNNING, so the watchdog core pings it until userspace --
#    systemd RuntimeWatchdogSec -- opens the device). CONFIG_SUNXI_WATCHDOG=y
#    (built-in, not a module) keeps that probe inside the 16s window; the
#    kernel stage asserts it (pins/kernel-config.assert).
# ---------------------------------------------------------------------------
series_load "${patches_dir}/u-boot" \
  || { echo "::error:: bootchain/patches/u-boot/series is missing, empty or malformed -- overlay is incomplete"; exit 1; }

for name in "${SERIES[@]}"; do
  case "${name}" in
    */*) echo "::error:: bootchain/patches/u-boot/series: '${name}' has a directory; U-Boot patch names must be flat"; exit 1 ;;
  esac
  src="${patches_dir}/u-boot/${name}"

  if grep -qxF "u-boot/${name}" "${dir}/debian/patches/series"; then
    echo "  [overlay] ${name} already in series -- skipping"
    continue
  fi

  if [ -f "${dir}/debian/patches/u-boot/${name}" ]; then
    echo "::error:: debian/patches/u-boot/${name} already exists in the tree -- overlapping overlay? Refusing."
    exit 1
  fi

  cp "${src}" "${dir}/debian/patches/u-boot/${name}"
  printf 'u-boot/%s\n' "${name}" >> "${dir}/debian/patches/series"
  echo "  [overlay] added ${name}"
done

# ---------------------------------------------------------------------------
# 4. Apply our patches to the atf tree.
#
#    Deliberately NOT step 3's mechanism. That one appends to radxa's quilt
#    series in debian/patches, which dpkg-source consumes and which describes
#    u-boot. TF-A is a separate tree with its own upstream pin, so it gets its
#    own list applied straight against it.
#
#    The base is upstream TF-A master at a pinned commit, not radxa's pin.
#    radxa's submodule points at the dlan17 fork, TF-A master of 2025-01-09
#    plus the A523/A733 commits. So: assert radxa's pin in the package tree (a
#    radxa bump still fails loud and gets a look), and assert that the atf
#    tree the stage fetched is the pinned upstream commit. The A733 support is
#    bootchain/patches/tf-a/series, rebased onto that commit. The fetch stage
#    reads ATF_UPSTREAM and ATF_BASE from this file, so the pin is part of the
#    overlay's identity.
#
#    Same refusal to clobber as step 3: a patch that does not apply stops the
#    script. The thing being patched is the firmware that powers CPUs down,
#    and a half-applicable patch there is a board that does not boot.
#    Not re-runnable: step 1 refuses an already overlaid tree; the fetch stage
#    always starts from a fresh one.
# ---------------------------------------------------------------------------
ATF_PIN="f4c0b0dba78a2d9916154c130979992caa3f3156"  # radxa's submodule pin: dlan17 fork, A733 v2.12 tip
ATF_UPSTREAM="https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git"
ATF_BASE="3d425f4f459820a44d24b23464dbc09d6baab7bb"  # TF-A master, 2026-10-02 (VERSION 2.15.0)
# TF-A puts `git describe --always --dirty --tags` of its tree into the BL31
# banner (v2.15.0(release):<commit>-dirty). Without tags that is the abbreviated
# commit id, and git's default abbreviation grows with the number of objects in
# the repository: a shallow fetch and a full clone print different banners and
# build different bytes. Pinned to 9 digits, what a full clone of the package's
# atf submodule gives.
ATF_ABBREV=9
atf_dir="${dir}/atf"

gitlink="$(git -C "${dir}" ls-tree HEAD atf | awk '$2=="commit" {print $3}')"
[ "${gitlink}" = "${ATF_PIN}" ] \
  || { echo "::error:: the package pins atf at '${gitlink}', expected radxa's ${ATF_PIN}. Upstream bumped the submodule -- re-verify before changing a pin."; exit 1; }
[ -f "${atf_dir}/plat/allwinner/common/allwinner-common.mk" ] \
  || { echo "::error:: atf tree missing at ${atf_dir} -- the fetch stage puts TF-A ${ATF_BASE} there"; exit 1; }
have="$(git -C "${atf_dir}" rev-parse HEAD)"
[ "${have}" = "${ATF_BASE}" ] \
  || { echo "::error:: atf is at ${have}, expected TF-A master ${ATF_BASE}"; exit 1; }
git -C "${atf_dir}" config core.abbrev "${ATF_ABBREV}"
echo "  [overlay] atf on TF-A master ${ATF_BASE} (radxa's pin ${ATF_PIN} replaced), describe abbreviation ${ATF_ABBREV}"

series_load "${patches_dir}/tf-a" \
  || { echo "::error:: bootchain/patches/tf-a/series is missing, empty or malformed"; exit 1; }

for name in "${SERIES[@]}"; do
  src="${patches_dir}/tf-a/${name}"
  git -C "${atf_dir}" apply --check "${src}" \
    || { echo "::error:: atf patch ${name} does not apply cleanly to TF-A ${ATF_BASE} + the entries before it"; exit 1; }
  git -C "${atf_dir}" apply "${src}"
  echo "  [overlay] atf ${name} applied"
done

# ---------------------------------------------------------------------------
# 5. Sanity: print the resulting A7S rule so the build log shows what shipped.
# ---------------------------------------------------------------------------
echo
echo "  Resulting radxa-cubie-a7s_build rule:"
awk '/^\.PHONY: radxa-cubie-a7s_build$/,/^$/' "${dir}/.github/local/Makefile.local" \
  | sed 's/^/    /'
echo
echo "  BL31 provenance after overlay (should be the SOURCE path, not awbin/):"
grep -E 'BL31=' "${dir}/.github/local/Makefile.local" | sed 's/^/    /'
