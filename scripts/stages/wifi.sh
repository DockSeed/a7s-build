# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# WiFi/Bluetooth firmware stages: wifi (= fetch-wifi + build-wifi), fetch-wifi,
# build-wifi. Sourced by scripts/inner.sh.
#
# The AIC8800D80 driver is built with the kernel, by the kernel recipe
# a7s-linux-lts (docs/kernel.md), when A7S_KERNEL=build. This stage provides
# what the driver loads at run time: the seven firmware files of the same
# upstream commit. They are vendor binaries without a licence statement:
# fetched at build time, verified against out-of-tree/aic8800/firmware.sha256
# and never committed.
#
# With A7S_KERNEL=release the kernel packages carry no driver. This stage then
# also packages the driver's source for DKMS (a7s-aic8800-dkms): the upstream
# commit below with the recipe's patches (out-of-tree/aic8800/patches in the
# pinned a7s-linux-lts checkout, so fetch-kernel has to run first). The image
# builds the modules against the installed headers, and a kernel installed
# later with its headers package gets them rebuilt.
#
# Output: OUT_DIR/aic8800/usr/lib/firmware/aic8800D80/ and, for the release
# kernel, OUT_DIR/aic8800/dkms/{a7s-aic8800-dkms_<version>_all.deb,DKMS-ID}.

# shellcheck source=../lib/series.sh
. "${SRC}/scripts/lib/series.sh"

# Pinned to a COMMIT, not the tag; the tag is recorded so a reader can find the
# release. It is the commit the kernel recipe builds the driver from:
# wifi_verify_output compares the two.
AIC8800_URL="https://github.com/radxa-pkg/aic8800.git"
AIC8800_TAG="5.0+git20260123.5f7be68d-8"
AIC8800_COMMIT="df4c783b663eba1956579c681acd5e45f25c671d"
AIC8800_FW_SUBDIR="src/USB/driver_fw/fw/aic8800D80"
# The driver's source in the same commit.
AIC8800_DRIVER_SUBDIR="src/USB/driver_fw/drivers/aic8800"
# The DKMS package and its module name. Its version is the upstream tag plus a
# hash of the recipe's patch series (wifi_dkms_version), so one version never
# stands for two sets of patches.
AIC8800_DKMS_PACKAGE="a7s-aic8800-dkms"
AIC8800_DKMS_MODULE="aic8800"

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
  if [ "$(kernel_source)" = release ]; then wifi_build_dkms_package; fi
}

# sha256 over the series file and the patches in its order (the recipe's
# out-of-tree/aic8800/patches). Needs the recipe checkout.
wifi_series_sha256() {
  local pdir; pdir="$(kernel_dir)/out-of-tree/aic8800/patches"
  series_load "${pdir}" || die "${pdir}/series is missing, empty or malformed"
  ( cd "${pdir}" && sha256sum series "${SERIES[@]}" ) | sha256sum | cut -d' ' -f1
}

wifi_dkms_version() { printf '%s+a7s.%s' "${AIC8800_TAG}" "$(wifi_series_sha256 | cut -c1-12)"; }

# Where the DKMS package lands.
wifi_dkms_deb() {
  printf '%s/aic8800/dkms/%s_%s_all.deb\n' "${OUT_DIR}" "${AIC8800_DKMS_PACKAGE}" "$(wifi_dkms_version)"
}

# The recipe builds the driver from the commit and subdirectory its own
# scripts/lib/aic8800.sh names; the DKMS package must be made from the same.
wifi_check_recipe_pins() {
  local f c t d; f="$(kernel_dir)/scripts/lib/aic8800.sh"
  c="$(sed -n 's/^AIC8800_COMMIT="\(.*\)"$/\1/p' "${f}")"
  t="$(sed -n 's/^AIC8800_TAG="\(.*\)"$/\1/p' "${f}")"
  d="$(sed -n 's/^AIC8800_SUBDIR="\(.*\)"$/\1/p' "${f}")"
  [ "${c}" = "${AIC8800_COMMIT}" ] && [ "${t}" = "${AIC8800_TAG}" ] && [ "${d}" = "${AIC8800_DRIVER_SUBDIR}" ] \
    || die "the recipe builds the driver from '${c}' (${t}, ${d}), wifi.sh pins ${AIC8800_COMMIT} (${AIC8800_TAG}, ${AIC8800_DRIVER_SUBDIR}) -- move the pins together"
}

# The driver's source with the recipe's patches as a Debian package for DKMS:
# /usr/src/aic8800-<version>/ with a dkms.conf, registered with `dkms add` when
# the package is installed and removed with it. The modules are built when a
# kernel's headers are there: dkms' hook in /etc/kernel/header_postinst.d runs
# when a linux-headers package is installed, and the postinst below covers the
# kernels that are installed already.
wifi_build_dkms_package() {
  local dir src pdir w pkg usr doc p v m="${AIC8800_DKMS_MODULE}"
  dir="$(wifi_src_dir)"; src="${dir}/${AIC8800_DRIVER_SUBDIR}"
  [ -d "${src}" ] || die "aic8800 source missing -- run fetch-wifi first"
  [ "$(git -C "${dir}" rev-parse HEAD)" = "${AIC8800_COMMIT}" ] \
    || die "${dir} is not at ${AIC8800_COMMIT} -- run fetch-wifi again"
  command -v dpkg-deb >/dev/null || die "dpkg-deb is missing in the builder"
  kernel_recipe >/dev/null || exit 1   # the checkout is the pinned recipe commit
  wifi_check_recipe_pins
  pdir="$(kernel_dir)/out-of-tree/aic8800/patches"
  series_load "${pdir}" || die "${pdir}/series is missing, empty or malformed"
  v="$(wifi_dkms_version)"

  # The patches name their files from the root of the upstream repository.
  w="${WORK_DIR}/aic8800-dkms"; pkg="${w}/pkg"
  rm -rf "${w}"
  mkdir -p "${w}/tree/${AIC8800_DRIVER_SUBDIR%/*}"
  cp -a "${src}" "${w}/tree/${AIC8800_DRIVER_SUBDIR}"
  ( cd "${w}/tree" || exit 1
    for p in "${SERIES[@]}"; do
      git apply --whitespace=nowarn "${pdir}/${p}" || die "aic8800: ${p} did not apply"
    done ) || exit 1
  log "aic8800: ${#SERIES[@]} patches of the recipe applied to ${AIC8800_COMMIT:0:12}"

  usr="${pkg}/usr/src/${m}-${v}"; doc="${pkg}/usr/share/doc/${AIC8800_DKMS_PACKAGE}"
  mkdir -p "${usr}" "${doc}" "${pkg}/DEBIAN"
  cp -a "${w}/tree/${AIC8800_DRIVER_SUBDIR}/." "${usr}/"
  # Two modules; DKMS installs them below updates/dkms.
  cat > "${usr}/dkms.conf" <<EOF
PACKAGE_NAME="${m}"
PACKAGE_VERSION="${v}"
AUTOINSTALL="yes"
BUILT_MODULE_NAME[0]="aic_load_fw"
BUILT_MODULE_LOCATION[0]="aic_load_fw/"
DEST_MODULE_LOCATION[0]="/updates/dkms"
BUILT_MODULE_NAME[1]="aic8800_fdrv"
BUILT_MODULE_LOCATION[1]="aic8800_fdrv/"
DEST_MODULE_LOCATION[1]="/updates/dkms"
EOF
  {
    echo "The source of the driver for the AIC8800D80 WLAN/BT part, built by DKMS."
    echo
    echo "Source:  ${AIC8800_URL}"
    echo "Tag:     ${AIC8800_TAG}"
    echo "Commit:  ${AIC8800_COMMIT}"
    echo "Subdir:  ${AIC8800_DRIVER_SUBDIR}"
    echo "Patches: ${KERNEL_RECIPE_URL%.git} @ ${KERNEL_RECIPE_COMMIT},"
    echo "         out-of-tree/aic8800/patches/series:"
    printf '           %s\n' "${SERIES[@]}"
    echo
    echo "This package was made by a7s-build. The source files keep their own notices."
  } > "${doc}/README"
  cat > "${pkg}/DEBIAN/control" <<EOF
Package: ${AIC8800_DKMS_PACKAGE}
Version: ${v}
Architecture: all
Maintainer: a7s-build
Section: kernel
Priority: optional
Depends: dkms (>= 3.0), gcc, make
Description: AIC8800D80 WLAN/BT driver source for DKMS
 The driver of the WLAN/BT part of the Radxa Cubie A7S, built against each
 installed kernel that has its headers package. README in
 /usr/share/doc/${AIC8800_DKMS_PACKAGE} says where the source comes from.
EOF
  cat > "${pkg}/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if [ "\$1" = configure ]; then
  [ -d /var/lib/dkms/${m}/${v} ] || dkms add -m ${m} -v ${v}
  # Kernels that were installed before this package: build for each one that
  # has its headers.
  for b in /lib/modules/*/build; do
    [ -d "\$b/include" ] || continue
    k="\${b%/build}"; k="\${k##*/}"
    dkms autoinstall -k "\$k"
  done
fi
exit 0
EOF
  cat > "${pkg}/DEBIAN/prerm" <<EOF
#!/bin/sh
set -e
if [ "\$1" = remove ] || [ "\$1" = upgrade ] || [ "\$1" = deconfigure ]; then
  dkms remove -m ${m} -v ${v} --all || true
fi
exit 0
EOF
  chmod 0755 "${pkg}/DEBIAN/postinst" "${pkg}/DEBIAN/prerm"
  find "${pkg}" -type d -exec chmod 0755 {} +
  find "${pkg}/usr" -type f -exec chmod 0644 {} +
  find "${pkg}" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
  mkdir -p "${OUT_DIR}/aic8800/dkms"
  dpkg-deb --root-owner-group -Zxz --build "${pkg}" "$(wifi_dkms_deb)" >/dev/null \
    || die "building ${AIC8800_DKMS_PACKAGE} failed"
  {
    echo "aic8800=${AIC8800_COMMIT}"
    echo "recipe=${KERNEL_RECIPE_COMMIT}"
    echo "version=${v}"
    echo "patches=${#SERIES[@]}"
    echo "series_sha256=$(wifi_series_sha256)"
    echo "deb_sha256=$(sha256sum "$(wifi_dkms_deb)" | cut -d' ' -f1)"
  } > "${OUT_DIR}/aic8800/dkms/DKMS-ID"
  log "aic8800: $(basename "$(wifi_dkms_deb)") ($(du -h "$(wifi_dkms_deb)" | cut -f1)) -> ${OUT_DIR}/aic8800/dkms"
  rm -rf "${w}"
}

# Used by the image stage: the driver in the image was built from the commit the
# firmware comes from. A7S_KERNEL=build: KERNEL-ID says which commit the driver
# in OUT_DIR/modules was built from. release: the DKMS package was made from it
# (DKMS-ID).
wifi_verify_output() {
  local have
  if [ "$(kernel_source)" = release ]; then
    local id="${OUT_DIR}/aic8800/dkms/DKMS-ID" deb
    have="$(sed -n 's/^aic8800=//p' "${id}" 2>/dev/null)"
    [ "${have}" = "${AIC8800_COMMIT}" ] \
      || die "the aic8800 DKMS package in ${OUT_DIR} was made from '${have}', the firmware pin is ${AIC8800_COMMIT} -- run the wifi stage"
    wifi_check_recipe_pins
    # The package is the one the pins and the recipe's patches give.
    [ "$(sed -n 's/^series_sha256=//p' "${id}")" = "$(wifi_series_sha256)" ] \
      && [ "$(sed -n 's/^version=//p' "${id}")" = "$(wifi_dkms_version)" ] \
      || die "the aic8800 DKMS package in ${OUT_DIR} was not made from the patches of the pinned recipe commit -- run the wifi stage"
    deb="$(wifi_dkms_deb)"
    [ -f "${deb}" ] && [ "$(sed -n 's/^deb_sha256=//p' "${id}")" = "$(sha256sum "${deb}" | cut -d' ' -f1)" ] \
      || die "${deb} is missing or differs from the package the wifi stage made -- run the wifi stage"
    return 0
  fi
  have="$(sed -n 's/^aic8800=//p' "${OUT_DIR}/KERNEL-ID" 2>/dev/null)"
  [ "${have}" = "${AIC8800_COMMIT}" ] \
    || die "the aic8800 driver in ${OUT_DIR} was built from '${have}', the firmware pin is ${AIC8800_COMMIT} -- move the pins together"
}

# Group stage run by the full chain (inner.sh all).
stage_wifi() { stage_fetch_wifi && stage_build_wifi; }
