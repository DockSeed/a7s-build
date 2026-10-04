# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# Boot-chain stages: bootchain (= fetch-bootchain + build-bootchain),
# fetch-bootchain, apply-bootchain-overlay, build-bootchain, bootchain-key.
# Sourced by scripts/inner.sh after scripts/lib/common.sh; defines functions and
# pins only.
#
# The chain is boot0 (vendor blob, with Allwinner's DRAM library) + BL31 (TF-A,
# built here from upstream source plus bootchain/patches/tf-a/) + U-Boot (Radxa's
# package tree plus bootchain/patches/u-boot/) + the SCP (ar100s) firmware,
# packed into boot0_sdcard.bin and boot_package.fex by the package's own build
# system. docs/bootchain.md says what each part is and where it comes from.
#
# Output: OUT_DIR/bootchain/{boot0_sdcard.bin,boot_package.fex,BOOTCHAIN-ID}.

# shellcheck source=../lib/series.sh
. "${SRC}/scripts/lib/series.sh"
# shellcheck source=../lib/bootchain-epoch.sh
. "${SRC}/scripts/lib/bootchain-epoch.sh"
# shellcheck source=../lib/bootchain-layout.sh
. "${SRC}/scripts/lib/bootchain-layout.sh"

# The package: radxa-pkg/u-boot-dlan17, pinned to a COMMIT (main moves).
# 7bfda4c8 = main of 2026-06-30 = release 2026.04-2 plus one commit adding
# patches 0030 (the vdd-cpul fix) and 0031-0033 (SPI-NOR/UFS/PCIe/NVMe). There
# is no .deb release for this commit, so the package is built from source.
BOOTCHAIN_URL="https://github.com/radxa-pkg/u-boot-dlan17.git"
BOOTCHAIN_COMMIT="7bfda4c83180d4ab8e0f4be291a91fc839e36173"
BOOTCHAIN_BOARD="radxa-cubie-a7s"
# The five submodules the package pins (`<path> <commit> <url>`); fetch-bootchain
# checks the package tree against this list and fetches each by commit id.
BOOTCHAIN_SUBMODULES_PIN="${SRC}/pins/bootchain-submodules.txt"
# sha256 of every prebuilt file taken from the package tree.
BOOTCHAIN_BLOBS_PIN="${SRC}/pins/bootchain-blobs.sha256"
# The overlay. apply.sh also carries the TF-A pin (ATF_UPSTREAM, ATF_BASE) and
# the abbreviation of its version banner, so both are part of the overlay's
# identity.
BOOTCHAIN_APPLY="${SRC}/bootchain/overlay/apply.sh"
# The SCP (ar100s, RISC-V) is built from source, so the chain needs Radxa's
# riscv64-elf toolchain. The package's `make install_toolchain` would download it
# unpinned; it is fetched here against the digest GitHub reports for the asset
# and put where that target finds it.
RISCV_TC_URL="https://github.com/radxa/allwinner-toolchain/releases/download/aiot-linux-v1.4.6/riscv64-elf-x86_64-20201104.tar.gz"
RISCV_TC_SHA256="c0b9197b25e9778afffbcda649f3e1d4cc3555fe0bed70e9aaf5730d90a70530"

# A variable of apply.sh (ATF_UPSTREAM, ATF_BASE, ATF_PIN), read, not sourced.
bootchain_apply_var() {
  local v
  v="$(sed -n "s/^$1=\"\\([^\"]*\\)\".*/\\1/p" "${BOOTCHAIN_APPLY}")"
  [ -n "${v}" ] || die "cannot read $1 from ${BOOTCHAIN_APPLY}"
  printf '%s\n' "${v}"
}

# Fetch every submodule of the package tree by commit id (no history, no branch
# names, cached in CACHE_DIR/git) and prove it is the commit the package pins and
# the one our pin file lists. `atf` is the exception: its pin is checked, and
# the tree put there is upstream TF-A at ATF_BASE (apply.sh step 4). A pin that
# no longer answers fails with its name, commit and source: the `src` commit is
# on no branch or tag of its upstream any more, GitHub serves it by hash only
# (docs/bootchain.md, "Known limits").
bootchain_submodules() {
  local dir="$1" pin path url want line n
  [ -f "${BOOTCHAIN_SUBMODULES_PIN}" ] || die "boot chain: ${BOOTCHAIN_SUBMODULES_PIN} missing"
  local -a links
  mapfile -t links < <(git -C "${dir}" ls-tree HEAD | awk '$2=="commit" {print $3, $4}')
  n="$(grep -cEv '^(#|$)' "${BOOTCHAIN_SUBMODULES_PIN}")"
  [ "${#links[@]}" = "${n}" ] \
    || die "boot chain: the package pins ${#links[@]} submodules, ${BOOTCHAIN_SUBMODULES_PIN} lists ${n}"
  for line in "${links[@]}"; do
    pin="${line%% *}" path="${line#* }"
    want="$(awk -v p="${path}" '$1==p {print $2" "$3}' "${BOOTCHAIN_SUBMODULES_PIN}")"
    [ -n "${want}" ] || die "boot chain: submodule ${path} (${pin}) is not in ${BOOTCHAIN_SUBMODULES_PIN}"
    [ "${want%% *}" = "${pin}" ] \
      || die "boot chain: the package pins ${path} at ${pin}, our pin file says ${want%% *}"
    url="${want#* }"
    if [ "${path}" = atf ]; then
      local atf_url atf_base
      atf_url="$(bootchain_apply_var ATF_UPSTREAM)"
      atf_base="$(bootchain_apply_var ATF_BASE)"
      git_fetch_pinned "${atf_url}" "${atf_base}" "${dir}/atf"
      printf '        %s %s  (package pin %s replaced) <- %s\n' "${atf_base:0:12}" "${path}" "${pin:0:12}" "${atf_url}"
      continue
    fi
    git_fetch_pinned "${url}" "${pin}" "${dir}/${path}"
    printf '        %s %s  <- %s\n' "${pin:0:12}" "${path}" "${url}"
  done
}

# Every prebuilt file taken from the package tree must match
# pins/bootchain-blobs.sha256 (paths relative to the tree). A moved or altered
# blob stops the stage.
bootchain_verify_blobs() {
  local dir="$1" n
  [ -s "${BOOTCHAIN_BLOBS_PIN}" ] || die "${BOOTCHAIN_BLOBS_PIN} missing or empty"
  n="$(grep -vcE '^[[:space:]]*(#|$)' "${BOOTCHAIN_BLOBS_PIN}")"
  ( cd "${dir}" && grep -vE '^[[:space:]]*(#|$)' "${BOOTCHAIN_BLOBS_PIN}" | sha256sum -c --quiet - ) \
    || die "a prebuilt file in ${dir} does not match pins/bootchain-blobs.sha256 (listed above)"
  log "prebuilt files verified against pins/bootchain-blobs.sha256 (${n} files)"
}

# Fetch the package at the pinned commit, prove it, fetch the submodules, check
# the prebuilt files and apply the overlay (bootchain/overlay/apply.sh).
stage_fetch_bootchain() {
  local dir="${WORK_DIR}/u-boot-dlan17"
  mkdir -p "${WORK_DIR}"
  rm -rf "${dir}"
  git_fetch_pinned "${BOOTCHAIN_URL}" "${BOOTCHAIN_COMMIT}" "${dir}"
  log "submodule pins (verified):"
  bootchain_submodules "${dir}"
  bootchain_verify_blobs "${dir}"
  # The package ships a prebuilt BL31; the overlay stops wiring it in. Printed
  # for awareness: knowing what Radxa shipped helps when diagnosing a regression.
  if [ -f "${dir}/awbin/a733/bl31.bin" ]; then
    local bl31_ver
    bl31_ver="$(grep -a -m1 -o 'v2\.[0-9][^ ]*' "${dir}/awbin/a733/bl31.bin" 2>/dev/null | tr -d '\0')" \
      || bl31_ver="<no version string>"
    log "awbin/a733/bl31.bin (prebuilt, UNUSED after overlay): $(stat -c%s "${dir}/awbin/a733/bl31.bin") B, ${bl31_ver}"
  fi
  stage_apply_bootchain_overlay "${dir}"
}

# Identity of the boot-chain overlay as it exists in THIS checkout: one hash over
# every file under bootchain/, the two pin files, and the two scripts that decide
# what the chain contains without living in it: scripts/lib/series.sh (which
# patches apply) and scripts/lib/bootchain-epoch.sh (the build time every
# timestamp in the firmware is pinned to). Recomputed, never stored. Paths are
# hashed relative to the repository root, so the identity does not depend on
# where the repo is checked out, and a rename changes it.
#
# It exists so that a fresh kernel cannot silently be composed onto a chain built
# before an overlay change: the image stage compares BOOTCHAIN-ID against it.
bootchain_overlay_id() {
  ( cd "${SRC}" \
      && { find bootchain -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum; } \
      && sha256sum pins/bootchain-blobs.sha256 pins/bootchain-submodules.txt \
                   scripts/lib/series.sh scripts/lib/bootchain-epoch.sh ) \
    | sha256sum | cut -d' ' -f1
}

# The key of a boot chain: the pinned upstream commit plus the identity of our
# overlay. Both are known from this checkout alone, with no fetch and no build.
stage_bootchain_key() {
  printf '%s-%s\n' "$(printf '%s' "${BOOTCHAIN_COMMIT}" | cut -c1-12)" \
                    "$(bootchain_overlay_id | cut -c1-12)"
}

# Apply the overlay to a freshly fetched tree. Every assumption about Radxa's
# tree shape is asserted inside apply.sh: an upstream edit that touches the same
# lines fails this stage loudly rather than producing a different machine.
stage_apply_bootchain_overlay() {
  local dir="${1:-${WORK_DIR}/u-boot-dlan17}"
  [ -x "${BOOTCHAIN_APPLY}" ] || die "bootchain/overlay/apply.sh missing or not executable"
  [ -d "${dir}/.git" ] || die "boot chain missing -- run fetch-bootchain first"
  log "applying bootchain/overlay/ and bootchain/patches/ (BL31 from source)"
  "${BOOTCHAIN_APPLY}" "${dir}" || die "bootchain overlay failed to apply (see messages above)"
}

# Build the boot package with the package's own build system, then prove the
# result is what the patches say. Runs in a subshell: the epoch, the locale and
# the working directory it sets belong to the boot chain only.
stage_build_bootchain() {
  ( bootchain_build ) || die "build-bootchain failed (reason above)"
}

bootchain_build() {
  local dir="${WORK_DIR}/u-boot-dlan17"
  [ -d "${dir}/.git" ] || die "boot chain missing -- run fetch-bootchain first"
  # TF-A make_helpers/toolchain.mk greps the output of `gcc -v` for "gcc
  # version", which a localized gcc prints differently; C is also the locale
  # the published chain was built and proven with.
  export LC_ALL=C
  # Refuse to build a chain we did not overlay -- that would silently bring back
  # the prebuilt BL31 blob and undo the source-built BL31.
  [ -f "${dir}/debian/patches/u-boot/0019-sunxi-a733-relocate-SCP-base-to-DRAM.patch" ] \
    || die "radxa 0019 not rewritten to SCP-only -- overlay missing? Run fetch-bootchain again."
  # Pin every build time in the firmware to the pinned package commit's date
  # (why that date: scripts/lib/bootchain-epoch.sh). The recipe-wide epoch is
  # replaced here, not used: the chain must not change with this repository's
  # history.
  local epoch
  epoch="$(bootchain_source_date_epoch "${dir}")" \
    || die "boot chain: cannot read the committer date of ${BOOTCHAIN_COMMIT} in ${dir}"
  export SOURCE_DATE_EPOCH="${epoch}"
  log "boot chain SOURCE_DATE_EPOCH=${epoch} ($(date -u -d "@${epoch}" '+%Y-%m-%d %H:%M:%S') UTC), committer date of ${BOOTCHAIN_COMMIT}"
  bootchain_verify_blobs "${dir}"
  cd "${dir}"
  # Check the tools up front rather than dying halfway through a build. The
  # authority for the package list is the package's own debian/control
  # Build-Depends; container/packages.d/bootchain.txt carries them.
  command -v aarch64-linux-gnu-gcc >/dev/null || [ "$(uname -m)" = "aarch64" ] \
    || die "aarch64-linux-gnu-gcc missing"
  # dragonsecboot, which packs boot_package.fex, is a statically linked x86-64
  # ELF, as are allwinner-arisc/ar100s/scripts/{conf,mconf} and the RISC-V
  # toolchain. On any other host architecture this stage would build for
  # minutes and then fail, so it is refused here.
  [ "$(uname -m)" = "x86_64" ] \
    || die "boot chain packing needs an x86-64 host (dragonsecboot is a static x86-64 ELF)"
  local t h inc
  for t in quilt swig dos2unix xxd dpkg-parsechangelog; do
    command -v "$t" >/dev/null || die "${t} missing (container/packages.d/bootchain.txt)"
  done
  # Headers are probed by compiling, not inferred from package names: only a
  # compile knows whether the header is actually reachable here.
  for h in Python.h openssl/engine.h gnutls/gnutls.h; do
    inc=""
    [ "$h" = "Python.h" ] && inc="$(python3-config --includes 2>/dev/null || true)"
    # shellcheck disable=SC2086
    echo "#include <$h>" | cc ${inc} -fsyntax-only -x c - 2>/dev/null \
      || die "header <$h> not found (container/packages.d/bootchain.txt)"
  done
  # The RISC-V toolchain for the SCP, verified and cached; with the tarball in
  # place `make install_toolchain` downloads nothing.
  local tc="allwinner-arisc/ar100s/tools/${RISCV_TC_URL##*/}"
  fetch_verified "${RISCV_TC_SHA256}" "${tc}" "${RISCV_TC_URL}"
  log "RISC-V toolchain sha256 verified"
  make install_toolchain || die "install_toolchain failed"
  # Radxa's 33 U-Boot patches are a quilt series that dpkg-source applies during
  # debuild -- `make` does not. Without them src/ has no radxa-cubie-a7s_defconfig
  # at all and the build dies at kconfig. They carry the A733 memory map that
  # remains relevant post-overlay: 0020 (SPL -> 0x47800000) and the SCP half of
  # our rewritten 0019 (SCP -> 0x48100000). BL31 is back at upstream SRAM 0x62000.
  # quilt exits 2 when the series is already fully applied -- that is not an
  # error. --fuzz=0: quilt defaults to fuzz 2 and places a drifted hunk anyway,
  # which once let a rewritten patch apply at fuzz 1 unnoticed.
  QUILT_PATCHES=debian/patches quilt push -a --fuzz=0 || [ $? -eq 2 ] \
    || die "applying radxa's u-boot patch series failed"
  [ -f src/configs/"${BOOTCHAIN_BOARD}"_defconfig ] \
    || die "patch series applied but ${BOOTCHAIN_BOARD}_defconfig is still missing"
  make "${BOOTCHAIN_BOARD}" || die "boot chain build failed"
  bootchain_assert "${dir}"
  local out="${dir}/out/${BOOTCHAIN_BOARD}" f
  for f in boot_package.fex boot0_sdcard.bin; do
    [ -s "${out}/${f}" ] || die "boot chain build produced no ${f}"
  done
  # Refuse a chain the image stage could not place. Here, and not only in the
  # image stage, so that the stage that builds the chain is the one that fails;
  # and before the copy, so nothing that does not fit reaches out/bootchain.
  bootchain_layout_check "${out}/boot0_sdcard.bin" "${out}/boot_package.fex" \
    || die "the boot chain does not fit the image layout (offsets: scripts/lib/bootchain-layout.sh) -- nothing copied to out/bootchain"
  rm -rf "${OUT_DIR}/bootchain"
  mkdir -p "${OUT_DIR}/bootchain"
  cp "${out}/boot0_sdcard.bin" "${out}/boot_package.fex" "${OUT_DIR}/bootchain/"
  # Stamp what this chain is, so the image stage can refuse to pair it with a
  # checkout it does not match. Content-addressed and without a build time: the
  # stamp goes into the image, which is reproducible.
  {
    echo "upstream=${BOOTCHAIN_COMMIT}"
    echo "overlay=$(bootchain_overlay_id)"
    # The build time inside the firmware, pinned to the package commit.
    echo "source_date_epoch=${SOURCE_DATE_EPOCH}"
    ( cd "${OUT_DIR}/bootchain" && sha256sum boot0_sdcard.bin boot_package.fex | sed 's/^\([0-9a-f]*\)  \(.*\)$/sha256_\2=\1/' )
  } > "${OUT_DIR}/bootchain/BOOTCHAIN-ID"
  log "boot chain built -> ${OUT_DIR}/bootchain"
  log "boot chain identity:"
  sed 's/^/        /' "${OUT_DIR}/bootchain/BOOTCHAIN-ID"
}

# What the build must have produced, read from the build output itself: the
# BL31 the package links, its size, version and build time, the features and
# errata the patches switch on, the stores of the security setup, and the EL3
# stacks. Only our own bl31.elf, built from public source, is disassembled here.
bootchain_assert() {
  local dir="$1"
  local rel="${dir}/atf/build/sun60i_a733/release"
  local src_bl31="${rel}/bl31.bin" bl31_elf="${rel}/bl31/bl31.elf" bl31_map="${rel}/bl31/bl31.map"
  local cfg="${rel}/config.h" mkf="${dir}/atf/plat/allwinner/sun60i_a733/platform.mk"
  local pkg="${dir}/out/${BOOTCHAIN_BOARD}/boot_package.fex"
  local tc="" syms bl31_objs
  [ "$(uname -m)" = "aarch64" ] || tc="aarch64-linux-gnu-"

  # File existence and size alone do not prove the produced boot_package.fex
  # links the source BL31: a regression could rewire the A7S Makefile target to
  # the awbin blob while the source bl31.bin still gets built as a side effect.
  # So assert the Makefile line, the BL31 size and the version banner in both
  # the BL31 and the package.
  grep -qF 'BL31=../atf/build/sun60i_a733/release/bl31.bin' "${dir}/.github/local/Makefile.local" \
    || die "Makefile.local no longer references the source BL31 -- overlay regression?"
  # SRAM A2 BL31 slot is 0x62000..0x70000 = 57 344 B; the release build (LTO)
  # is ~33 KiB. The blob would be 115 677 B linked at 0x48000000.
  [ -s "${src_bl31}" ] || die "source BL31 not built at ${src_bl31} -- Makefile.local overlay didn't take?"
  local src_bl31_size; src_bl31_size="$(stat -c%s "${src_bl31}")"
  [ "${src_bl31_size}" -gt 4096 ] && [ "${src_bl31_size}" -lt 57344 ] \
    || die "source BL31 is ${src_bl31_size} B -- outside the expected range (4 KiB floor, 56 KiB SRAM A2 ceiling); will not boot"
  # The full TF-A X.Y.Z(release|debug):hash format: the package also embeds
  # U-Boot strings like "v2.0Network" that a looser pattern would match first.
  local re='v[0-9]\.[0-9]\+\.[0-9]\+\((release)\|(debug)\):[0-9a-f]\+' src_bl31_ver pkg_bl31_ver
  src_bl31_ver="$(grep -a -m1 -o "${re}" "${src_bl31}" 2>/dev/null | tr -d '\0')" \
    || src_bl31_ver="<no TF-A version string>"
  log "source BL31 verified: ${src_bl31_size} B, ${src_bl31_ver} (SRAM @0x62000)"
  [ -s "${pkg}" ] || die "boot chain build produced no boot_package.fex"
  pkg_bl31_ver="$(grep -a -m1 -o "${re}" "${pkg}" 2>/dev/null | tr -d '\0')" \
    || die "no TF-A version banner (vN.N.N(release|debug):hash) in boot_package.fex -- cannot prove the right BL31 shipped"
  [ "${pkg_bl31_ver}" = "${src_bl31_ver}" ] \
    || die "boot_package.fex BL31 version (${pkg_bl31_ver}) != source BL31 version (${src_bl31_ver}) -- wrong BL31 shipped"
  log "boot_package.fex BL31 version matches source: ${pkg_bl31_ver}"

  # The epoch has to be IN the file, not merely exported. Every U-Boot banner,
  # every TF-A `Built :` string and every FIT root `timestamp` must read the
  # pinned epoch, and each kind must be found at least once, so a changed banner
  # format fails here and does not pass as "nothing to check".
  python3 - "${pkg}" "${SOURCE_DATE_EPOCH}" <<'PY' || die "boot_package.fex does not carry the pinned SOURCE_DATE_EPOCH everywhere (see above): its build time is not reproducible"
import re, struct, sys, time

pkg, epoch = sys.argv[1], int(sys.argv[2])
data = open(pkg, 'rb').read()
MON = 'Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec'.split()
g = time.gmtime(epoch)
# U-Boot: U_BOOT_DATE "%b %d %C%y", U_BOOT_TIME "%T", U_BOOT_TZ "%z" under date -u.
uboot = '%s %02d %d - %02d:%02d:%02d +0000' % (MON[g.tm_mon - 1], g.tm_mday, g.tm_year, g.tm_hour, g.tm_min, g.tm_sec)
# TF-A: __TIME__ ", " __DATE__ -> "hh:mm:ss, Mmm dd yyyy", the day space-padded.
tfa = '%02d:%02d:%02d, %s %2d %d' % (g.tm_hour, g.tm_min, g.tm_sec, MON[g.tm_mon - 1], g.tm_mday, g.tm_year)

bad = 0
def kind(name, found, want):
    global bad
    if not found:
        print('::error:: no %s found in %s -- the banner format changed? this check cannot read it' % (name, pkg)); bad += 1; return
    wrong = sorted(set(found) - {want})
    print('%d %s, expected "%s"%s' % (len(found), name, want, ': WRONG: %s' % wrong if wrong else ': all match'))
    if wrong: bad += 1

kind('U-Boot banner(s)',
     [m.decode() for m in re.findall(rb'U-Boot (?:SPL )?\d{4}\.\d\d[^\x00()]*\(([^)\x00]*)\)', data)], uboot)
kind('TF-A "Built :" string(s)',
     [m.decode() for m in re.findall(rb'Built : ([^\x00\n]*)', data)], tfa)

# FIT images: an FDT whose root node has a `timestamp` property (the U-Boot
# control dtb inside it has none; a stray magic that does not parse is skipped).
def fit_timestamp(base):
    magic, total, off_struct, off_strings = struct.unpack_from('>4I', data, base)
    if base + total > len(data):
        return None
    p, depth = base + off_struct, 0
    while True:
        tag = struct.unpack_from('>I', data, p)[0]; p += 4
        if tag == 1:
            p = (data.index(b'\0', p) + 1 + 3) & ~3; depth += 1
        elif tag == 2:
            depth -= 1
        elif tag == 3:
            length, name_off = struct.unpack_from('>II', data, p); p += 8
            start = base + off_strings + name_off
            name = data[start:data.index(b'\0', start)]
            if depth == 1 and name == b'timestamp' and length == 4:
                return struct.unpack_from('>I', data, p)[0]
            p = (p + length + 3) & ~3
        elif tag == 4:
            pass
        else:
            return None
        if depth == 0:
            return None
stamps = []
for m in re.finditer(b'\xd0\x0d\xfe\xed', data):
    try:
        t = fit_timestamp(m.start())
    except (struct.error, ValueError):
        t = None
    if t is not None:
        stamps.append(t)
kind('FIT timestamp(s)', [str(t) for t in stamps], str(epoch))
sys.exit(1 if bad else 0)
PY
  log "boot_package.fex carries the pinned SOURCE_DATE_EPOCH ${SOURCE_DATE_EPOCH} in every banner and FIT timestamp"

  # Which objects BL31 links, read from the link map of this bl31.elf: the
  # linker lists every input file as a LOAD line. A search of the build
  # directory cannot tell an input of this link from an object an earlier build
  # left there, and with link-time optimisation (the GCC release default) the C
  # functions of these files are inlined and leave no symbol to look for.
  bl31_objs="$(sed -n 's|^LOAD .*/\([^/]*\.o\)$|\1|p' "${bl31_map}" | sort -u)"
  [ -n "${bl31_objs}" ] || die "no LOAD lines in ${bl31_map} -- cannot tell which objects BL31 links"
  # Native PSCI CPU_SUSPEND, asserted against platform.mk in both directions:
  # size cannot tell an armed build from a built-out one (the added text fits
  # inside existing page padding), the version banner names TF-A, not our flags.
  # allwinner-common.mk adds sunxi_cpu_suspend.c only under
  # SUNXI_PSCI_NATIVE_SUSPEND=1, so the object is linked iff the feature is in.
  local susp_want susp_obj=""
  susp_want="$(sed -n 's/^[[:space:]]*SUNXI_PSCI_NATIVE_SUSPEND[[:space:]]*:\{0,1\}=[[:space:]]*\([01]\).*/\1/p' "${mkf}" | tail -1)"
  [ -n "${susp_want}" ] || die "cannot read SUNXI_PSCI_NATIVE_SUSPEND from the A733 platform.mk -- overlay changed shape?"
  ! grep -qx 'sunxi_cpu_suspend.o' <<<"${bl31_objs}" || susp_obj=sunxi_cpu_suspend.o
  if [ "${susp_want}" = 1 ]; then
    [ -n "${susp_obj}" ] \
      || die "platform.mk arms SUNXI_PSCI_NATIVE_SUSPEND=1 but bl31.elf does not link sunxi_cpu_suspend.o -- the feature silently did not compile in"
    # The per-core reset check (AA64nAA32 + RVBAR read back) prints its mask in
    # the arming summary; without it a core 0 that resets into the BROM would be
    # armed again.
    grep -aqF 'reset to BL31 0x' "${src_bl31}" \
      || die "native suspend armed but bl31.bin has no 'reset to BL31' summary -- tf-a patch allwinner-a733-native-psci-cpu-suspend did not take"
    log "deep idle: ARMED (platform.mk=1, sunxi_cpu_suspend.o linked)"
  else
    [ -z "${susp_obj}" ] \
      || die "platform.mk sets SUNXI_PSCI_NATIVE_SUSPEND=0 but bl31.elf links ${susp_obj} -- the build-out did not take"
    log "deep idle: built out (platform.mk=0, sunxi_cpu_suspend.o not linked)"
  fi
  # CPU_BACK_PLL enable: the kernel parks the CPU clusters on this PLL during a
  # relock and falls back to the 26 MHz DCXO when it is off, so a chain that
  # silently lost the enable still boots and only runs slower. The object in the
  # link map proves it is linked, the log string that the packed BL31 is that build.
  grep -qx 'sunxi_cpu_back_pll.o' <<<"${bl31_objs}" \
    || die "bl31.elf does not link sunxi_cpu_back_pll.o -- tf-a patch allwinner-a733-enable-cpu-back-pll did not take"
  grep -aqF 'BL31: CPU_BACK_PLL' "${pkg}" \
    || die "boot_package.fex carries no 'BL31: CPU_BACK_PLL' string -- the packed BL31 lacks the back-PLL enable"
  log "CPU_BACK_PLL enable: in BL31 and in boot_package.fex"
  # SCPI PSCI path built out: mainline's or1k/A31-msgbox SCPI code must not reach
  # an A733 BL31, where its SCP release would write an undocumented CPUIDLE register.
  local scpi_obj
  scpi_obj="$(grep -x -m1 -e 'sunxi_scpi_pm.o' -e 'sunxi_msgbox.o' -e 'css_scpi.o' <<<"${bl31_objs}" || true)"
  [ -z "${scpi_obj}" ] \
    || die "bl31.elf links ${scpi_obj} -- tf-a patch allwinner-a733-add-initial-support (SUNXI_PSCI_USE_SCPI := 0) did not take (SCPI path built in)"
  log "SCPI PSCI path: built out"

  # Cortex-A76 errata 1946160 and 2743102. A flag that silently stopped taking
  # would change nothing a boot can see, so assert the linked BL31. The errata
  # framework inlines reset-time workarounds into cortex_a76_reset_func and
  # leaves only an erratum_cortex_a76_<id>_skip_reset label, which it emits for a
  # chosen erratum only; runtime workarounds keep their own
  # erratum_cortex_a76_<id>_wa function. 1946160 is a reset workaround, 2743102 a
  # runtime one, and cortex_a76_core_pwr_dwn must read the revision itself --
  # without that the 2743102 check takes x10 as found.
  # Tool output goes into a variable first: `nm f | grep -q x` fails under
  # pipefail exactly when x is found early and grep closes the pipe (SIGPIPE).
  local pwrdn
  syms="$("${tc}nm" "${bl31_elf}")" || die "nm failed on ${bl31_elf}"
  grep -q " erratum_cortex_a76_1946160_skip_reset$" <<<"${syms}" \
    || die "bl31.elf has no erratum_cortex_a76_1946160_skip_reset -- ERRATA_A76_1946160 did not take"
  grep -q " erratum_cortex_a76_2743102_wa$" <<<"${syms}" \
    || die "bl31.elf has no erratum_cortex_a76_2743102_wa -- ERRATA_A76_2743102 did not take"
  pwrdn="$("${tc}objdump" -d "${bl31_elf}" | sed -n '/<cortex_a76_core_pwr_dwn>:/,/ret/p')" \
    || die "objdump failed on ${bl31_elf}"
  grep -q '<cpu_get_rev_var>' <<<"${pwrdn}" \
    || die "cortex_a76_core_pwr_dwn does not call cpu_get_rev_var -- the 2743102 revision check is gone from the TF-A base"
  log "Cortex-A76 errata 1946160 + 2743102: in BL31, 2743102 with its own revision check"

  # The power-down WFI of CPU_SUSPEND. TF-A master executes one WFI after the
  # CPU's power-down hook; should that WFI return, PSCI calls the hook again and
  # panics unless the hook acknowledges a powerdown abandon. Cortex-A55 and
  # Cortex-A76 cannot abandon: once CPUPWRCTLR_EL1.CORE_PWRDN_EN is 1, a WFI
  # masks every interrupt and wake-up event and only a reset ends it (Cortex-A55
  # TRM 100442_0200_03_en 2.4.8; Cortex-A76 TRM 100798_0401_01_en 5.9). That
  # keeps the panic unreachable exactly as long as the hook PSCI calls on each
  # core sets CORE_PWRDN_EN and synchronises it before the WFI. So assert it in
  # the linked image: the cpu_ops entry of each MIDR has its core's hook in both
  # power-down slots (scripts/lib/aarch64-cpu-ops.py), and the hook sets bit 0 of
  # CPUPWRCTLR_EL1 (S3_0_C15_C2_7) by mrs/orr #0x1/msr -- no other write of the
  # register -- and issues an ISB after it, before it returns.
  local ops core midr hook
  ops="$(python3 "${SRC}/scripts/lib/aarch64-cpu-ops.py" "${tc}" "${bl31_elf}")" \
    || die "cannot read the cpu_ops table of ${bl31_elf} (reason above)"
  for core in cortex_a55:0x410fd050 cortex_a76:0x410fd0b0; do
    midr="${core#*:}"; core="${core%%:*}"
    grep -qx "${midr} ${core}_core_pwr_dwn ${core}_core_pwr_dwn" <<<"${ops}" \
      || die "the cpu_ops of MIDR ${midr} do not point both power-down slots at ${core}_core_pwr_dwn; cpu_ops: $(tr '\n' ';' <<<"${ops}")"
    hook="$("${tc}objdump" -d "${bl31_elf}" | sed -n "/<${core}_core_pwr_dwn>:/,/\tret/p")" \
      || die "objdump failed on ${bl31_elf}"
    awk '
      { l[NR] = $0 }
      /msr[ \t]+s3_0_c15_c2_7,/ { w++ }
      END {
        for (i = 2; i < NR; i++)
          if (l[i-1] ~ /mrs[ \t]+x[0-9]+, s3_0_c15_c2_7$/ && l[i] ~ /orr[ \t]+x[0-9]+, x[0-9]+, #0x1$/ && l[i+1] ~ /msr[ \t]+s3_0_c15_c2_7, x[0-9]+$/) {
            for (j = i + 2; j < NR; j++) if (l[j] ~ /\tisb/) isb = 1
            exit !(isb && w == 1 && l[NR] ~ /\tret/)
          }
        exit 1 }' <<<"${hook}" \
      || die "${core}_core_pwr_dwn does not set CPUPWRCTLR_EL1.CORE_PWRDN_EN (mrs/orr #0x1/msr s3_0_c15_c2_7, then isb, then ret, no other write) -- a power-down WFI could return into PSCI's abandon path, which panics on this core"
  done
  log "Cortex-A55 / Cortex-A76 power-down: cpu_ops of both MIDRs carry the core hook, which sets CORE_PWRDN_EN and ISBs before the WFI"

  # Upstream's allwinner-common.mk turns the CPU CVE workarounds off for every
  # Allwinner SoC, which is right for the A53-only ones and wrong for the
  # Cortex-A76 cores; allwinner-cortex-a53-opt-outs-in-the-a53-makefile moves
  # them to allwinner-common-a53.mk, which the A733 does not include. If that
  # patch ever stops taking, nothing a boot shows would change -- the BL31 would
  # simply lose Spectre-BHB and SSB. So assert the CVE-2022-23960 vector table,
  # the eight settings as the build used them (config.h holds every define the
  # build passed: the TF-A defaults, none of the A53 values), the end of
  # cortex_a76_reset_func (point VBAR_EL3 at the CVE-2022-23960 vectors), and the
  # version banner: the pinned TF-A master, so a chain on another base cannot
  # pass as this one.
  local rst d tfa_base tfa_hash
  grep -q " cortex_a76_wa_cve_vbar$" <<<"${syms}" \
    || die "bl31.elf has no cortex_a76_wa_cve_vbar -- the A76 CVE workarounds are off (tf-a patch allwinner-cortex-a53-opt-outs-in-the-a53-makefile did not take)"
  for d in ENABLE_SPE_FOR_NS:2 ENABLE_SVE_FOR_NS:2 ENABLE_FEAT_MPAM:2 WORKAROUND_CVE_2017_5715:1 \
           WORKAROUND_CVE_2018_3639:1 WORKAROUND_CVE_2022_23960:1 WORKAROUND_CVE_2024_7881:1 WORKAROUND_CVE_2024_5660:1; do
    grep -qx "#define ${d%%:*} ${d#*:}" "${cfg}" \
      || die "the A733 BL31 was built with $(grep -m1 "^#define ${d%%:*} " "${cfg}" || echo "no ${d%%:*}"), not ${d#*:} -- the Cortex-A53 opt-outs reached the A733 (tf-a patch allwinner-cortex-a53-opt-outs-in-the-a53-makefile)"
  done
  rst="$("${tc}objdump" -d "${bl31_elf}" | sed -n '/<cortex_a76_reset_func>:/,/ret/p')"
  grep -q 'msr[[:space:]]*vbar_el3,' <<<"${rst}" \
    || die "cortex_a76_reset_func does not install the CVE-2022-23960 vectors (no msr vbar_el3)"
  tfa_base="$(bootchain_apply_var ATF_BASE)"
  tfa_hash="${src_bl31_ver#v2.15.0(release):}"
  [ "${tfa_hash}" != "${src_bl31_ver}" ] && [ "${#tfa_hash}" -ge 7 ] && [ "${tfa_base#"${tfa_hash}"}" != "${tfa_base}" ] \
    || die "bl31.bin is not built from TF-A master ${tfa_base} (banner: ${src_bl31_ver})"
  log "TF-A base master ${tfa_base} (v2.15.0); A76 reset installs the CVE-2022-23960 vectors"

  # Cortex-A76 errata 2356586 and 3888013, reset-time bits in CPUACTLR2_EL1
  # (S3_0_C15_C1_1) -- bit 0 and bit 22 (0x400000) -- asserted against
  # platform.mk in both directions. Both are required: 3888013 costs the A76
  # about half its Non-cacheable read bandwidth, and the decision is that it
  # stays on. It keeps its own enabling patch so a measurement build can drop
  # it; such a build must also set A7S_BUILD_WITHOUT_ERRATUM_3888013=1, and then
  # it builds with a warning that says it is not the shipping chain.
  local e want bit
  for e in 2356586:0x1 3888013:0x400000; do
    bit="${e#*:}"; e="${e%%:*}"
    want="$(sed -n "s/^[[:space:]]*ERRATA_A76_${e}[[:space:]]*:\{0,1\}=[[:space:]]*\([01]\).*/\1/p" "${mkf}" | tail -1)"
    if [ "${want}" = 1 ]; then
      grep -q " erratum_cortex_a76_${e}_skip_reset$" <<<"${syms}" \
        || die "platform.mk sets ERRATA_A76_${e} but bl31.elf has no erratum_cortex_a76_${e}_skip_reset"
      # The exact read-modify-write, three consecutive instructions, so an
      # unrelated orr of the same immediate elsewhere in the function cannot pass.
      awk -v b="#${bit}" '
        { l[NR] = $0 }
        END { for (i = 2; i < NR; i++)
                if (l[i-1] ~ /mrs[ \t]+x[0-9]+, s3_0_c15_c1_1$/ && index(l[i], "orr") && substr(l[i], length(l[i]) - length(b) + 1) == b && l[i+1] ~ /msr[ \t]+s3_0_c15_c1_1, x[0-9]+$/) exit 0
              exit 1 }' <<<"${rst}" \
        || die "cortex_a76_reset_func has no mrs/orr ${bit}/msr on CPUACTLR2_EL1 (s3_0_c15_c1_1) for erratum ${e}"
      log "Cortex-A76 erratum ${e}: in the A76 reset, sets ${bit} in CPUACTLR2_EL1"
    else
      ! grep -q " erratum_cortex_a76_${e}_skip_reset$" <<<"${syms}" \
        || die "platform.mk does not set ERRATA_A76_${e} but bl31.elf has erratum_cortex_a76_${e}_skip_reset"
      if [ "${e}" = 3888013 ] && [ "${A7S_BUILD_WITHOUT_ERRATUM_3888013:-0}" = 1 ]; then
        warn "this boot chain is built WITHOUT the Cortex-A76 erratum 3888013 workaround, on purpose (A7S_BUILD_WITHOUT_ERRATUM_3888013=1). Not the shipping chain."
      elif [ "${e}" = 3888013 ]; then
        die "platform.mk does not set ERRATA_A76_3888013 -- tf-a patch allwinner-a733-apply-a76-erratum-3888013 did not take. A measurement build without it must set A7S_BUILD_WITHOUT_ERRATUM_3888013=1"
      else
        die "platform.mk does not set ERRATA_A76_${e} -- tf-a patch allwinner-a733-apply-a76-errata did not take"
      fi
    fi
  done

  # CVE-2025-10263 (Cortex-A76 erratum 4193800): after an Inner/Outer Shareable
  # TLBI + DSB, the code must issue one more TLBI + DSB. TF-A puts that into the
  # xlat library only, which the A733 builds without PLAT_XLAT_TABLES_DYNAMIC,
  # so the linked BL31 has no broadcast TLBI at all. What must hold is the
  # property: every broadcast TLBI in bl31.elf sits in the workaround itself or
  # in xlat_arch_tlbi_va, whose sync function then has to call it. A broadcast
  # TLBI anywhere else fails the build, so a patch that adds one has to answer
  # for the erratum.
  local cve_want tlbi_fns f
  cve_want="$(sed -n 's/^[[:space:]]*WORKAROUND_CVE_2025_10263[[:space:]]*:\{0,1\}=[[:space:]]*\([01]\).*/\1/p' "${mkf}" | tail -1)"
  [ "${cve_want}" = 1 ] \
    || die "platform.mk does not set WORKAROUND_CVE_2025_10263 -- tf-a patch allwinner-a733-apply-a76-errata did not take"
  tlbi_fns="$("${tc}objdump" -d "${bl31_elf}" \
    | awk '/^[0-9a-f]+ <.*>:$/ {f = $2} /\ttlbi\t[a-z0-9]*(is|os)([,[:space:]]|$)/ {print f}' | sort -u)"
  for f in ${tlbi_fns}; do
    case "${f}" in
      "<apply_cve_2025_10263_wa>:") ;;
      "<xlat_arch_tlbi_va>:")
        "${tc}objdump" -d "${bl31_elf}" | sed -n '/<xlat_arch_tlbi_va_sync>:/,/ret/p' \
          | grep -q '<apply_cve_2025_10263_wa>' \
          || die "xlat_arch_tlbi_va issues a broadcast TLBI but xlat_arch_tlbi_va_sync does not call apply_cve_2025_10263_wa (CVE-2025-10263)" ;;
      *) die "${f%:} issues a broadcast TLBI outside the CVE-2025-10263 workaround path -- add the second TLBI + DSB (Cortex-A76 erratum 4193800)" ;;
    esac
  done
  log "CVE-2025-10263: on in platform.mk; broadcast TLBI in: ${tlbi_fns:-none}"

  # The security setup in sunxi_security_setup() (tf-a patches
  # allwinner-a733-security-setup and allwinner-a733-add-initial-support):
  # PRCM_SEC_SWITCH_REG (0x07010290) gets 0x7 set read-modify-write
  # (SUNXI_R_PRCM_SEC_SWITCH_NS in platform.mk, UM V1.00 4.2.5.26); the A523's
  # DSP PRCM write, which on the A733 put 7 into S_PRCM + 0x8 (no register, UM
  # 4.2.4), is gone; and the CCU security switch goes to CCU + 0x1F00 =
  # 0x02003F00 (UM 4.1.6.278), not to CCU + 0x0F00 = 0x02002F00, which is
  # SPI0_CLK_REG (4.1.6.160). None of it changes anything a boot shows, so check
  # the linked code itself: scripts/lib/aarch64-mmio-stores.py --anchor finds, in
  # the disassembly of all of our bl31.elf, the one straight-line region that
  # stores to PRCM_SEC_SWITCH_REG and lists every store it makes, address and
  # value followed through the disassembly (`[A]|0x7` = the word at A with 0x7
  # set, i.e. mmio_setbits_32). The region, not the symbol: with link-time
  # optimisation sunxi_security_setup() is inlined into bl31_main(). It fails if
  # no region or more than one stores there and on any store it cannot resolve,
  # so an unexpected compiler output fails here instead of passing as "no such
  # store". The S_TZMA and S_SPC writes (from the dlan17 TF-A fork's public A523
  # code) are asserted as well, so dropping them has to be a decision.
  local sec_ns sec_st a
  sec_ns="$(sed -n 's/^[[:space:]]*SUNXI_R_PRCM_SEC_SWITCH_NS[[:space:]]*:\{0,1\}=[[:space:]]*\(0x[0-9a-fA-F]*\).*/\1/p' "${mkf}" | tail -1)"
  [ "${sec_ns}" = 0x7 ] \
    || die "the A733 platform.mk sets SUNXI_R_PRCM_SEC_SWITCH_NS to '${sec_ns}', not 0x7 -- tf-a patch allwinner-a733-security-setup did not take"
  sec_st="$("${tc}objdump" -d "${bl31_elf}" | python3 "${SRC}/scripts/lib/aarch64-mmio-stores.py" --anchor 0x07010290)" \
    || die "cannot list the stores of the code that writes PRCM_SEC_SWITCH_REG in bl31.elf (reason above) -- extend scripts/lib/aarch64-mmio-stores.py or check the code by hand"
  [ "$(grep -c '^0x7010290 ' <<<"${sec_st}" || true)" = 1 ] && grep -qx '0x7010290 \[0x7010290\]|0x7' <<<"${sec_st}" \
    || die "sunxi_security_setup does not set 0x7 in PRCM_SEC_SWITCH_REG (0x07010290) by one read-modify-write; its stores: $(tr '\n' ' ' <<<"${sec_st}")"
  ! grep -q '^0x7010008 ' <<<"${sec_st}" \
    || die "sunxi_security_setup writes S_PRCM + 0x8 (0x07010008), which is no register (UM 4.2.4) -- the A523 DSP PRCM write reached the A733"
  grep -qx '0x2003f00 0x7' <<<"${sec_st}" \
    || die "sunxi_security_setup does not write 0x7 to CCMU_SEC_SWITCH_REG (0x02003F00) -- the CCU offset of tf-a patch allwinner-a733-add-initial-support did not take"
  ! grep -q '^0x2002f00 ' <<<"${sec_st}" \
    || die "sunxi_security_setup writes CCU + 0x0F00 (0x02002F00), SPI0_CLK_REG on the A733 (UM 4.1.6.160)"
  for a in 0x7003000:0x0 0x7003004:0x0 0x7003008:0x0 0x7002004:0xffffffff 0x7002014:0xffffffff 0x7002024:0xffffffff; do
    grep -qx "${a%%:*} ${a#*:}" <<<"${sec_st}" \
      || die "sunxi_security_setup no longer writes ${a#*:} to ${a%%:*} (S_TZMA / S_SPC) -- they stay"
  done
  log "security setup: PRCM_SEC_SWITCH_REG |= 0x7, no S_PRCM + 0x8, CCMU_SEC_SWITCH_REG at 0x02003F00 (not SPI0_CLK_REG), S_TZMA / S_SPC set (bl31.elf)"

  # EL3 stacks: contiguous, eight of them; an undersized one overflows silently
  # into the next core's. Check the linked size against the declared one:
  # SUNXI_PLAT_STACK_SIZE per core, 0 = the common default, 0x1000 shared by
  # eight cores.
  local stk stk_lo stk_hi stk_want
  stk="$(sed -n 's/^[[:space:]]*SUNXI_PLAT_STACK_SIZE[[:space:]]*:\{0,1\}=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "${mkf}" | tail -1)"
  [ -n "${stk}" ] || die "cannot read SUNXI_PLAT_STACK_SIZE from the A733 platform.mk -- overlay changed shape?"
  stk_lo="$(sed -n 's/^[[:space:]]*0x\([0-9a-f]*\)[[:space:]]*__STACKS_START__ = \..*/\1/p' "${bl31_map}" | head -1)"
  stk_hi="$(sed -n 's/^[[:space:]]*0x\([0-9a-f]*\)[[:space:]]*__STACKS_END__ = \..*/\1/p' "${bl31_map}" | head -1)"
  [ -n "${stk_lo}" ] && [ -n "${stk_hi}" ] || die "no __STACKS_START__/__STACKS_END__ in ${bl31_map}"
  stk_want=$(( stk == 0 ? 0x1000 : stk * 8 ))
  [ $(( 0x${stk_hi} - 0x${stk_lo} )) = "${stk_want}" ] \
    || die "BL31 EL3 stacks are $(( 0x${stk_hi} - 0x${stk_lo} )) B, platform.mk SUNXI_PLAT_STACK_SIZE=${stk} wants ${stk_want} B"
  log "BL31 EL3 stacks: $(( stk_want / 8 )) B per core, 0x${stk_lo}-0x${stk_hi}"
}

pins_bootchain() {
  log "bootchain: ${BOOTCHAIN_URL} @ ${BOOTCHAIN_COMMIT}"
  log "           submodules by commit id: pins/bootchain-submodules.txt; prebuilt files: pins/bootchain-blobs.sha256"
  log "           TF-A $(bootchain_apply_var ATF_UPSTREAM) @ $(bootchain_apply_var ATF_BASE)"
  log "           + $(grep -cEv '^(#|$)' "${SRC}/bootchain/patches/tf-a/series") TF-A patches, $(grep -cEv '^(#|$)' "${SRC}/bootchain/patches/u-boot/series") U-Boot patches"
  log "           RISC-V toolchain sha256 ${RISCV_TC_SHA256}"
  log "           overlay id $(bootchain_overlay_id | cut -c1-12)"
}

# Group stage run by the full chain (inner.sh all).
stage_bootchain() { stage_fetch_bootchain && stage_build_bootchain; }
