# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# WiFi/Bluetooth firmware stages: wifi (= fetch-wifi + build-wifi), fetch-wifi,
# build-wifi. Sourced by scripts/inner.sh.
#
# The AIC8800D80 driver comes from the kernel recipe a7s-linux-lts
# (docs/kernel.md): built with the kernel when A7S_KERNEL=build, and as its
# release file a7s-aic8800-dkms (the driver source for DKMS) when
# A7S_KERNEL=release. This stage provides what the driver loads at run time:
# the seven firmware files of the same upstream commit. They are vendor
# binaries that carry no licence text (the package's debian/copyright lists
# src/* as GPL-2): fetched at build time, verified against
# out-of-tree/aic8800/firmware.sha256 and never committed.
#
# Output: OUT_DIR/aic8800/usr/lib/firmware/aic8800D80/ and, for the release
# kernel, OUT_DIR/aic8800/dkms/{a7s-aic8800-dkms_<version>_all.deb,DKMS-ID}.

# Pinned to a COMMIT, not the tag; the tag is recorded so a reader can find the
# release. It is the commit the kernel recipe builds the driver from:
# wifi_check_recipe_pins compares the two.
AIC8800_URL="https://github.com/radxa-pkg/aic8800.git"
AIC8800_TAG="5.0+git20260123.5f7be68d-11"
AIC8800_COMMIT="b6e136a9fe30a4babf0dde5ba9d02313e1c99c30"
AIC8800_FW_SUBDIR="src/USB/driver_fw/fw/aic8800D80"
# The driver's source in the same commit.
AIC8800_DRIVER_SUBDIR="src/USB/driver_fw/drivers/aic8800"
AIC8800_DKMS_PACKAGE="a7s-aic8800-dkms"

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
  if [ "$(kernel_source)" = release ]; then wifi_fetch_dkms_package; fi
}

# Where the DKMS package lands.
wifi_dkms_deb() { printf '%s/aic8800/dkms/%s\n' "${OUT_DIR}" "${KERNEL_RELEASE_DKMS_DEB}"; }

# The recipe builds the driver from the commit and subdirectory its own
# scripts/lib/aic8800.sh names; the firmware must come from the same.
wifi_check_recipe_pins() {
  local f c t d; f="$(kernel_dir)/scripts/lib/aic8800.sh"
  c="$(sed -n 's/^AIC8800_COMMIT="\(.*\)"$/\1/p' "${f}")"
  t="$(sed -n 's/^AIC8800_TAG="\(.*\)"$/\1/p' "${f}")"
  d="$(sed -n 's/^AIC8800_SUBDIR="\(.*\)"$/\1/p' "${f}")"
  [ "${c}" = "${AIC8800_COMMIT}" ] && [ "${t}" = "${AIC8800_TAG}" ] && [ "${d}" = "${AIC8800_DRIVER_SUBDIR}" ] \
    || die "the recipe builds the driver from '${c}' (${t}, ${d}), wifi.sh pins ${AIC8800_COMMIT} (${AIC8800_TAG}, ${AIC8800_DRIVER_SUBDIR}) -- move the pins together"
}

# The DKMS package of the pinned release (KERNEL_RELEASE_DKMS_* in kernel.sh),
# the pinned bytes, with the version of the release's kernel packages.
wifi_fetch_dkms_package() {
  local deb; deb="$(wifi_dkms_deb)"
  kernel_recipe >/dev/null || exit 1   # the checkout is the pinned recipe commit
  wifi_check_recipe_pins
  [ -n "${KERNEL_RELEASE_DKMS_DEB:-}" ] && [ -n "${KERNEL_RELEASE_DKMS_SHA256:-}" ] \
    || die "release ${KERNEL_RELEASE_TAG} has no pinned ${AIC8800_DKMS_PACKAGE} (KERNEL_RELEASE_DKMS_* in scripts/stages/kernel.sh)"
  mkdir -p "${OUT_DIR}/aic8800/dkms"
  fetch_verified "${KERNEL_RELEASE_DKMS_SHA256}" "${deb}" "${KERNEL_RELEASE_BASE_URL}/${KERNEL_RELEASE_DKMS_DEB}"
  [ "$(dpkg-deb -f "${deb}" Package)" = "${AIC8800_DKMS_PACKAGE}" ] || die "${deb} is not ${AIC8800_DKMS_PACKAGE}"
  [ "$(dpkg-deb -f "${deb}" Version)" = "$(dpkg-deb -f "$(kernel_release_dir)/${KERNEL_RELEASE_IMAGE_DEB}" Version)" ] \
    || die "${deb} does not have the version of the release's kernel packages"
  {
    echo "aic8800=${AIC8800_COMMIT}"
    echo "recipe=${KERNEL_RECIPE_COMMIT}"
    echo "version=$(dpkg-deb -f "${deb}" Version)"
    echo "deb_sha256=${KERNEL_RELEASE_DKMS_SHA256}"
  } > "${OUT_DIR}/aic8800/dkms/DKMS-ID"
  log "aic8800: ${KERNEL_RELEASE_DKMS_DEB} of ${KERNEL_RELEASE_TAG} (sha256 verified)"
}

# Used by the image stage: the driver in the image goes with the firmware's
# commit. A7S_KERNEL=build: KERNEL-ID says which commit the driver in
# OUT_DIR/modules was built from. release: DKMS-ID and the pinned package.
wifi_verify_output() {
  local have
  if [ "$(kernel_source)" = release ]; then
    local id="${OUT_DIR}/aic8800/dkms/DKMS-ID" deb
    have="$(sed -n 's/^aic8800=//p' "${id}" 2>/dev/null)"
    [ "${have}" = "${AIC8800_COMMIT}" ] \
      || die "the aic8800 DKMS package in ${OUT_DIR} goes with '${have}', the firmware pin is ${AIC8800_COMMIT} -- run the wifi stage"
    wifi_check_recipe_pins
    deb="$(wifi_dkms_deb)"
    [ -f "${deb}" ] && [ "$(sed -n 's/^deb_sha256=//p' "${id}")" = "${KERNEL_RELEASE_DKMS_SHA256}" ] \
      && [ "$(sha256sum "${deb}" | cut -d' ' -f1)" = "${KERNEL_RELEASE_DKMS_SHA256}" ] \
      || die "${deb} is missing or is not the pinned package -- run the wifi stage"
    return 0
  fi
  have="$(sed -n 's/^aic8800=//p' "${OUT_DIR}/KERNEL-ID" 2>/dev/null)"
  [ "${have}" = "${AIC8800_COMMIT}" ] \
    || die "the aic8800 driver in ${OUT_DIR} was built from '${have}', the firmware pin is ${AIC8800_COMMIT} -- move the pins together"
}

# Group stage run by the full chain (inner.sh all).
stage_wifi() { stage_fetch_wifi && stage_build_wifi; }
