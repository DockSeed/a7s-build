# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# Where the boot chain sits on the card, and the check that it fits. Sourced,
# never run: `build-bootchain` and the image stage read the constants from here,
# so there is one copy of them.
#
# Layout of the gap in front of the first partition (offsets in KiB):
#
#   0        MBR (sector 0)
#   128      boot0_sdcard.bin   (the BROM loads it from sector 256)
#   12288    boot_package.fex   (boot0 loads it from 12 MiB)
#   16384    first partition    (the ext4 root)
#
# Nothing is allocated here: the three offsets are fixed, so the room each
# artefact has is the distance to the next one. `dd conv=notrunc` writes past
# the room without a word, and the sunxi magic that the image stage reads back after
# the write is still there when the tail of the package has overwritten the
# start of the filesystem -- so the fit is checked from the sizes, before
# anything is written. U-Boot grows with every driver it gains (NVMe, PCIe, UFS).

# Boot-chain on-card offsets. They are the values the boot ROM and boot0 use
# (boot0 is loaded by the BROM from sector 256, boot0 loads the package from
# 12 MiB) and they were proven by booting a card written this way. The first
# partition must clear boot_package (~2.4 MiB, ending ~14.4 MiB), so it starts
# at 16 MiB.
BOOT0_OFFSET_KIB=128
BOOTPKG_OFFSET_KIB=12288   # 12 MiB
P1_START_MIB=16

# bootchain_layout_check <boot0-file> <package-file>
#     The two files, at the offsets above, must each end before the next thing
#     starts: boot0 before the package, the package before the first partition.
#     Compared in bytes, because dd writes exactly the bytes the file has.
#     Both problems are reported when both exist, as `::error::` lines on stderr
#     (the same form series_load uses), and the return is 1; the caller adds the
#     `die`. On success one `===` line states the room that is left.
#     Reads the three constants above; refuses a layout whose offsets are not
#     in increasing order after the MBR, and an empty or missing file.
bootchain_layout_check() {
  local boot0="${1:?bootchain_layout_check: boot0 file}" pkg="${2:?bootchain_layout_check: package file}"
  local b0_off=$(( BOOT0_OFFSET_KIB * 1024 ))
  local pkg_off=$(( BOOTPKG_OFFSET_KIB * 1024 ))
  local p1_off=$(( P1_START_MIB * 1024 * 1024 ))
  local bad=0 f over

  # The MBR is sector 0 (512 B); boot0 may not start inside it.
  if [ "${b0_off}" -lt 512 ] || [ "${b0_off}" -ge "${pkg_off}" ] || [ "${pkg_off}" -ge "${p1_off}" ]; then
    echo "::error:: layout constants out of order: boot0 @${BOOT0_OFFSET_KIB} KiB, package @${BOOTPKG_OFFSET_KIB} KiB, first partition @$(( P1_START_MIB * 1024 )) KiB (${P1_START_MIB} MiB)" >&2
    return 1
  fi

  local b0_size pkg_size
  for f in "${boot0}" "${pkg}"; do
    if [ ! -f "${f}" ]; then
      echo "::error:: ${f}: not a regular file" >&2
      bad=1
    elif [ ! -s "${f}" ]; then
      echo "::error:: ${f}: empty" >&2
      bad=1
    fi
  done
  [ "${bad}" = 0 ] || return 1
  b0_size="$(wc -c < "${boot0}")"
  pkg_size="$(wc -c < "${pkg}")"

  if [ $(( b0_off + b0_size )) -gt "${pkg_off}" ]; then
    over=$(( b0_off + b0_size - pkg_off ))
    echo "::error:: ${boot0##*/} is ${b0_size} B at ${BOOT0_OFFSET_KIB} KiB and ends at $(( (b0_off + b0_size + 1023) / 1024 )) KiB, ${over} B past the start of the package at ${BOOTPKG_OFFSET_KIB} KiB (room: $(( (pkg_off - b0_off) / 1024 )) KiB)" >&2
    bad=1
  fi
  if [ $(( pkg_off + pkg_size )) -gt "${p1_off}" ]; then
    over=$(( pkg_off + pkg_size - p1_off ))
    echo "::error:: ${pkg##*/} is ${pkg_size} B at ${BOOTPKG_OFFSET_KIB} KiB and ends at $(( (pkg_off + pkg_size + 1023) / 1024 )) KiB, ${over} B into the first partition at $(( P1_START_MIB * 1024 )) KiB (${P1_START_MIB} MiB; room: $(( (p1_off - pkg_off) / 1024 )) KiB)" >&2
    bad=1
  fi
  [ "${bad}" = 0 ] || return 1

  printf '=== boot chain fits the image layout: boot0 %s B, %s KiB of %s KiB left before the package; package %s B, %s KiB of %s KiB left before the first partition\n' \
    "${b0_size}" "$(( (pkg_off - b0_off - b0_size) / 1024 ))" "$(( (pkg_off - b0_off) / 1024 ))" \
    "${pkg_size}" "$(( (p1_off - pkg_off - pkg_size) / 1024 ))" "$(( (p1_off - pkg_off) / 1024 ))"
}
