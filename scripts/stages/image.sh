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
# The GPU firmware the powervr driver asks for.
IMAGE_GPU_FW="rogue_36.56.104.183_v1.fw"

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
  printf '%s/%s' "${OUT_DIR}" "${A7S_IMAGE_NAME:-a7s-${DISTRO_NAME}-${DISTRO_RELEASE}-$([ "$(image_switch A7S_DESKTOP)" = 1 ] && echo desktop || echo minimal).img}"
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
  local r="$1" kver="$2" aic d fw="" lic="" mods=""
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

  for d in "${OUT_DIR}/gpu-firmware" "${OUT_DIR}/firmware/powervr"; do
    [ -f "${d}/${IMAGE_GPU_FW}" ] && fw="${d}/${IMAGE_GPU_FW}" && lic="${d}/LICENSE.powervr" && break
  done
  [ -n "${fw}" ] || die "no ${IMAGE_GPU_FW} in ${OUT_DIR}/gpu-firmware -- run the gpu-firmware stage"
  [ -f "${lic}" ] || die "no LICENSE.powervr beside ${fw}"
  if [ -f "${SRC}/pins/gpu-firmware.sha256" ]; then
    grep -q "^$(sha256sum "${fw}" | cut -d' ' -f1)  .*${IMAGE_GPU_FW}\$" "${SRC}/pins/gpu-firmware.sha256" \
      || die "${fw} does not match pins/gpu-firmware.sha256"
  fi
  install -d -m0755 "${r}/usr/lib/firmware/powervr" "${r}/usr/share/doc/powervr-firmware"
  install -m0644 "${fw}" "${r}/usr/lib/firmware/powervr/"
  install -m0644 "${lic}" "${r}/usr/share/doc/powervr-firmware/"
  for d in powervr.ko drm_gpuvm.ko drm_exec.ko gpu-sched.ko drm_shmem_helper.ko; do
    find "${r}/usr/lib/modules/${kver}" -name "${d}" -print -quit | grep -q . || mods+=" ${d}"
  done
  [ -z "${mods}" ] || die "the GPU firmware is in the image but not its modules:${mods}"
  log "gpu: ${IMAGE_GPU_FW} + LICENSE.powervr"
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
