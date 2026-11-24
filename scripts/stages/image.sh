# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# Image stages: rootfs, image, compress. Sourced by scripts/inner.sh after
# scripts/lib/common.sh; defines functions only.
#
#   rootfs    the distro's root filesystem in WORK_DIR/rootfs
#             (scripts/distro/${A7S_DISTRO}/, docs/distro-interface.md)
#   image     kernel, modules, firmware and the boot chain around it, written
#             into a partitioned raw image in OUT_DIR -- distro-agnostic. The
#             kernel is either copied in (A7S_KERNEL=build) or already installed
#             by the distro's packages (A7S_KERNEL=release, docs/kernel.md).
#   compress  xz of the raw image, plus its sha256
#
# Rootless throughout: no loop device, no mount. The root filesystem is built
# from a directory (mke2fs -d), the partition table is written into the image
# file (sfdisk) and the pieces are placed with dd conv=notrunc. docs/image.md
# has the layout and what makes two builds bit-identical.

# MBR disk signature: fixed, so the root partition's PARTUUID (<id>-01), which
# extlinux.conf and fstab name, is the same in every build. Each board replaces
# it on its first boot (a7s-root-identity, which reads it from BUILD-ID).
A7S_DISK_ID="${A7S_DISK_ID:-a7530001}"
# The ext4 UUID and directory hash seed: fixed, for the same reason. The UUID
# is replaced on the first boot, too.
A7S_ROOT_UUID="${A7S_ROOT_UUID:-a7500000-7e57-4a7a-8a7a-000000000001}"
IMAGE_ROOT_LABEL="a7s-root"
# The device tree the kernel stage puts beside the Image in OUT_DIR (the file
# name of its A7S_KERNEL_DTB).
IMAGE_DTB="${A7S_KERNEL_DTB:-allwinner/sun60i-a733-cubie-a7s.dtb}"
IMAGE_DTB="${IMAGE_DTB##*/}"

image_load_distro() {
  local d="${SRC}/scripts/distro/${A7S_DISTRO:-debian}"
  [ -f "${d}/distro.sh" ] || die "A7S_DISTRO=${A7S_DISTRO:-}: no ${d}/distro.sh"
  # shellcheck source=../distro/debian/distro.sh
  . "${d}/distro.sh"
  local f
  for f in distro_rootfs_inputs distro_rootfs_build distro_rootfs_assert; do
    declare -F "${f}" >/dev/null || die "${d}/distro.sh does not define ${f} (docs/distro-interface.md)"
  done
  [ -n "${DISTRO_NAME:-}" ] && [ -n "${DISTRO_RELEASE:-}" ] || die "${d}/distro.sh does not set DISTRO_NAME and DISTRO_RELEASE"
}

image_switch() {  # <name>
  local v="${!1:-0}"
  case "${v}" in 0|1) printf '%s' "${v}" ;; *) die "${1} must be 0 or 1, not '${v}'" ;; esac
}

image_file() {
  printf '%s/%s' "${OUT_DIR}" "${A7S_IMAGE_NAME:-a7s-${DISTRO_RELEASE}-$([ "$(image_switch A7S_DESKTOP)" = 1 ] && echo desktop || echo minimal).img}"
}

# The key of the root filesystem: a sha256 over everything it is made from
# (distro_rootfs_inputs: the distro directory, the switches, the inputs).
image_rootfs_key() {
  distro_rootfs_inputs | sha256sum | cut -d' ' -f1
}

# --- rootfs -------------------------------------------------------------------

stage_rootfs() {
  image_load_distro
  # The distro installs the release packages: they are the pinned bytes, and the
  # DKMS package is the one made from the pinned patches, before dpkg sees them.
  if [ "$(kernel_source)" = release ]; then kernel_verify_output; wifi_verify_output; fi
  local r="${WORK_DIR}/rootfs" key
  key="$(image_rootfs_key)"
  if [ -d "${r}" ] && [ "$(cat "${WORK_DIR}/rootfs.key" 2>/dev/null)" = "${key}" ] && [ "${A7S_ROOTFS_REBUILD:-0}" != 1 ]; then
    log "rootfs: ${r} was built from the same inputs (key ${key:0:16}) -- reused (A7S_ROOTFS_REBUILD=1 builds it again)"
    distro_rootfs_assert "${r}"
    return 0
  fi
  rm -f "${WORK_DIR}/rootfs.key" "${WORK_DIR}/rootfs.inputs"
  rm -rf "${r}"
  distro_rootfs_build "${r}"
  distro_rootfs_assert "${r}"
  distro_rootfs_inputs > "${WORK_DIR}/rootfs.inputs"
  printf '%s\n' "${key}" > "${WORK_DIR}/rootfs.key"
  log "rootfs: ${DISTRO_NAME} ${DISTRO_RELEASE} in ${r} (key ${key:0:16})"
}

# --- image --------------------------------------------------------------------

stage_image() {
  image_load_distro
  local rootfs="${WORK_DIR}/rootfs" stage="${WORK_DIR}/image-root" img fs
  [ -d "${rootfs}" ] && [ -f "${WORK_DIR}/rootfs.key" ] || die "no root filesystem in ${rootfs} -- run the rootfs stage first"
  [ "$(cat "${WORK_DIR}/rootfs.key")" = "$(image_rootfs_key)" ] \
    || die "${rootfs} was built from other inputs than this configuration -- run the rootfs stage again"
  for t in mke2fs dumpe2fs sfdisk depmod tar dd; do command -v "${t}" >/dev/null || die "the image stage needs ${t} (container/packages.d/image.txt)"; done

  # The inputs other stages left in OUT_DIR.
  local kimg="${OUT_DIR}/Image" dtb="${OUT_DIR}/${IMAGE_DTB}"
  local spl="${OUT_DIR}/bootchain/u-boot-sunxi-with-spl.bin" bcid="${OUT_DIR}/bootchain/BOOTCHAIN-ID"
  local source; source="$(kernel_source)"
  if [ "${source}" = build ]; then
    [ -s "${kimg}" ] || die "no kernel Image in ${OUT_DIR} -- run the kernel stage"
    [ -s "${dtb}" ] || die "no ${IMAGE_DTB} in ${OUT_DIR} -- run the kernel stage"
  fi
  kernel_verify_output
  bootchain_verify_output

  # A copy of the root filesystem to add the kernel side to; the rootfs stays
  # as the distro built it.
  log "image: staging ${rootfs} -> ${stage}"
  rm -rf "${stage}"
  cp -a --reflink=auto "${rootfs}" "${stage}"

  # The kernel's files in the tree and the paths U-Boot reads them from.
  local kver kpath fpath
  if [ "${source}" = release ]; then
    kver="$(image_release_kernel "${stage}")"
    kpath="/boot/vmlinuz-${kver}"
    fpath="/usr/lib/linux-image-${kver}/${KERNEL_RELEASE_DTB}"
  else
    kver="$(image_add_modules "${stage}")"
    install -d -m0755 "${stage}/boot"
    install -m0644 "${kimg}" "${stage}/boot/Image"
    install -m0644 "${dtb}" "${stage}/boot/${IMAGE_DTB}"
    kpath="/boot/Image"
    fpath="/boot/${IMAGE_DTB}"
  fi
  image_add_firmware "${stage}" "${kver}"
  image_add_bootchain_copyright "${stage}"
  image_depmod "${stage}" "${kver}"
  image_add_boot "${stage}" "${bcid}" "${kver}" "${kpath}" "${fpath}"

  # The rules hold for the finished tree, not only for the rootfs.
  distro_rootfs_assert "${stage}"
  image_assert_kernel_side "${stage}" "${kver}" "${kpath}"

  img="$(image_file)"
  fs="${WORK_DIR}/rootfs.ext4"
  rm -f "${img}" "${img}.xz" "${img}.xz.sha256" "${fs}"
  mkdir -p "${OUT_DIR}"
  image_assemble "${stage}" "${fs}" "${img}" "${spl}"
  rm -f "${fs}"
  ( cd "${OUT_DIR}" && sha256sum "${img##*/}" ) > "${img}.sha256"
  log "image ready -> ${img} ($(du -h --apparent-size "${img}" | cut -f1), sha256 $(cut -c1-16 "${img}.sha256")...)"
}

# Kernel modules from the kernel stage: OUT_DIR/modules/{usr/,}lib/modules/<version>.
image_add_modules() {  # <root> -- prints the kernel version
  local r="$1" src d n
  for d in "${OUT_DIR}/modules/usr/lib/modules" "${OUT_DIR}/modules/lib/modules"; do
    [ -d "${d}" ] && src="${d}" && break
  done
  [ -n "${src:-}" ] || die "no modules in ${OUT_DIR}/modules/lib/modules -- run the kernel stage"
  n="$(find "${src}" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  [ "${n}" = 1 ] || die "${src} holds ${n} kernel versions, expected exactly one"
  d="$(find "${src}" -mindepth 1 -maxdepth 1 -type d)"
  install -d -m0755 "${r}/usr/lib/modules"
  cp -a --no-preserve=ownership "${d}" "${r}/usr/lib/modules/"
  # The build directory links point into the kernel tree of the build host.
  rm -f "${r}/usr/lib/modules/${d##*/}/build" "${r}/usr/lib/modules/${d##*/}/source"
  printf '%s' "${d##*/}"
}

# The release kernel is in the tree as its packages left it (the distro installed
# them): prints its version after checking that it is the only kernel and that
# its image, device tree and headers are in place.
image_release_kernel() {  # <root>
  local r="$1" kver="${KERNEL_RELEASE_NAME}" n
  n="$(find "${r}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  [ "${n}" = 1 ] && [ -d "${r}/usr/lib/modules/${kver}" ] \
    || die "${r}/usr/lib/modules holds ${n} kernel version(s), expected only ${kver} -- the distro did not install the release kernel"
  [ -s "${r}/boot/vmlinuz-${kver}" ] && [ -s "${r}/usr/lib/linux-image-${kver}/${KERNEL_RELEASE_DTB}" ] \
    || die "the release kernel's image or device tree is missing in the tree"
  [ -d "${r}/usr/src/linux-headers-${kver}" ] || die "the release kernel's headers are missing in the tree"
  printf '%s' "${kver}"
}

image_depmod() {  # <root> <kver>
  depmod -b "$1" "$2" || die "depmod failed for $2"
  [ -s "$1/usr/lib/modules/$2/modules.dep" ] || die "depmod wrote no modules.dep"
}

# WLAN/BT (aic8800: firmware here, modules from the kernel stage) and the GPU
# firmware.
image_add_firmware() {  # <root> <kver>
  local r="$1" kver="$2" aic d fw lic mods=""
  aic="${OUT_DIR}/aic8800/usr/lib"
  for d in aic_load_fw.ko aic8800_fdrv.ko; do
    find "${r}/usr/lib/modules/${kver}" -name "${d}*" -print -quit | grep -q . || mods+=" ${d}"
  done
  # The driver modules come with the kernel (A7S_KERNEL=build) or from DKMS
  # (release; they are .ko files unless the kernel compresses modules); the keep-cfg80211 rule goes with them.
  if [ -z "${mods}" ]; then
    install -d -m0755 "${r}/etc/modprobe.d"
    cat > "${r}/etc/modprobe.d/aic8800-keep-cfg80211.conf" <<'EOF'
# a7s-build: `modprobe -r aic8800_fdrv` would take cfg80211 with it (nothing
# else holds it), and the running wpa_supplicant then falls back to wext, which
# this kernel does not have. Remove the driver alone.
remove aic8800_fdrv /sbin/rmmod aic8800_fdrv
EOF
  fi
  if [ -d "${aic}/firmware/aic8800D80" ]; then
    wifi_verify_output
    [ -z "${mods}" ] || die "the aic8800 firmware is in the image but not its modules:${mods}"
    install -d -m0755 "${r}/usr/lib/firmware/aic8800D80"
    cp -a --no-preserve=ownership "${aic}/firmware/aic8800D80/." "${r}/usr/lib/firmware/aic8800D80/"
    if [ -f "${SRC}/out-of-tree/aic8800/firmware.sha256" ]; then
      ( cd "${r}/usr/lib/firmware/aic8800D80" && grep -v '^#' "${SRC}/out-of-tree/aic8800/firmware.sha256" | sha256sum -c --quiet - ) \
        || die "the aic8800 firmware does not match out-of-tree/aic8800/firmware.sha256"
    fi
    log "wifi/bt: aic8800 firmware (hashes checked) + aic_load_fw.ko + aic8800_fdrv.ko"
  else
    warn "wifi/bt: no aic8800 firmware in ${OUT_DIR}/aic8800 -- the image has NO working WLAN and NO Bluetooth (run the wifi stage)"
  fi
  mods=""

  # The gpu-firmware stage wrote both files after checking them; they are
  # checked again against the same pins (gpu-firmware.sh) as they go in, so a
  # stale or edited OUT_DIR cannot put another file in the image.
  fw="${OUT_DIR}/gpu-firmware/${GPU_FW_NAME}"
  lic="${OUT_DIR}/gpu-firmware/LICENSE.powervr"
  [ -f "${fw}" ] || die "no ${GPU_FW_NAME} in ${OUT_DIR}/gpu-firmware -- run the gpu-firmware stage"
  [ -f "${lic}" ] || die "no LICENSE.powervr beside ${fw}"
  _sha256_ok "${GPU_FW_SHA}" "${fw}" || die "${fw} does not match GPU_FW_SHA (scripts/stages/gpu-firmware.sh)"
  _sha256_ok "${GPU_FW_LIC_SHA}" "${lic}" || die "${lic} does not match GPU_FW_LIC_SHA (scripts/stages/gpu-firmware.sh)"
  install -d -m0755 "${r}/usr/lib/firmware/powervr" "${r}/usr/share/doc/powervr-firmware"
  install -m0644 "${fw}" "${r}/usr/lib/firmware/powervr/"
  install -m0644 "${lic}" "${r}/usr/share/doc/powervr-firmware/"
  for d in powervr.ko drm_gpuvm.ko drm_exec.ko gpu-sched.ko drm_shmem_helper.ko; do
    find "${r}/usr/lib/modules/${kver}" -name "${d}" -print -quit | grep -q . || mods+=" ${d}"
  done
  [ -z "${mods}" ] || die "the GPU firmware is in the image but not its modules:${mods}"
  log "gpu: ${GPU_FW_NAME} + LICENSE.powervr (hashes checked)"
}

# The boot chain is written to the raw area in front of the first partition, so
# no package owns it. Its licence notices go where a package's would:
# /usr/share/doc/a733-boot-chain/copyright in the machine-readable format of
# Debian policy 12.5, with the texts and copyright lines the sources carry
# (collected by the bootchain stage) and the commits they were built from. No
# network: everything comes from OUT_DIR/bootchain/licences.
image_deb822_text() {  # continuation lines of a field, from stdin
  sed -e 's/[[:space:]]*$//' -e 's/^$/./' -e 's/^/ /'
}

image_add_bootchain_copyright() {  # <root>
  local r="$1" lic="${OUT_DIR}/bootchain/licences" d bsd kib rec own path spdx name base first fdt=""
  d="${r}/usr/share/doc/a733-boot-chain"
  bootchain_licences_check "${lic}"
  kib="$(sed -n 's/^offset_kib=//p' "${OUT_DIR}/bootchain/BOOTCHAIN-ID")"
  case "${kib}" in ""|*[!0-9]*) die "no offset_kib in ${OUT_DIR}/bootchain/BOOTCHAIN-ID" ;; esac
  # The BSD-3-Clause text of TF-A: the indented block of docs/license.rst from
  # "Redistribution" to the disclaimer, without its "Copyright (c) [XXXX-]YYYY,
  # <OWNER>" template line.
  bsd="$(sed -n '/^    Redistribution and use in source/,/^    SOFTWARE, EVEN IF ADVISED/p' "${lic}/tf-a-license.rst" \
    | sed -e 's/^    //' | image_deb822_text)"
  grep -q 'Neither the name of Arm' <<<"${bsd}" && grep -q 'POSSIBILITY OF SUCH DAMAGE' <<<"${bsd}" \
    || die "the BSD-3-Clause text is not in ${lic}/tf-a-license.rst"
  install -d -m0755 "${d}"
  install -m0644 "${lic}/COPYING.u-boot" "${d}/COPYING.u-boot"
  install -m0644 "${lic}/tf-a-license.rst" "${d}/tf-a-license.rst"
  cp -r --no-preserve=mode,ownership "${lic}/Licenses" "${d}/Licenses"
  find "${d}/Licenses" -type d -exec chmod 0755 {} + || die "cannot set the modes of ${d}/Licenses"
  find "${d}/Licenses" -type f -exec chmod 0644 {} + || die "cannot set the modes of ${d}/Licenses"
  {
    cat <<TEXT
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: U-Boot and TF-A
Source: https://github.com/radxa/u-boot
 https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git
Comment: The boot chain is not a file of this system: it is written to the disk
 in front of the first partition, at ${kib} KiB (SPL, BL31 and U-Boot in one
 image). It was built from these sources:
 .
 U-Boot: https://github.com/radxa/u-boot, commit $(sed -n 's/^u-boot=//p' "${lic}/SOURCES")
 TF-A: https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git, commit $(sed -n 's/^tf-a=//p' "${lic}/SOURCES")
 Build glue: https://github.com/radxa-pkg/u-boot-dlan17, commit $(sed -n 's/^package=//p' "${lic}/SOURCES")
 Patches: https://github.com/DockSeed/a733-bootchain, commit $(sed -n 's/^recipe=//p' "${lic}/SOURCES")
 .
 The patches on U-Boot and TF-A are in the last repository; they are under the
 licence of the code they change. The licence texts in this directory are those
 of the sources above. The paths below are those of the build glue's tree: src/
 is U-Boot (SPL and U-Boot), atf/ is TF-A (BL31), awbin/a733/ddr.bin is the
 DRAM initialisation inside the SPL.

Files: src/*
Copyright: Wolfgang Denk and many others, see the source
License: GPL-2+
Comment: U-Boot is GPL-2 or, at your option, any later version, except where a
 file says otherwise (U-Boot's own statement: Licenses/README). COPYING.u-boot
 is the GPL-2 text. The corresponding source is at the commits above.

Files: atf/*
TEXT
    # The copyright lines of the BL31 sources, from the files the link of this
    # BL31 took (tf-a-files), not from the whole TF-A tree.
    sed -e '1s/^/Copyright: /' -e '2,$s/^/ /' "${lic}/tf-a-copyright"
    cat <<TEXT
License: BSD-3-Clause
Comment: The copyright lines are those of the $(wc -l < "${lic}/tf-a-files") TF-A source files (code and headers) that
 go into BL31, found from its link map and dependency files; the sources with
 their own licence are in the paragraphs below. TF-A's list of the licences of
 the other code inside it is tf-a-license.rst.
TEXT
    if [ -s "${lic}/tf-a-no-notice" ]; then
      echo " These sources carry no copyright line, they are under TF-A's licence:"
      sed 's/^/ /' "${lic}/tf-a-no-notice"
    fi
    echo
    # The sources under a licence of their own, one paragraph each; libfdt
    # (dual licensed, used under BSD-2-Clause) in one.
    for rec in "${lic}"/tf-a-other/*; do
      path="$(sed -n 's/^path=//p' "${rec}")"; spdx="$(sed -n 's/^spdx=//p' "${rec}")"
      if [ -z "$(sed '1,/^--$/d' "${rec}")" ]; then
        case "${spdx}" in
          "(GPL-2.0-or-later OR BSD-2-Clause)") fdt+="${rec}"$'\n'; continue ;;
          *) die "${rec} has no licence text and is not libfdt" ;;
        esac
      fi
      base="$(basename "${path}")"; name="${spdx:-BSD-style}-${base//./-}"
      echo "Files: atf/${path}"
      sed -n 's/^copyright=//p' "${rec}" | sed -e '1s/^/Copyright: /' -e '2,$s/^/ /'
      echo "License: ${name}"
      echo
      own+="License: ${name}"$'\n'"$(sed '1,/^--$/d' "${rec}" | image_deb822_text)"$'\n\n'
    done
    if [ -n "${fdt}" ]; then
      first=1
      for rec in ${fdt}; do
        if [ "${first}" = 1 ]; then echo "Files: atf/$(sed -n 's/^path=//p' "${rec}")"; first=0
        else echo " atf/$(sed -n 's/^path=//p' "${rec}")"; fi
      done
      for rec in ${fdt}; do sed -n 's/^copyright=//p' "${rec}"; done | LC_ALL=C sort -u \
        | sed -e '1s/^/Copyright: /' -e '2,$s/^/ /'
      echo "License: BSD-2-Clause"
      echo "Comment: libfdt is dual licensed (GPL-2.0-or-later OR BSD-2-Clause); TF-A uses it"
      echo " under BSD-2-Clause (tf-a-license.rst). The files carry no text, only the"
      echo " identifier; the text is that of Licenses/bsd-2-clause.txt of U-Boot."
      echo
    fi
    cat <<TEXT
Files: awbin/a733/ddr.bin
Copyright: unknown
License: unknown
Comment: The file is a binary without a licence text or copyright notice, and
 the Debian copyright format has no keyword for that. It is built into the SPL
 unchanged. The copyright file of the build glue (u-boot-dlan17) lists its
 whole tree, this file included, under "Files: *" as GPL-3+; this paragraph
 does not judge that.

License: GPL-2+
 This program is free software; you can redistribute it and/or modify it under
 the terms of the GNU General Public License as published by the Free Software
 Foundation; either version 2 of the License, or (at your option) any later
 version.
 .
 This program is distributed in the hope that it will be useful, but WITHOUT
 ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 details.
 .
 On Debian systems, the complete text of the GNU General Public License
 version 2 can be found in /usr/share/common-licenses/GPL-2, and in
 COPYING.u-boot.

License: BSD-3-Clause
TEXT
    printf '%s\n' "${bsd}"
    if [ -n "${fdt}" ]; then
      printf '\nLicense: BSD-2-Clause\n'
      image_deb822_text < "${lic}/Licenses/bsd-2-clause.txt"
    fi
    if [ -n "${own}" ]; then
      printf '\n%s' "${own%$'\n\n'}"; echo
    fi
  } > "${d}/copyright" || die "cannot write ${d}/copyright"
  chmod 0644 "${d}/copyright"
  log "boot chain: ${d#"${r}"}/copyright, U-Boot and TF-A licence texts"
}

# extlinux and the identity of the build, plus fstab. The kernel and the device
# tree are in the tree already, at <kernel path> and <fdt path> (as U-Boot reads
# them from the root filesystem).
image_add_boot() {  # <root> <BOOTCHAIN-ID> <kver> <kernel path> <fdt path>
  local r="$1" bcid="$2" kver="$3" kpath="$4" fpath="$5" console="" root
  [ -s "${r}${kpath}" ] && [ -s "${r}${fpath}" ] || die "the kernel (${kpath}) or the device tree (${fpath}) is not in the tree"
  root="root=PARTUUID=${A7S_DISK_ID,,}-01 rootwait rw"
  install -d -m0755 "${r}/boot/extlinux"
  # The boot chain's identity, minus a build time stamp if it carries one
  # (the image is reproducible; the chain's bytes and pins identify it).
  grep -v '^built=' "${bcid}" > "${r}/boot/bootchain-id"
  chmod 0644 "${r}/boot/bootchain-id"
  # console=tty0 only on the desktop: on a console image every kernel message
  # would land between the login prompt's lines on the screen. ttyS0 is last,
  # so /dev/console -- init, systemd, the emergency shell -- is the UART.
  # consoleblank=0: the kernel's 600 s blank tears the display pipeline down
  # and nothing brings it back. watchdog.open_timeout=60: the watchdog U-Boot
  # left running resets a kernel that never reaches PID 1 (a rescue boot with
  # init=/bin/sh must add watchdog.open_timeout=0).
  # plymouth.ignore-serial-consoles: the desktop's plymouth would otherwise
  # replay the kernel log in colour on ttyS0 at boot and shutdown.
  if [ "$(image_switch A7S_DESKTOP)" = 1 ]; then
    console="console=tty0 plymouth.ignore-serial-consoles "
  fi
  cat > "${r}/boot/extlinux/extlinux.conf" <<EOF
# a7s-build. Root on the single ext4 partition, no initrd. No menu: U-Boot boots
# the default label.
default a7s
label a7s
    kernel ${kpath}
    fdt ${fpath}
    append ${root} ${console}console=ttyS0,115200 earlycon consoleblank=0 watchdog.open_timeout=60
EOF
  # Safe mode. U-Boot counts boots in RTC GP_DATA_REG7 and, past its bootlimit
  # (3), its altbootcmd boots this file. The same kernel, but multi-user only
  # and without the GPU and WLAN drivers; Ethernet is built in, so the board
  # stays reachable by cable.
  # a7s.fallback keeps a7s-boot-good.service from clearing the counter.
  cat > "${r}/boot/extlinux/extlinux-fallback.conf" <<EOF
# a7s-build: safe mode, booted by U-Boot's altbootcmd after bootlimit failed boots.
# a7s.fallback keeps the boot counter set: the board stays here until it is cleared.
default a7s-fallback
label a7s-fallback
    kernel ${kpath}
    fdt ${fpath}
    append ${root} ${console}console=ttyS0,115200 earlycon consoleblank=0 watchdog.open_timeout=60 systemd.unit=multi-user.target module_blacklist=powervr,aic8800_fdrv,aic_load_fw a7s.fallback
EOF
  chmod 0644 "${r}"/boot/extlinux/*.conf
  printf 'PARTUUID=%s-01 / ext4 defaults,noatime 0 1\n' "${A7S_DISK_ID,,}" > "${r}/etc/fstab"
  # Which build this is, readable on the board. No time stamp: the image is
  # reproducible.
  {
    echo "recipe=a7s-build"
    echo "commit=${A7S_BUILD_COMMIT:-unknown}"
    echo "distro=${DISTRO_NAME} ${DISTRO_RELEASE}"
    echo "snapshot=${A7S_SNAPSHOT:-live}"
    echo "desktop=$(image_switch A7S_DESKTOP)"
    echo "rootfs_key=$(cat "${WORK_DIR}/rootfs.key")"
    echo "kernel=${kver}"
    echo "disk_id=${A7S_DISK_ID,,}"
    echo "root_uuid=${A7S_ROOT_UUID}"
    echo "kernel_sha256=$(sha256sum "${r}${kpath}" | cut -d' ' -f1)"
    echo "dtb=${fpath##*/} $(sha256sum "${r}${fpath}" | cut -d' ' -f1)"
    sed 's/^/bootchain_/' "${r}/boot/bootchain-id"
  } > "${r}/boot/BUILD-ID"
  chmod 0644 "${r}/boot/BUILD-ID"
}

image_assert_kernel_side() {  # <root> <kver> <kernel path>
  local r="$1" kver="$2" kpath="$3"
  [ -s "${r}${kpath}" ] && [ -s "${r}/boot/extlinux/extlinux.conf" ] && [ -s "${r}/boot/extlinux/extlinux-fallback.conf" ] \
    || die "the boot files are incomplete"
  grep -q "root=PARTUUID=${A7S_DISK_ID,,}-01 " "${r}/boot/extlinux/extlinux.conf" || die "extlinux.conf does not name the root partition"
  grep -qx "disk_id=${A7S_DISK_ID,,}" "${r}/boot/BUILD-ID" && grep -qx "root_uuid=${A7S_ROOT_UUID}" "${r}/boot/BUILD-ID" \
    || die "BUILD-ID does not name the build's disk ID and ext4 UUID (a7s-root-identity reads them)"
  [ -s "${r}/usr/lib/modules/${kver}/modules.dep" ] || die "no modules.dep for ${kver}"
  [ -f "${r}/etc/fstab" ] || die "no /etc/fstab"
}

# The size of a tree as ext4 will need it, from file sizes alone (not from the
# builder's filesystem, so every builder computes the same number): each file
# rounded up to 4 KiB blocks, one block per directory, symlink and inode.
image_tree_mib() {  # <dir>
  find "$1" -xdev -printf '%y %s\n' | awk '
    $1 == "f" { b += int(($2 + 4095) / 4096) + 1; next }
    { b += 1 }
    END { printf "%d\n", (b * 4096 + 1048575) / 1048576 }'
}

# Root filesystem from the staged tree, partition table, boot chain.
image_assemble() {  # <tree> <fs file> <image> <u-boot-sunxi-with-spl.bin>
  local tree="$1" fs="$2" img="$3" spl="$4" used head size fsmib m0 pt feat
  used="$(image_tree_mib "${tree}")"
  size="${A7S_IMAGE_SIZE_MB:-}"
  if [ -z "${size}" ]; then
    # Headroom: a quarter of the content, at least 512 MiB, so the first boot
    # has room before a7s-growroot fills the card. Rounded to 64 MiB, at
    # least 1536 MiB.
    head=$(( used / 4 )); [ "${head}" -ge 512 ] || head=512
    size=$(( (P1_START_MIB + used + head + 63) / 64 * 64 ))
    [ "${size}" -ge 1536 ] || size=1536
  fi
  case "${size}" in ''|*[!0-9]*) die "A7S_IMAGE_SIZE_MB must be a number of MiB, not '${size}'" ;; esac
  fsmib=$(( size - P1_START_MIB ))
  [ "${fsmib}" -gt "${used}" ] || die "an image of ${size} MiB cannot hold ${used} MiB of root filesystem"
  log "image: ${size} MiB (root filesystem ${used} MiB of content in a ${fsmib} MiB ext4 at ${P1_START_MIB} MiB)"

  # The tree as one tar stream for mke2fs: names sorted, owners numeric, every
  # mtime clamped to SOURCE_DATE_EPOCH, no atime/ctime, and of the extended
  # attributes only file capabilities (never the builder's SELinux labels).
  # mke2fs takes its own timestamps (superblock, root, lost+found, journal)
  # from SOURCE_DATE_EPOCH; UUID and hash seed are fixed. metadata_csum_seed
  # (Debian's mke2fs default, named here so it does not rest on the builder's
  # mke2fs.conf) keeps the checksums independent of the UUID: the board can
  # change the UUID of its mounted root on the first boot.
  tar -C "${tree}" --create --file=- --format=posix --sort=name --numeric-owner \
      --mtime="@${SOURCE_DATE_EPOCH}" --clamp-mtime \
      --pax-option='exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime' \
      --xattrs --xattrs-include='security.capability' --no-acls --no-selinux \
      . \
    | mke2fs -q -F -t ext4 -b 4096 -O metadata_csum_seed -L "${IMAGE_ROOT_LABEL}" -U "${A7S_ROOT_UUID}" \
        -E "hash_seed=${A7S_ROOT_UUID},root_owner=0:0" -d - "${fs}" "$(( fsmib * 256 ))" \
    || die "mke2fs -d failed"
  feat="$(dumpe2fs -h "${fs}" 2>/dev/null | sed -n 's/^Filesystem features://p')"
  [[ " ${feat} " == *" metadata_csum_seed "* ]] || die "the root filesystem has no metadata_csum_seed: ${feat}"

  truncate -s "${size}M" "${img}"
  printf 'label: dos\nlabel-id: 0x%s\nunit: sectors\n\nstart=%s, type=83\n' \
      "${A7S_DISK_ID,,}" "$(( P1_START_MIB * 2048 ))" \
    | sfdisk --quiet --no-reread --no-tell-kernel "${img}" >/dev/null \
    || die "sfdisk failed on ${img}"
  dd if="${fs}" of="${img}" bs=1M seek="${P1_START_MIB}" conv=notrunc,sparse status=none || die "writing the root filesystem failed"
  log "boot chain: u-boot-sunxi-with-spl.bin @${SPL_OFFSET_KIB} KiB"
  dd if="${spl}" of="${img}" bs=1024 seek="${SPL_OFFSET_KIB}" conv=notrunc status=none || die "writing u-boot-sunxi-with-spl.bin failed"

  # Read back what the board will read.
  m0="$(dd if="${img}" bs=1024 skip="${SPL_OFFSET_KIB}" count=1 status=none | tr -d '\0' | grep -aoF 'eGON.BT0' | head -1 || true)"
  [ "${m0}" = eGON.BT0 ] || die "SPL magic eGON.BT0 not at ${SPL_OFFSET_KIB} KiB"
  cmp -s "${spl}" <(dd if="${img}" bs=1024 skip="${SPL_OFFSET_KIB}" status=none | head -c "$(wc -c < "${spl}")") \
    || die "the image does not carry u-boot-sunxi-with-spl.bin unchanged at ${SPL_OFFSET_KIB} KiB"
  pt="$(sfdisk -d "${img}")" || die "sfdisk cannot read the table back"
  grep -qx "label-id: 0x${A7S_DISK_ID,,}" <<<"${pt}" || die "disk id did not take: ${pt}"
  grep -Eq "^${img//./\\.}1 : start= +$(( P1_START_MIB * 2048 )), size= +$(( fsmib * 2048 )), type=83\$" <<<"${pt}" \
    || die "partition 1 is not ${P1_START_MIB} MiB + ${fsmib} MiB, type 83: ${pt}"
  [ "$(dd if="${img}" bs=1M skip="${P1_START_MIB}" count=1 status=none | head -c 2048 | tail -c 1024 | od -An -tx1 -j56 -N2 | tr -d ' ')" = 53ef ] \
    || die "no ext4 superblock at ${P1_START_MIB} MiB"
  log "image: boot chain at ${SPL_OFFSET_KIB} KiB, partition table (disk id ${A7S_DISK_ID,,}) and the ext4 superblock read back"
}

# --- compress -----------------------------------------------------------------

stage_compress() {
  image_load_distro
  local img
  img="$(image_file)"
  [ -f "${img}" ] || die "no raw image ${img} -- run the image stage"
  rm -f "${img}.xz" "${img}.xz.sha256"
  # -T0 always uses xz's multi-threaded block format, so the thread count does
  # not change the bytes. The raw image is replaced by the .xz.
  xz -T0 -9 "${img}" || die "xz failed"
  rm -f "${img}.sha256"
  ( cd "${OUT_DIR}" && sha256sum "${img##*/}.xz" ) > "${img}.xz.sha256"
  log "compressed: ${img}.xz (sha256 $(cut -c1-16 "${img}.xz.sha256")...)"
}
