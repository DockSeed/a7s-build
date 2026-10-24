# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# WiFi/Bluetooth firmware stages: wifi (= fetch-wifi + build-wifi), fetch-wifi,
# build-wifi. Sourced by scripts/inner.sh.
#
# The AIC8800D80 driver is built with the kernel, by the kernel recipe
# a7s-linux-lts (docs/kernel.md). This stage provides what the driver loads at
# run time: the seven firmware files of the same upstream commit. They are
# vendor binaries without a licence statement: fetched at build time, verified
# against out-of-tree/aic8800/firmware.sha256 and never committed.
#
# Output: OUT_DIR/aic8800/usr/lib/firmware/aic8800D80/.

# Pinned to a COMMIT, not the tag; the tag is recorded so a reader can find the
# release. It is the commit the kernel recipe builds the driver from:
# wifi_verify_output compares the two.
AIC8800_URL="https://github.com/radxa-pkg/aic8800.git"
AIC8800_TAG="5.0+git20260123.5f7be68d-8"
AIC8800_COMMIT="df4c783b663eba1956579c681acd5e45f25c671d"
AIC8800_FW_SUBDIR="src/USB/driver_fw/fw/aic8800D80"

wifi_src_dir() { printf '%s\n' "${WORK_DIR}/aic8800-firmware"; }

pins_wifi() {
  log "wifi     : ${AIC8800_URL} @ ${AIC8800_COMMIT} (tag ${AIC8800_TAG})"
  log "           $(grep -cEv '^#' "${SRC}/out-of-tree/aic8800/firmware.sha256") firmware files pinned by sha256"
}

stage_fetch_wifi() {
  mkdir -p "${WORK_DIR}"
  local dir; dir="$(wifi_src_dir)"
  git_fetch_pinned "${AIC8800_URL}" "${AIC8800_COMMIT}" "${dir}"
  # The vendor manifest (src/firmware_version.md) does not list
  # aic_userconfig_8800d80.txt, so it cannot cover the set we use.
  ( cd "${dir}/${AIC8800_FW_SUBDIR}" \
    && grep -v '^#' "${SRC}/out-of-tree/aic8800/firmware.sha256" | sha256sum -c - >/dev/null ) \
    || die "aic8800 firmware does not match out-of-tree/aic8800/firmware.sha256"
  log "firmware: $(grep -cv '^#' "${SRC}/out-of-tree/aic8800/firmware.sha256") files match our pins"
}

# Only the files the driver actually opens. The tag ships fifteen; the rest are
# the RF test mode, calibration, BLE scan filters and other chip variants.
stage_build_wifi() {
  local dir fwd; dir="$(wifi_src_dir)"
  fwd="${OUT_DIR}/aic8800/usr/lib/firmware/aic8800D80"
  [ -d "${dir}/${AIC8800_FW_SUBDIR}" ] || die "aic8800 firmware source missing -- run fetch-wifi first"
  rm -rf "${OUT_DIR}/aic8800"
  mkdir -p "${fwd}"
  ( cd "${dir}/${AIC8800_FW_SUBDIR}" \
    && awk '!/^#/ {print $2}' "${SRC}/out-of-tree/aic8800/firmware.sha256" \
       | xargs -I{} cp {} "${fwd}/" ) || die "aic8800: firmware copy failed"
  log "aic8800 firmware -> ${fwd} ($(find "${fwd}" -type f | wc -l) files)"
}

# Used by the image stage: the driver in OUT_DIR/modules was built from the
# commit the firmware comes from (KERNEL-ID says which).
wifi_verify_output() {
  local have; have="$(sed -n 's/^aic8800=//p' "${OUT_DIR}/KERNEL-ID" 2>/dev/null)"
  [ "${have}" = "${AIC8800_COMMIT}" ] \
    || die "the aic8800 driver in ${OUT_DIR} was built from '${have}', the firmware pin is ${AIC8800_COMMIT} -- move the pins together"
}

# Group stage run by the full chain (inner.sh all).
stage_wifi() { stage_fetch_wifi && stage_build_wifi; }
