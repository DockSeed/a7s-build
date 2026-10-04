# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# WiFi/Bluetooth stages: fetch-wifi, build-wifi. Sourced by scripts/inner.sh.
#
# The AIC8800D80 driver is built out of tree on purpose
# (out-of-tree/aic8800/README.md): importing 130 files of vendor code as
# numbered kernel patches would claim a review that did not happen. Nothing from
# that source is committed to this repository; our changes are the patch series
# in out-of-tree/aic8800/patches/.

# shellcheck source=../lib/series.sh
. "${SRC}/scripts/lib/series.sh"

# Pinned to a COMMIT, not the tag; the tag is recorded so a reader can find the
# release. This tag carries all seven firmware files the driver opens
# (out-of-tree/aic8800/firmware.sha256), and that list is checked.
AIC8800_URL="https://github.com/radxa-pkg/aic8800.git"
AIC8800_TAG="5.0+git20260123.5f7be68d-8"
AIC8800_COMMIT="df4c783b663eba1956579c681acd5e45f25c671d"
# The board's part sits on USB behind the on-board hub, so src/USB is the subtree.
AIC8800_SUBDIR="src/USB/driver_fw/drivers/aic8800"
AIC8800_FW_SUBDIR="src/USB/driver_fw/fw/aic8800D80"

pins_wifi() {
  log "wifi     : ${AIC8800_URL} @ ${AIC8800_COMMIT} (tag ${AIC8800_TAG})"
  log "           $(grep -cEv '^(#|$)' "${SRC}/out-of-tree/aic8800/patches/series") patches, $(grep -cEv '^#' "${SRC}/out-of-tree/aic8800/firmware.sha256") firmware files pinned by sha256"
}

stage_fetch_wifi() {
  mkdir -p "${WORK_DIR}"
  local dir="${WORK_DIR}/aic8800" p
  git_fetch_pinned "${AIC8800_URL}" "${AIC8800_COMMIT}" "${dir}"
  log "aic8800 at ${AIC8800_COMMIT} (tag ${AIC8800_TAG}, verified)"

  # Order: out-of-tree/aic8800/patches/series. `git apply` is exact on context,
  # so the order is not cosmetic.
  series_load "${SRC}/out-of-tree/aic8800/patches" \
    || die "aic8800: patches/series is missing, empty or malformed"
  cd "${dir}"
  for p in "${SERIES[@]}"; do
    git apply --whitespace=nowarn "${SRC}/out-of-tree/aic8800/patches/${p}" \
      || die "aic8800: ${p} did not apply"
    log "applied ${p}"
  done

  # Verify the firmware against OUR hashes, not the vendor manifest: in this tag
  # the manifest (src/firmware_version.md) does not list
  # aic_userconfig_8800d80.txt at all, so it cannot check the set we use.
  ( cd "${dir}/${AIC8800_FW_SUBDIR}" \
    && grep -v '^#' "${SRC}/out-of-tree/aic8800/firmware.sha256" | sha256sum -c - >/dev/null ) \
    || die "aic8800 firmware does not match out-of-tree/aic8800/firmware.sha256"
  log "firmware: $(grep -cv '^#' "${SRC}/out-of-tree/aic8800/firmware.sha256") files match our pins"
}

# Build the two modules against the kernel tree. Needs build-kernel to have run:
# modpost wants that tree's Module.symvers, and without it the .ko still links
# but carries no dependency information, which reads as "no dependencies".
stage_build_wifi() {
  local tree dir
  tree="$(kernel_tree)"
  dir="${WORK_DIR}/aic8800/${AIC8800_SUBDIR}"
  [ -d "${tree}" ] || die "kernel tree missing -- run fetch-kernel, apply-patches and build-kernel first"
  [ -d "${dir}" ]  || die "aic8800 source missing -- run fetch-wifi first"
  [ -f "${tree}/Module.symvers" ] \
    || die "no ${tree}/Module.symvers -- run build-kernel first (a module built without it has no depends:)"
  local kver; kver="$(cat "${tree}/include/config/kernel.release")"

  cd "${tree}"
  _kmake -j"${A7S_JOBS}" M="${dir}" modules || die "aic8800 module build failed"

  local dst="${OUT_DIR}/aic8800/lib/modules/${kver}/updates/aic8800"
  local fwd="${OUT_DIR}/aic8800/lib/firmware/aic8800D80"
  rm -rf "${OUT_DIR}/aic8800"
  mkdir -p "${dst}" "${fwd}"
  local m
  for m in aic_load_fw/aic_load_fw.ko aic8800_fdrv/aic8800_fdrv.ko; do
    [ -f "${dir}/${m}" ] || die "aic8800: ${m} was not produced"
    cp "${dir}/${m}" "${dst}/"
  done
  # Only the files the driver actually opens. The tag ships fifteen; the rest are
  # the RF test mode, calibration, BLE scan filters and foreign chip variants.
  ( cd "${WORK_DIR}/aic8800/${AIC8800_FW_SUBDIR}" \
    && awk '!/^#/ {print $2}' "${SRC}/out-of-tree/aic8800/firmware.sha256" \
       | xargs -I{} cp {} "${fwd}/" ) || die "aic8800: firmware copy failed"

  # Pack what these modules cannot run without. Some are not our dependency in
  # the modinfo sense and are named here on purpose:
  #   cfg80211  -- aic8800_fdrv's actual `depends:`, so wlan0 cannot appear without it
  #   btusb     -- claims the BT interfaces the part exposes AFTER the firmware
  #                upload; aic_btusb is deliberately not built
  #   bluetooth -- btusb's own stack
  #   hidp      -- classic Bluetooth mice and keyboards; nothing depends on it, so
  #                without this name it is built and never shipped
  #   uhid      -- Bluetooth LE mice and keyboards: bluetoothd creates them
  #                through /dev/uhid
  #   uinput    -- /dev/uinput: bluetoothd's AVRCP plugin creates the input device
  #                for a speaker's media keys through it
  #   rfcomm    -- the serial-port layer under Hands-Free/Headset and SPP
  #   bnep      -- Bluetooth PAN
  # "=m" means built and installed by build-kernel but published by nothing, so
  # the list is resolved by modprobe against the installed tree rather than
  # written out by hand.
  local mtree="${OUT_DIR}/modules"
  [ -d "${mtree}/lib/modules/${kver}" ] \
    || die "no ${mtree}/lib/modules/${kver} -- run build-kernel (its modules_install) first"
  local staged="${mtree}/lib/modules/${kver}/updates/aic8800"
  mkdir -p "${staged}"
  cp "${dst}"/*.ko "${staged}/"
  depmod -b "${mtree}" "${kver}" || die "depmod over the installed tree failed"

  local want rel
  want="$(
    for m in aic8800_fdrv btusb hidp uhid uinput rfcomm bnep; do
      modprobe -d "${mtree}" -S "${kver}" --show-depends "${m}" 2>/dev/null \
        | awk '$1=="insmod" {print $2}'
    done | sort -u
  )"
  [ -n "${want}" ] || die "modprobe resolved no dependencies -- depmod or the module names are wrong"
  # Non-empty is not enough: a module that was never built simply drops out
  # while the others keep the list non-empty. Every requested name has to
  # resolve to its own file.
  for m in aic8800_fdrv btusb hidp uhid uinput rfcomm bnep; do
    printf '%s\n' "${want}" | grep -q "/${m}\.ko" \
      || die "${m}.ko did not resolve in ${mtree} -- its Kconfig symbol is not =m in this build"
  done
  for m in ${want}; do
    case "${m}" in
      */updates/aic8800/*) continue ;;   # ours, already placed
    esac
    rel="${m#"${mtree}"/lib/modules/${kver}/}"
    mkdir -p "${OUT_DIR}/aic8800/lib/modules/${kver}/$(dirname "${rel}")"
    cp "${m}" "${OUT_DIR}/aic8800/lib/modules/${kver}/${rel}"
    log "dep: ${rel}"
  done
  # depmod again, over the pack itself, so `modprobe -d <unpacked>` and a plain
  # `modprobe` after unpacking onto a board both work.
  depmod -b "${OUT_DIR}/aic8800" "${kver}" || die "depmod over the pack failed"

  log "aic8800 modules -> ${dst}"
  ls -l "${dst}" | sed 's/^/        /'
  log "aic8800 firmware -> ${fwd} ($(ls -1 "${fwd}" | wc -l) files)"

  # Ship the tree rooted at usr/, not at lib/. Debian trixie is usr-merged: /lib
  # is a SYMLINK to usr/lib, and `tar -C / -xzf` of an archive whose first entry
  # is the directory `lib/` replaces that symlink with a real directory holding
  # only what the archive carried -- the dynamic loader goes out of reach and the
  # system can no longer exec anything. A pack rooted at usr/ cannot do that.
  # depmod ran before the move because `depmod -b <dir>` looks only at
  # <dir>/lib/modules/<ver>.
  mkdir -p "${OUT_DIR}/aic8800/usr"
  mv "${OUT_DIR}/aic8800/lib" "${OUT_DIR}/aic8800/usr/lib"
  tar -C "${OUT_DIR}/aic8800" --sort=name --mtime="@${SOURCE_DATE_EPOCH}" \
      --owner=0 --group=0 --numeric-owner \
      -czf "${OUT_DIR}/aic8800-${kver}.tar.gz" usr \
    || die "aic8800: packing failed"
  log "packed -> ${OUT_DIR}/aic8800-${kver}.tar.gz ($(du -h "${OUT_DIR}/aic8800-${kver}.tar.gz" | cut -f1))"
}

# Group stage run by the full chain (inner.sh all).
stage_wifi() { stage_fetch_wifi && stage_build_wifi; }
