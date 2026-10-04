# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# The Debian root filesystem: the distro interface for Debian trixie arm64
# (docs/distro-interface.md, docs/image.md). Sourced by scripts/stages/image.sh,
# and by customize-hook, which mmdebstrap runs with the root filesystem's
# path once the packages are in.
#
# The interface this file provides:
#   DISTRO_NAME, DISTRO_RELEASE   the image file name takes them
#   distro_rootfs_inputs          prints what the root filesystem is made from
#   distro_rootfs_build <dir>     builds the root filesystem into <dir>
#   distro_rootfs_assert <dir>    fails when the root filesystem breaks a rule
#
# Rootless: the build runs as uid 0 in a user namespace with no real root, no
# mknod and no loop devices; foreign-architecture code runs through a
# binfmt_misc handler registered inside the container. mmdebstrap in root mode
# handles that: without mknod it bind-mounts the device nodes it needs.

DISTRO_NAME="debian"
DEBIAN_DIR="${SRC}/scripts/distro/debian"
# shellcheck source=packages.sh
. "${DEBIAN_DIR}/packages.sh"
DISTRO_RELEASE="${DEBIAN_SUITE}"

# Where the build fetches from: DEBIAN_MIRROR and DEBIAN_SECURITY_MIRROR
# (scripts/lib/common.sh), i.e. snapshot.debian.org at A7S_SNAPSHOT, the same
# timestamp the builder container is pinned to, or the live archive when
# A7S_SNAPSHOT is empty. apt checks the archive's signature on every Release
# file against the Debian archive keyring of the builder; for a snapshot,
# check-valid-until=no only accepts an expired Valid-Until, which every
# snapshot of -security and -backports has after a week.
DEBIAN_KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
# Where the finished image fetches from: Debian's own archives, so `apt update
# && apt upgrade` on the board brings normal Debian updates, security included.
DEBIAN_MIRROR_FINAL="https://deb.debian.org/debian"
DEBIAN_SECURITY_FINAL="https://security.debian.org/debian-security"

# The image's account and identity (config/defaults.conf may set them).
A7S_USER="${A7S_USER:-a7s}"
A7S_USER_UID="${A7S_USER_UID:-1000}"
A7S_HOSTNAME="${A7S_HOSTNAME:-a7s}"
# minbase has no `render` group; systemd's sysusers would create it on the
# first boot with whatever gid is free then. A fixed gid keeps the image
# reproducible.
A7S_RENDER_GID="${A7S_RENDER_GID:-991}"

# The patched userspace inputs, produced by other stages in OUT_DIR.
DEBIAN_ORC_DIR="${OUT_DIR}/orc"
DEBIAN_ORC_SONAME="liborc-0.4.so.0"
DEBIAN_XFWM4_DIR="${OUT_DIR}/xfwm4"
DEBIAN_XFWM4_APT_PIN="etc/apt/preferences.d/xfwm4-a7s"
DEBIAN_XFWM4_DOC_DIR="usr/local/share/doc/xfwm4-a7s"

# --- small helpers --------------------------------------------------------------

debian_switch() {  # <name> -- 0 or 1, anything else fails
  local v="${!1:-0}"
  case "${v}" in
    0|1) printf '%s' "${v}" ;;
    *) die "${1} must be 0 or 1, not '${v}'" ;;
  esac
}

# Run a program of the root filesystem. Foreign binaries run through the
# container's binfmt_misc handler.
in_root() {  # <root> <command> [<argument>...]
  local r="$1"; shift
  LC_ALL=C DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true chroot "${r}" "$@"
}

# Does <path> exist inside <root>, resolved the way the booted system resolves
# it? Enable links are absolute; a plain test on the host would follow them
# into the builder's /usr.
in_rootfs() { chroot "$1" /usr/bin/test -e "$2"; }

pkg_status() {  # <root> <package>
  in_root "$1" dpkg-query -W -f='${db:Status-Status}' "$2" 2>/dev/null || true
}
assert_installed() {  # <root> <why> <package>...
  local r="$1" why="$2" p st; shift 2
  for p in "$@"; do
    st="$(pkg_status "${r}" "${p}")"
    [ "${st}" = installed ] || die "${p} is not installed (status '${st}') -- ${why}"
  done
}
assert_not_installed() {  # <root> <why> <package>...
  local r="$1" why="$2" p st; shift 2
  for p in "$@"; do
    st="$(pkg_status "${r}" "${p}")"
    case "${st}" in
      ""|not-installed|config-files) ;;
      *) die "${p} is installed (status '${st}') -- ${why}" ;;
    esac
  done
}

debian_apt_install() {  # <root> [--with-recommends] <package>...
  local r="$1" rec=--no-install-recommends; shift
  if [ "${1:-}" = "--with-recommends" ]; then rec=--install-recommends; shift; fi
  in_root "${r}" apt-get -y -q "${rec}" install "$@"
}

# --- inputs ---------------------------------------------------------------------

# Everything the root filesystem is made from, one `key=value` per line. The
# rootfs stage reuses a finished root filesystem only when this is unchanged.
distro_rootfs_inputs() {
  local f
  printf 'distro=%s\nsuite=%s\narch=%s\nsnapshot=%s\nmirror=%s\nsecurity_mirror=%s\n' \
    "${DISTRO_NAME}" "${DEBIAN_SUITE}" "${DEBIAN_ARCH}" "${A7S_SNAPSHOT:-}" "${DEBIAN_MIRROR}" "${DEBIAN_SECURITY_MIRROR}"
  printf 'user=%s\nuid=%s\nhostname=%s\nrender_gid=%s\n' \
    "${A7S_USER}" "${A7S_USER_UID}" "${A7S_HOSTNAME}" "${A7S_RENDER_GID}"
  printf 'desktop=%s\n' "$(debian_switch A7S_DESKTOP)"
  printf 'source_date_epoch=%s\n' "${SOURCE_DATE_EPOCH}"
  # The recipe itself: every file of this distro directory, by content.
  (cd "${DEBIAN_DIR}" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) \
    | sed 's/^/recipe /'
  # The OUT_DIR inputs this configuration takes, by content.
  for f in $(debian_out_inputs); do
    printf 'input %s %s\n' "$(sha256sum "${f}" | cut -d' ' -f1)" "${f#"${OUT_DIR}"/}"
  done
}

# The OUT_DIR files this configuration installs, sorted. Missing ones are
# reported by distro_rootfs_build, not here.
debian_out_inputs() {
  local -a dirs=()
  if [ "$(debian_switch A7S_DESKTOP)" = 1 ]; then dirs+=("${DEBIAN_XFWM4_DIR}" "${DEBIAN_ORC_DIR}"); fi
  [ "${#dirs[@]}" -gt 0 ] || return 0
  find "${dirs[@]}" -type f 2>/dev/null | LC_ALL=C sort
}

# --- the build ----------------------------------------------------------------

distro_rootfs_build() {  # <dir>
  local r="$1"
  [ "$(id -u)" = 0 ] || die "the rootfs stage runs as uid 0 (in the container's user namespace)"
  [ "${A7S_SUITE:-${DEBIAN_SUITE}}" = "${DEBIAN_SUITE}" ] \
    || die "A7S_SUITE=${A7S_SUITE}: scripts/distro/debian is written for ${DEBIAN_SUITE} only (backports pins, version marks)"
  [ -n "${DEBIAN_MIRROR:-}" ] && [ -n "${DEBIAN_SECURITY_MIRROR:-}" ] \
    || die "DEBIAN_MIRROR / DEBIAN_SECURITY_MIRROR are not set (scripts/lib/common.sh)"
  if [ -z "${A7S_SNAPSHOT:-}" ]; then
    warn "A7S_SNAPSHOT is empty: the root filesystem comes from the live archive and is not reproducible"
  fi
  [ -n "${SOURCE_DATE_EPOCH:-}" ] || die "SOURCE_DATE_EPOCH is not set"
  command -v mmdebstrap >/dev/null || die "mmdebstrap missing in the builder (container/packages.d/image.txt)"
  [ -f "${DEBIAN_KEYRING}" ] || die "no ${DEBIAN_KEYRING} in the builder -- the archive signatures could not be checked"
  # The builder must run arm64 code: the binfmt_misc handler the container
  # registers in its own user namespace (never the host's).
  if [ "$(uname -m)" != aarch64 ]; then
    arch-test "${DEBIAN_ARCH}" >/dev/null 2>&1 \
      || die "this builder cannot run ${DEBIAN_ARCH} code (arch-test ${DEBIAN_ARCH} failed) -- the qemu-aarch64 binfmt_misc handler is not registered in the container"
  fi
  debian_check_out_inputs

  local opt="[signed-by=${DEBIAN_KEYRING}]"
  if [ -n "${A7S_SNAPSHOT:-}" ]; then opt="[signed-by=${DEBIAN_KEYRING} check-valid-until=no]"; fi
  local -a sources=(
    "deb ${opt} ${DEBIAN_MIRROR} ${DEBIAN_SUITE} main"
    "deb ${opt} ${DEBIAN_MIRROR} ${DEBIAN_SUITE}-updates main"
    "deb ${opt} ${DEBIAN_SECURITY_MIRROR} ${DEBIAN_SUITE}-security main"
    "deb ${opt} ${DEBIAN_MIRROR} ${DEBIAN_SUITE}-backports main"
  )
  local s
  for s in "${sources[@]}"; do
    case "${s}" in *trusted=yes*|*allow-insecure*|*allow-weak*) die "an apt source without signature check: ${s}" ;; esac
  done

  # Downloaded packages are kept in CACHE_DIR between builds; apt checks each
  # against the signed index of the snapshot before it is used.
  local debs="${CACHE_DIR}/debian-${DEBIAN_SUITE}-${DEBIAN_ARCH}-debs"
  mkdir -p "${debs}"
  local include
  include="$(IFS=,; echo "${DEBIAN_BASE_PACKAGES[*]},${STANDARD_IMAGE_PACKAGES[*]},${MESA_IMAGE_PACKAGES[*]}")"

  rm -rf "${r}"
  # Environment the customize hook reads (it is a separate process).
  export SRC WORK_DIR OUT_DIR CACHE_DIR SOURCE_DATE_EPOCH A7S_SNAPSHOT
  export A7S_USER A7S_USER_UID A7S_HOSTNAME A7S_RENDER_GID
  A7S_DESKTOP="$(debian_switch A7S_DESKTOP)"
  export A7S_DESKTOP

  log "mmdebstrap ${DEBIAN_SUITE}/${DEBIAN_ARCH} minbase from ${DEBIAN_MIRROR} -> ${r}"
  # --mode=root: uid 0 of the container's user namespace; mmdebstrap finds it
  #   has no mknod and bind-mounts /dev's nodes instead.
  # --setup-hook: the backports pins must exist before apt resolves --include.
  # --customize-hook: everything after the packages (customize-hook), then the
  #   downloaded .debs back into the cache.
  TMPDIR="${WORK_DIR}" mmdebstrap \
      --mode=root --variant=minbase --architectures="${DEBIAN_ARCH}" \
      --format=directory \
      --aptopt='Acquire::Retries "5"' \
      --aptopt='APT::Install-Recommends "false"' \
      --include="${include}" \
      --skip=download/empty --skip=essential/unlink \
      --setup-hook='mkdir -p "$1"/var/cache/apt/archives/' \
      --setup-hook="sync-in ${debs} /var/cache/apt/archives/" \
      --setup-hook="${DEBIAN_DIR}/setup-hook" \
      --customize-hook="${DEBIAN_DIR}/customize-hook" \
      --customize-hook="sync-out /var/cache/apt/archives ${debs}" \
      --customize-hook='rm -f "$1"/var/cache/apt/archives/*.deb' \
      "${DEBIAN_SUITE}" "${r}" "${sources[@]}" \
    || die "mmdebstrap failed"
  # mmdebstrap's own cleanup removed the package lists, the apt caches and its
  # build-time files; what the image must not carry beyond that is asserted.
  [ -x "${r}/sbin/init" ] || [ -L "${r}/sbin/init" ] || die "the rootfs has no /sbin/init"
  # mmdebstrap's cleanup leaves /etc/machine-id empty (systemd then makes the
  # ID on the first boot and commits it; an empty file is not a "first boot",
  # so no preset pass runs); read-only as Debian's installer leaves it.
  [ -f "${r}/etc/machine-id" ] && [ ! -s "${r}/etc/machine-id" ] || die "/etc/machine-id is missing or not empty after mmdebstrap"
  chmod 0444 "${r}/etc/machine-id"
  log "rootfs ready: $(du -sh "${r}" | cut -f1)"
}

# Every OUT_DIR input the switches ask for must be there before an hour of
# package installs, not after.
debian_check_out_inputs() {
  if [ "$(debian_switch A7S_DESKTOP)" = 1 ]; then
    compgen -G "${DEBIAN_XFWM4_DIR}/xfwm4_*_arm64.deb" >/dev/null && [ -f "${DEBIAN_XFWM4_DIR}/XFWM4-ID" ] \
      || die "A7S_DESKTOP=1 needs the patched xfwm4 in ${DEBIAN_XFWM4_DIR} (the build-xfwm4 stage)"
    [ -f "${DEBIAN_ORC_DIR}/ORC-ID" ] && compgen -G "${DEBIAN_ORC_DIR}/${DEBIAN_ORC_SONAME}.*" >/dev/null \
      || die "A7S_DESKTOP=1 needs the patched liborc in ${DEBIAN_ORC_DIR} (the build-orc stage)"
  fi
  return 0
}

# --- setup hook: before apt resolves anything --------------------------------

debian_setup() {  # <root>
  local r="$1"
  install -d -m0755 "${r}/etc/apt/preferences.d"
  cat > "${r}/etc/apt/preferences.d/kmscon-backports" <<EOF
# kmscon (>= ${KMSCON_MIN_VERSION}) and the libtsm4 it needs are backports-only.
# Every other package keeps the archive default: backports at priority 100
# loses to the release's 500, and the image is built with no package from
# backports beyond these two and Mesa.
Package: kmscon libtsm4
Pin: release n=${DEBIAN_SUITE}-backports
Pin-Priority: 990
EOF
  cat > "${r}/etc/apt/preferences.d/mesa-backports" <<EOF
# Mesa comes from ${DEBIAN_SUITE}-backports: ${DEBIAN_SUITE}'s own Mesa has no
# PowerVR Vulkan driver. "Package: src:mesa" matches every binary package built
# from the mesa source, so they move together and never split across two
# archives (apt_preferences(5)). 990: above the release's 500, below 1000, so
# apt never downgrades for it.
Package: src:mesa
Pin: release n=${DEBIAN_SUITE}-backports
Pin-Priority: 990
EOF
  chmod 0644 "${r}"/etc/apt/preferences.d/*-backports
}

# --- customize hook: after the packages, with /proc, /sys and /dev set up -----

debian_customize() {  # <root>
  local r="$1"
  [ -d "${r}/etc" ] || die "customize: ${r} is not a root filesystem"
  # Without a recorded reason a package's postinst would ask; the hooks run
  # noninteractive and every answer the image needs is seeded below.
  log "customize: packages of the base are in ($(in_root "${r}" dpkg-query -W -f='${db:Status-Status}\n' | grep -cx installed) installed)"

  debian_regulatory_db "${r}"
  debian_assert_kmscon "${r}"
  debian_assert_mesa "${r}"

  if [ "${A7S_DESKTOP}" = 1 ]; then debian_desktop "${r}"; debian_orc "${r}"; fi
  assert_backports_allow_list "${r}"
  assert_no_pending_upgrades "${r}"

  # Debian's enable links as the packages left them: the image's own changes
  # are measured against this.
  debian_unit_links "${r}" > "${WORK_DIR}/rootfs-unit-links.debian"

  debian_accounts "${r}"
  debian_system "${r}"
  if [ "${A7S_DESKTOP}" = 1 ]; then debian_desktop_config "${r}"; fi
  debian_apt_sources_final "${r}"
  debian_check_unit_links "${r}" "${WORK_DIR}/rootfs-unit-links.debian"
  debian_dpkg_verify "${r}"
  debian_cleanup "${r}"
}

# wireless-regdb ships a Debian-signed and an upstream-signed copy; the kernel
# trusts the upstream certificates only (CFG80211_USE_KERNEL_REGDB_KEYS), so the
# Debian copy is rejected at every boot. update-alternatives records the choice
# as manual: an upgrade of wireless-regdb keeps it.
debian_regulatory_db() {  # <root>
  in_root "$1" update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream >/dev/null \
    || die "could not select the upstream regulatory.db"
}

debian_assert_kmscon() {  # <root>
  local r="$1" v unit="$1/usr/lib/systemd/system/kmsconvt@.service"
  v="$(in_root "${r}" dpkg-query -W -f='${Version}' kmscon)" || die "kmscon is not installed"
  in_root "${r}" dpkg --compare-versions "${v}" ge "${KMSCON_MIN_VERSION}" \
    || die "kmscon ${v} is older than ${KMSCON_MIN_VERSION} -- the backports pin did not take, or the snapshot predates it"
  [ -x "${r}/usr/bin/kmscon" ] || die "kmscon reports installed but /usr/bin/kmscon is missing"
  [ -f "${unit}" ] || die "kmscon shipped no kmsconvt@.service"
  grep -q -- '--no-switchvt' "${unit}" || die "kmsconvt@.service no longer passes --no-switchvt"
  grep -qx 'Conflicts=getty@%i.service' "${unit}" || die "kmsconvt@.service lost Conflicts=getty@%i.service"
  grep -qx 'OnFailure=getty@%i.service' "${unit}" \
    || die "kmsconvt@.service lost OnFailure=getty@%i.service -- a kmscon that cannot start would leave tty1 dead"
  [ -x "${r}/usr/sbin/agetty" ] || die "no agetty -- kmsconvt@.service runs it for the login"
  log "kmscon ${v} from ${DEBIAN_SUITE}-backports"
}

# The image carries ONE Mesa, Debian's, from backports: every package built
# from the mesa source is a backports build, the PowerVR Vulkan driver and its
# ICD manifest are there, and there is exactly one libgallium.
debian_assert_mesa() {  # <root>
  local r="$1" bad ver g n v mlib="$1/usr/lib/aarch64-linux-gnu" ldcache lres lcanon wcanon dv
  bad="$(in_root "${r}" dpkg-query -W -f='${Package}\t${Version}\t${source:Package}\n' \
           | awk -F'\t' -v m="${MESA_BPO_MARK}" '$3 == "mesa" && index($2, m) == 0 {print $1 " " $2}')"
  [ -z "${bad}" ] || die "Mesa packages not from ${DEBIAN_SUITE}-backports: $(tr '\n' ';' <<<"${bad}")"
  assert_installed "${r}" "the image's Mesa is incomplete" "${MESA_IMAGE_PACKAGES[@]}"
  ver="$(in_root "${r}" dpkg-query -W -f='${Version}' mesa-vulkan-drivers)"
  [ -e "${r}/${MESA_POWERVR_VK_LIB}" ] || die "mesa-vulkan-drivers ${ver} has no /${MESA_POWERVR_VK_LIB}"
  compgen -G "${r}/usr/share/vulkan/icd.d/powervr_mesa_icd*.json" >/dev/null \
    || die "mesa-vulkan-drivers ${ver} has no PowerVR ICD manifest"
  g="$(find "${r}" -xdev -name 'libgallium*' \( -type f -o -type l \) 2>/dev/null)" || true
  n="$(grep -c . <<<"${g}" || true)"
  [ "${n}" = 1 ] || die "${n} libgallium files in the rootfs, expected exactly one: ${g//$'\n'/ }"
  for v in libEGL_mesa.so.0 libGLX_mesa.so.0 libgbm.so.1; do
    [ -e "${mlib}/${v}" ] || die "no ${v} in /usr/lib/aarch64-linux-gnu"
  done
  grep -aq 'EGL_EXT_platform_wayland' "${mlib}/libEGL_mesa.so.0" || die "Mesa has no Wayland EGL platform"
  grep -aq 'EGL_KHR_platform_x11' "${mlib}/libEGL_mesa.so.0" || die "Mesa has no X11 EGL platform"
  ldcache="$(in_root "${r}" ldconfig -p)" || die "ldconfig -p failed in the rootfs"
  for v in libEGL_mesa.so.0 libGLX_mesa.so.0 libgbm.so.1; do
    lres="$(awk -v s="${v}" '$1==s {print $NF; exit}' <<<"${ldcache}")"
    lcanon="$(in_root "${r}" readlink -f "${lres:-/nonexistent}")" || lcanon="(unresolvable)"
    wcanon="$(in_root "${r}" readlink -f "/usr/lib/aarch64-linux-gnu/${v}")" || wcanon="(unresolvable)"
    [ -n "${lres}" ] && [ "${lcanon}" = "${wcanon}" ] \
      || die "ld.so resolves ${v} to '${lres:-nothing}', not the Mesa package's"
  done
  dv="$(in_root "${r}" dpkg -V "${MESA_IMAGE_PACKAGES[@]}" 2>&1)" || die "dpkg -V failed: ${dv}"
  [ -z "${dv}" ] || die "dpkg -V reports changed files in the Mesa packages: ${dv}"
  in_root "${r}" apt-get check >/dev/null 2>&1 || die "apt-get check reports a broken dependency state"
  log "Mesa ${ver} from ${DEBIAN_SUITE}-backports, $(basename "${MESA_POWERVR_VK_LIB}") present, one libgallium"
}

# Nothing comes from backports but what the pins admit.
assert_backports_allow_list() {  # <root>
  local bad
  bad="$(in_root "$1" dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\t${source:Package}\n' \
           | awk -F'\t' -v m="${MESA_BPO_MARK}" -v pk=" ${BACKPORTS_ALLOWED_PACKAGES[*]} " -v src=" ${BACKPORTS_ALLOWED_SOURCES[*]} " \
               '$1 == "installed" && index($3, m) && !index(pk, " " $2 " ") && !index(src, " " $4 " ") {print $2 " " $3 " (source " $4 ")"}')"
  [ -z "${bad}" ] \
    || die "packages from ${DEBIAN_SUITE}-backports that no pin admits (allowed: ${BACKPORTS_ALLOWED_PACKAGES[*]}, source ${BACKPORTS_ALLOWED_SOURCES[*]}): $(tr '\n' ';' <<<"${bad}")"
}

# Nothing is older than apt's candidate at the snapshot: -updates and -security
# were in the sources from the first package on.
assert_no_pending_upgrades() {  # <root>
  local sim line n k
  sim="$(in_root "$1" apt-get -s upgrade 2>&1)" || die "apt-get -s upgrade failed: ${sim}"
  line="$(grep -E '^[0-9]+ upgraded, [0-9]+ newly installed, [0-9]+ to remove and [0-9]+ not upgraded\.$' <<<"${sim}")" \
    || die "apt-get -s upgrade printed no summary line: ${sim}"
  read -r n _ _ _ _ _ _ _ _ k _ <<<"${line}"
  [ "${n}" = 0 ] && [ "${k}" = 0 ] || die "the rootfs is not current at the snapshot: ${line}"
}

# Everything that starts a unit or a program without being asked: symlinks under
# etc/systemd/{system,user}, the packages' static wants/requires/upholds, and
# the XDG autostart entries. Not modelled: SysV links, cron, udev
# ENV{SYSTEMD_WANTS}, /usr/share/gnome/autostart, Wants= in drop-ins.
activation_points() {  # <root>
  local d dirs=()
  for d in etc/systemd/system etc/systemd/user usr/lib/systemd/system usr/lib/systemd/user etc/xdg/autostart; do
    if [ -d "$1/${d}" ]; then dirs+=("${d}"); fi
  done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  (cd "$1" && find "${dirs[@]}" \( \( -path 'etc/systemd/*' -type l \) \
                                    -o \( -path 'usr/lib/systemd/*' \( -path '*.wants/*' -o -path '*.requires/*' -o -path '*.upholds/*' \) \) \
                                    -o -path 'etc/xdg/autostart/*.desktop' \) -print) | LC_ALL=C sort
}
assert_activation_added_only() {  # <root> <before> <why> <allowed point>...
  local r="$1" before="$2" why="$3" now added removed allowed p bad=""; shift 3
  now="$(activation_points "${r}")"
  allowed="$(printf '%s\n' "$@")"
  added="$(LC_ALL=C comm -13 <(printf '%s\n' "${before}") <(printf '%s\n' "${now}"))"
  removed="$(LC_ALL=C comm -23 <(printf '%s\n' "${before}") <(printf '%s\n' "${now}"))"
  [ -z "${removed}" ] || die "${why}: the step removed activation points: $(tr '\n' ';' <<<"${removed}")"
  while IFS= read -r p; do
    [ -n "${p}" ] || continue
    grep -qxF -- "${p}" <<<"${allowed}" || bad+="${p};"
  done <<<"${added}"
  [ -z "${bad}" ] || die "${why}: it made something start that its allow-list does not name: ${bad}"
}

# The enable links under etc/systemd, `<link> <unit>` per line, sorted.
debian_unit_links() {  # <root>
  local dirs=() d
  for d in system user; do [ -d "$1/etc/systemd/${d}" ] && dirs+=("${d}"); done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  (cd "$1/etc/systemd" && find "${dirs[@]}" -type l -printf '%p %l\n') \
    | while read -r link target; do
        [ "${target}" = /dev/null ] || target="${target##*/}"
        echo "${link} ${target}"
      done | LC_ALL=C sort
}
# The image changes Debian's enable links only as DEBIAN_OWN_LINKS says.
debian_check_unit_links() {  # <root> <file with Debian's links>
  local r="$1" deb img line bad="" own
  deb="$(cat "$2")"; img="$(debian_unit_links "${r}")"
  [ -n "${deb}" ] || die "no enable links recorded before the image's changes"
  own="$(printf '%s\n' "${DEBIAN_OWN_LINKS[@]}")"
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    grep -qxF -- "${line}" <<<"${own}" || bad+="  ${line}"$'\n'
  done < <(LC_ALL=C comm -13 <(echo "${deb}") <(echo "${img}") | sed 's/^/+ /'
           LC_ALL=C comm -23 <(echo "${deb}") <(echo "${img}") | sed 's/^/- /')
  [ -z "${bad}" ] || die "enable links that are neither Debian's nor the image's own (DEBIAN_OWN_LINKS):"$'\n'"${bad}"
  log "enable links: Debian's, plus the image's own"
}

# --- A7S_DESKTOP=1 --------------------------------------------------------------

debian_desktop() {  # <root>
  local r="$1" act_before lightdm_home u
  log "desktop: Debian's task-desktop + task-xfce-desktop, with Recommends"
  printf '%s\n' \
    'lightdm shared/default-x-display-manager select lightdm' \
    "exim4-config exim4/mailname string ${A7S_HOSTNAME}" \
    "locales locales/locales_to_be_generated multiselect ${DESKTOP_LOCALES}" \
    "locales locales/default_environment_locale select ${DESKTOP_LANG}" \
    "keyboard-configuration keyboard-configuration/xkb-keymap select ${DESKTOP_XKB_LAYOUT}" \
    "keyboard-configuration keyboard-configuration/layoutcode string ${DESKTOP_XKB_LAYOUT}" \
    "keyboard-configuration keyboard-configuration/modelcode string pc105" \
    | in_root "${r}" debconf-set-selections || die "could not seed debconf for the desktop"
  debian_apt_install "${r}" --with-recommends task-desktop task-xfce-desktop \
      "${DESKTOP_TASK_ALSO[@]}" "${DESKTOP_TASK_WITHOUT[@]/%/-}" \
    || die "installing Debian's desktop task failed"
  act_before="$(activation_points "${r}")"
  debian_apt_install "${r}" --with-recommends "${DESKTOP_ADDITIONS[@]}" \
    || die "installing the desktop additions failed"
  assert_activation_added_only "${r}" "${act_before}" "the desktop additions" "${DESKTOP_ADDITIONS_MAY_ACTIVATE[@]}"
  debian_apt_install "${r}" "${DESKTOP_BLUETOOTH[@]}" || die "installing Bluetooth audio failed"

  # The greeter runs as user lightdm; with a pulseaudio of its own it would hold
  # the audio device across the login. Masked for that user only.
  lightdm_home="$(in_root "${r}" getent passwd lightdm | cut -d: -f6)"
  [ -n "${lightdm_home}" ] || die "no lightdm user in the rootfs"
  in_root "${r}" install -d -o lightdm -g lightdm -m 0700 \
    "${lightdm_home}/.config" "${lightdm_home}/.config/systemd" \
    "${lightdm_home}/.config/systemd/user" "${lightdm_home}/.config/pulse"
  for u in pulseaudio.socket pulseaudio.service; do
    ln -sfn /dev/null "${r}${lightdm_home}/.config/systemd/user/${u}"
    in_root "${r}" chown -h lightdm:lightdm "${lightdm_home}/.config/systemd/user/${u}"
  done
  printf 'autospawn = no\n' > "${r}${lightdm_home}/.config/pulse/client.conf"
  in_root "${r}" chown lightdm:lightdm "${lightdm_home}/.config/pulse/client.conf"
  chmod 0600 "${r}${lightdm_home}/.config/pulse/client.conf"

  debian_xfwm4 "${r}"

  assert_installed "${r}" "the desktop task did not take" \
    task-desktop task-xfce-desktop lightdm xfce4 xserver-xorg-core x11-xserver-utils "${DESKTOP_BLUETOOTH[@]}"
  assert_installed "${r}" "named in the desktop task's call" "${DESKTOP_TASK_ALSO[@]}"
  assert_not_installed "${r}" "left out of the desktop task on purpose" "${DESKTOP_TASK_WITHOUT[@]}" libreoffice-core
  assert_installed "${r}" "a desktop addition" "${DESKTOP_ADDITIONS[@]}"
  assert_not_installed "${r}" "a listening server beside gvfs's clients" "${DESKTOP_NEVER[@]}"
  assert_not_installed "${r}" "a second polkit agent from backports" hyprpolkitagent
  in_rootfs "${r}" /etc/systemd/system/multi-user.target.wants/earlyoom.service \
    || die "earlyoom is installed but not enabled"
  local loc_have loc_want
  loc_have="$(in_root "${r}" locale -a)"
  while IFS= read -r loc_want; do
    loc_want="${loc_want%% *}"; loc_want="${loc_want%.UTF-8}.utf8"
    grep -qxF -- "${loc_want}" <<<"${loc_have}" || die "locale ${loc_want} was not generated"
  done < <(sed 's/, /\n/g' <<<"${DESKTOP_LOCALES}")
  [ -x "${r}/usr/bin/xrandr" ] && [ -x "${r}/usr/bin/loginctl" ] \
    || die "no xrandr or loginctl -- a7s-greeter-outputs could not work"
}

# Our xfwm4 (Debian's source + userspace/xfwm4/patches), installed over
# Debian's build of the same source version and pinned, so apt keeps it until
# Debian publishes a newer xfwm4.
debian_xfwm4() {  # <root>
  local r="$1" deb base xfst xfpol p
  deb="$(compgen -G "${DEBIAN_XFWM4_DIR}/xfwm4_*_arm64.deb" | head -1)"
  [ -n "${deb}" ] || die "no xfwm4 .deb in ${DEBIAN_XFWM4_DIR}"
  [ "$(sed -n 's/^deb_sha256=//p' "${DEBIAN_XFWM4_DIR}/XFWM4-ID")" = "$(sha256sum "${deb}" | cut -d' ' -f1)" ] \
    || die "${DEBIAN_XFWM4_DIR}/XFWM4-ID does not describe ${deb##*/}"
  local ver; ver="$(dpkg-deb -f "${deb}" Version)"
  base="${ver%+a7s*}"
  [ "${base}" != "${ver}" ] || die "${deb##*/}: version ${ver} carries no +a7s suffix"
  xfst="$(in_root "${r}" dpkg-query -W -f='${db:Status-Status} ${Version}' xfwm4 2>/dev/null || true)"
  [ "${xfst}" = "installed ${base}" ] \
    || die "Debian's xfwm4 in the rootfs is '${xfst}', ours is built from ${base} -- rebuild xfwm4 against the snapshot's version"
  install -d -m0755 "${r}/tmp/a7s-xfwm4"
  install -m0644 "${deb}" "${r}/tmp/a7s-xfwm4/"
  debian_apt_install "${r}" "/tmp/a7s-xfwm4/${deb##*/}" || die "installing our xfwm4 ${ver} failed"
  rm -rf "${r:?}/tmp/a7s-xfwm4"
  cat > "${r}/${DEBIAN_XFWM4_APT_PIN}" <<EOF
# a7s-build: xfwm4 ${ver} is Debian's ${base} with userspace/xfwm4/patches
# (the compositor no longer starts without vsync on a user's first login).
# The pin keeps apt from replacing it with Debian's build of the same version;
# a newer Debian version (a security update) still wins.
Package: xfwm4
Pin: version ${ver}
Pin-Priority: 990
EOF
  chmod 0644 "${r}/${DEBIAN_XFWM4_APT_PIN}"
  install -d -m0755 "${r}/${DEBIAN_XFWM4_DOC_DIR}/patches"
  install -m0644 "${DEBIAN_XFWM4_DIR}/XFWM4-ID" "${r}/${DEBIAN_XFWM4_DOC_DIR}/"
  for p in "${SRC}"/userspace/xfwm4/patches/*.patch; do
    [ -f "${p}" ] && install -m0644 "${p}" "${r}/${DEBIAN_XFWM4_DOC_DIR}/patches/"
  done
  xfpol="$(in_root "${r}" apt-cache policy xfwm4)"
  grep -Fxq "  Candidate: ${ver}" <<<"${xfpol}" || die "apt's candidate for xfwm4 is not ${ver}: ${xfpol//$'\n'/ | }"
  xfst="$(in_root "${r}" dpkg -V xfwm4 2>&1)" || die "dpkg -V xfwm4 failed: ${xfst}"
  [ -z "${xfst}" ] || die "dpkg -V reports changed files of xfwm4: ${xfst}"
  log "xfwm4 ${ver} installed over Debian's ${base} and pinned"
}

# The desktop's configuration: greeter outputs, greeter language menu, the
# Xfce look, LightDM as display manager, graphical.target.
debian_desktop_config() {  # <root>
  local r="$1" dm_link lookd="$1/${DESKTOP_LOOK_DIR}" pkg_panel="$1/etc/xdg/xfce4/panel/default.xml"
  local menu_line='<property name="plugin-1" type="string" value="applicationsmenu"/>' panel_diff
  [ -x "${r}/usr/sbin/lightdm-gtk-greeter" ] && [ -d "${r}/usr/share/lightdm/lightdm-gtk-greeter.conf.d" ] \
    || die "no lightdm-gtk-greeter in the rootfs"
  cp -a --no-preserve=ownership "${DEBIAN_DIR}/files/desktop/." "${r}/"
  dm_link="$(readlink "${r}/etc/systemd/system/display-manager.service" || true)"
  case "${dm_link}" in
    /usr/lib/systemd/system/lightdm.service|/lib/systemd/system/lightdm.service) ;;
    *) die "display-manager.service points at '${dm_link}', not lightdm.service" ;;
  esac
  [ "$(cat "${r}/etc/X11/default-display-manager" 2>/dev/null)" = /usr/sbin/lightdm ] \
    || die "/etc/X11/default-display-manager does not name /usr/sbin/lightdm"
  # No autologin: the account has no password until its first login sets one.
  if grep -rqsE '^[[:space:]]*autologin-user[[:space:]]*=' "${r}/etc/lightdm" "${r}/usr/share/lightdm"; then
    die "LightDM is configured to log in automatically -- the account would never get a password"
  fi

  # The look: Greybird, elementary-xfce icons, the Whisker menu as the panel's
  # main menu, in a configuration directory of the image's own that
  # 56a7s-xfce-defaults puts ahead of /etc/xdg. No package file is edited.
  [ -f "${r}/usr/share/themes/${DESKTOP_GTK_THEME}/gtk-3.0/gtk.css" ] && [ -d "${r}/usr/share/themes/${DESKTOP_WM_THEME}/xfwm4" ] \
    || die "no ${DESKTOP_GTK_THEME} theme in the rootfs"
  [ -f "${r}/usr/share/icons/${DESKTOP_ICON_THEME}/index.theme" ] || die "no ${DESKTOP_ICON_THEME} icon theme in the rootfs"
  [ -f "${r}/usr/lib/aarch64-linux-gnu/xfce4/panel/plugins/libwhiskermenu.so" ] || die "no Whisker menu plugin in the rootfs"
  [ "$(grep -cF "${menu_line}" "${pkg_panel}" || true)" = 1 ] \
    || die "xfce4-panel's default.xml no longer has plugin-1 as the applications menu"
  install -d -m0755 "${lookd}/xfce4/panel" "${lookd}/xfce4/xfconf/xfce-perchannel-xml"
  sed "s|${menu_line}|${menu_line/applicationsmenu/whiskermenu}|" "${pkg_panel}" > "${lookd}/xfce4/panel/default.xml"
  panel_diff="$(diff "${pkg_panel}" "${lookd}/xfce4/panel/default.xml" | grep -c '^[<>]' || true)"
  [ "${panel_diff}" = 2 ] || die "the image's panel layout is not xfce4-panel's with exactly the menu exchanged"
  cat > "${lookd}/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- a7s-build: the image's GTK and icon theme, merged over xfce4-settings' own. -->
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="${DESKTOP_GTK_THEME}"/>
    <property name="IconThemeName" type="string" value="${DESKTOP_ICON_THEME}"/>
  </property>
</channel>
EOF
  cat > "${lookd}/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- a7s-build: the image's window manager theme; every other xfwm4 setting
     stays xfwm4's own default. -->
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="${DESKTOP_WM_THEME}"/>
  </property>
</channel>
EOF
  in_root "${r}" run-parts --list /etc/X11/Xsession.d | grep -qx /etc/X11/Xsession.d/56a7s-xfce-defaults \
    || die "run-parts does not list 56a7s-xfce-defaults -- Xsession would never source it"
  ln -sfn /lib/systemd/system/graphical.target "${r}/etc/systemd/system/default.target"
  # One language and one layout: the greeter and the session read them from
  # here, kmscon on tty1 follows systemd-localed, which reads the same file.
  [ "$(cat "${r}/etc/locale.conf")" = "LANG=${DESKTOP_LANG}" ] || die "/etc/locale.conf does not set LANG=${DESKTOP_LANG}"
  grep -qx "XKBLAYOUT=\"${DESKTOP_XKB_LAYOUT}\"" "${r}/etc/default/keyboard" \
    || die "/etc/default/keyboard does not set XKBLAYOUT=${DESKTOP_XKB_LAYOUT}"
  log "desktop: Xfce with LightDM, no autologin, default.target = graphical, ${DESKTOP_LANG}, keyboard ${DESKTOP_XKB_LAYOUT}"
}

# --- liborc with the aarch64 loadupdb fix (A7S_DESKTOP=1) ------------------------

# Debian's liborc of the same release, plus userspace/orc/patches, under
# /usr/local/lib/aarch64-linux-gnu, which ld.so searches before /usr/lib.
debian_orc() {  # <root>
  local r="$1" olib="$1/usr/local/lib/aarch64-linux-gnu" odoc="$1/usr/local/share/doc/liborc-a7s"
  local lib file deb_orc res up
  lib="$(compgen -G "${DEBIAN_ORC_DIR}/${DEBIAN_ORC_SONAME}.*" | LC_ALL=C sort | tail -1)"
  file="${lib##*/}"
  [ "$(sed -n 's/^lib_sha256=//p' "${DEBIAN_ORC_DIR}/ORC-ID")" = "$(sha256sum "${lib}" | cut -d' ' -f1)" ] \
    || die "${DEBIAN_ORC_DIR}/ORC-ID does not describe ${file}"
  deb_orc="$(in_root "${r}" dpkg-query -W -f='${db:Status-Status} ${Version}' liborc-0.4-0t64 2>/dev/null || true)"
  up="${file#"${DEBIAN_ORC_SONAME}".}"; up="${up%.0}"   # 41.0 -> 41 ; liborc-0.4.so.0.41.0 is orc 0.4.41
  case "${deb_orc}" in
    "installed 1:0.4.${up}-"*|"") ;;
    installed\ *) die "Debian's liborc is ${deb_orc#installed }, ours is orc 0.4.${up} -- ours would shadow a Debian build it was not made from" ;;
  esac
  install -d -m0755 "${olib}" "${odoc}/patches"
  install -m0644 "${lib}" "${olib}/"
  ln -sfn "${file}" "${olib}/${DEBIAN_ORC_SONAME}"
  install -m0644 "${DEBIAN_ORC_DIR}/ORC-ID" "${odoc}/"
  [ -f "${DEBIAN_ORC_DIR}/COPYING" ] && install -m0644 "${DEBIAN_ORC_DIR}/COPYING" "${odoc}/"
  local p
  for p in "${SRC}"/userspace/orc/patches/*.patch; do
    [ -f "${p}" ] && install -m0644 "${p}" "${odoc}/patches/"
  done
  in_root "${r}" ldconfig || die "ldconfig in the rootfs failed"
  res="$(in_root "${r}" ldconfig -p | awk -v s="${DEBIAN_ORC_SONAME}" '$1==s {print $NF; exit}')"
  [ "${res}" = "/usr/local/lib/aarch64-linux-gnu/${DEBIAN_ORC_SONAME}" ] \
    || die "ld.so resolves ${DEBIAN_ORC_SONAME} to '${res}', not ours"
  log "liborc ${file} (userspace/orc/patches) -> /usr/local/lib/aarch64-linux-gnu; Debian's: ${deb_orc:-not installed}"
}

# --- accounts -------------------------------------------------------------------

# root stays locked (Debian's `*`). The user account gets an EMPTY password
# that is expired: the first login on the console or in the greeter asks for a
# new one at once (pam_unix: "You are required to change your password
# immediately"), and sshd refuses an empty password (sshd_config.d/10-a7s.conf),
# so there is no remote login before a password is set.
debian_accounts() {  # <root>
  local r="$1" u="${A7S_USER}" g
  [[ "${u}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "A7S_USER '${u}' is not a valid user name"
  if grep -q "^${u}:" "${r}/etc/passwd"; then die "user ${u} already exists in the rootfs"; fi
  for g in useradd usermod groupadd chage grpck; do
    [ -x "${r}/usr/sbin/${g}" ] || [ -x "${r}/usr/bin/${g}" ] || die "no ${g} in the rootfs"
  done
  if ! grep -q '^render:' "${r}/etc/group"; then
    in_root "${r}" groupadd -g "${A7S_RENDER_GID}" render || die "creating group render failed"
  fi
  in_root "${r}" useradd -k /etc/skel -u "${A7S_USER_UID}" -U -m -s /bin/bash -G sudo,video,render "${u}" \
    || die "useradd ${u} failed"
  in_root "${r}" usermod -p '' "${u}" || die "clearing the password of ${u} failed"
  in_root "${r}" chage -d 0 "${u}" || die "expiring the password of ${u} failed"
  # root: Debian's `*` locks it; anything else is made `!`.
  case "$(awk -F: '$1=="root" {print $2}' "${r}/etc/shadow")" in
    '*'|'!'*) ;;
    *) in_root "${r}" usermod -p '!' root || die "locking root failed" ;;
  esac
  [ "$(stat -c '%a %u:%g' "${r}/home/${u}")" = "700 ${A7S_USER_UID}:${A7S_USER_UID}" ] \
    || die "/home/${u} is not 0700 ${A7S_USER_UID}:${A7S_USER_UID}"
  in_root "${r}" grpck -r >/dev/null 2>&1 || die "grpck: $(in_root "${r}" grpck -r 2>&1 | head -3)"
  log "accounts: root locked; ${u} (uid ${A7S_USER_UID}, sudo video render) with an empty, expired password"
}

# --- the system's configuration -----------------------------------------------

debian_system() {  # <root>
  local r="$1" u
  cp -a --no-preserve=ownership "${DEBIAN_DIR}/files/base/." "${r}/"
  chmod 0755 "${r}/usr/local/sbin/a7s-growroot"

  printf '%s\n' "${A7S_HOSTNAME}" > "${r}/etc/hostname"
  cat > "${r}/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	${A7S_HOSTNAME}
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF
  # C.UTF-8 without the locales package (as Debian's cloud images); the desktop
  # has it and gets DESKTOP_LANG, as the Debian installer sets for English.
  # /etc/default/locale is a link to this file.
  if [ "${A7S_DESKTOP}" = 1 ]; then
    printf 'LANG=%s\n' "${DESKTOP_LANG}" > "${r}/etc/locale.conf"
  else
    printf 'LANG=C.UTF-8\n' > "${r}/etc/locale.conf"
  fi
  # The board has no RTC battery. systemd (PID 1) moves a clock that is behind
  # the mtime of /usr/lib/clock-epoch up to it, so the first boot starts at the
  # build time instead of the RTC's reset value until NTP sets the clock.
  : > "${r}/usr/lib/clock-epoch"
  touch -d "@${SOURCE_DATE_EPOCH}" "${r}/usr/lib/clock-epoch"

  # Network: NetworkManager owns the links, no profile ships.
  [ -x "${r}/usr/sbin/NetworkManager" ] || die "no NetworkManager in the rootfs"
  in_rootfs "${r}" /etc/systemd/system/multi-user.target.wants/NetworkManager.service \
    || die "network-manager is installed but not enabled"
  install -d -m0700 "${r}/etc/NetworkManager/system-connections"
  [ -z "$(ls -A "${r}/etc/NetworkManager/system-connections")" ] || die "a connection profile is in the rootfs"
  for u in multi-user.target.wants/systemd-networkd.service sockets.target.wants/systemd-networkd.socket network-online.target.wants/systemd-networkd-wait-online.service; do
    ! in_rootfs "${r}" "/etc/systemd/system/${u}" || die "systemd-networkd is enabled next to NetworkManager (${u})"
  done
  rm -f "${r}/etc/systemd/system/default.target.wants/nvmf-autoconnect.service" \
        "${r}/etc/systemd/system/default.target.wants/nvmefc-boot-connections.service"
  [ -z "$(find "${r}/etc/systemd/system" -name 'nftables.service' -print -quit)" ] \
    || die "nftables.service is enabled -- Debian ships it disabled"
  [ "$(readlink "${r}/etc/alternatives/iptables")" = /usr/sbin/iptables-nft ] || die "iptables does not point at iptables-nft"
  # DNS as on a Debian install: NetworkManager writes /etc/resolv.conf, no
  # systemd-resolved (and so no LLMNR listener).
  [ ! -e "${r}/usr/lib/systemd/systemd-resolved" ] || die "systemd-resolved is in the rootfs -- NetworkManager does DNS, as on Debian"
  in_rootfs "${r}" /etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service || die "systemd-timesyncd is not enabled"
  in_rootfs "${r}" /etc/systemd/system/bluetooth.target.wants/bluetooth.service || die "bluetooth.service is not enabled"

  # Consoles: kmscon on tty1 only, agetty on tty2..6 (autovt@ back to getty@,
  # or logind would start a kmscon on every VT), and the UART.
  install -d -m0755 "${r}/etc/systemd/system/getty.target.wants" "${r}/etc/systemd/system/multi-user.target.wants"
  ln -sfn /lib/systemd/system/serial-getty@.service "${r}/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"
  ln -sfn /lib/systemd/system/getty@.service "${r}/etc/systemd/system/autovt@.service"
  ln -sfn /lib/systemd/system/kmsconvt@.service "${r}/etc/systemd/system/getty.target.wants/kmsconvt@tty1.service"
  [ -L "${r}/etc/systemd/system/getty.target.wants/getty@tty1.service" ] \
    || die "getty@tty1 is not enabled -- kmsconvt@'s OnFailure would have nothing to hand tty1 back to"

  # Our units.
  for u in a7s-growroot.service a7s-boot-good.service a7s-ssh-keygen.service a7s-nvme-hostid.service \
           a7s-ssl-cert.service a7s-icon-caches.service; do
    ln -sfn "/etc/systemd/system/${u}" "${r}/etc/systemd/system/multi-user.target.wants/${u}"
  done
  ln -sfn /dev/null "${r}/etc/systemd/system/systemd-firstboot.service"

  # Tools our units and scripts need.
  [ -x "${r}/usr/bin/busybox" ] || die "no busybox -- a7s-boot-good.service could not clear the boot counter"
  { in_root "${r}" /usr/bin/busybox 2>&1 || true; } | grep -qw devmem || die "busybox has no devmem applet"
  local t
  for t in usr/sbin/nvme usr/bin/uuidgen usr/sbin/sfdisk usr/bin/partx usr/sbin/dumpe2fs usr/sbin/resize2fs usr/sbin/fsck.ext4 usr/sbin/modprobe usr/bin/ssh-keygen usr/sbin/sshd; do
    [ -x "${r}/${t}" ] || die "no /${t} in the rootfs"
  done
  [ -f "${r}/usr/lib/aarch64-linux-gnu/security/pam_systemd.so" ] || die "no pam_systemd.so"
  grep -Eq '^session[[:space:]]+optional[[:space:]]+pam_systemd\.so' "${r}/etc/pam.d/common-session" \
    || die "common-session does not name pam_systemd"
  grep -Eq '^-?net\.ipv4\.ping_group_range *= *0 2147483647' "${r}/usr/lib/sysctl.d/50-default.conf" \
    || die "no ping_group_range in 50-default.conf (linux-sysctl-defaults)"

  # No setup wizard of any kind; the account's first login is the only question.
  local fb hit
  for fb in rsetup resize2fs_once armbian-firstrun firstrun oem-config cloud-init; do
    hit="$(find "${r}/etc/systemd/system" "${r}/usr/lib/systemd/system" "${r}/etc/init.d" -iname "*${fb}*" 2>/dev/null | head -1)"
    [ -z "${hit}" ] || die "setup-wizard unit in the rootfs: ${hit}"
  done
}

# The build fetched from the snapshot; the image fetches from Debian. deb822, as
# the trixie installer writes it, plus the backports source the two pins use.
debian_apt_sources_final() {  # <root>
  local r="$1"
  rm -f "${r}/etc/apt/sources.list"
  rm -f "${r}"/etc/apt/sources.list.d/*.list
  cat > "${r}/etc/apt/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: ${DEBIAN_MIRROR_FINAL}
Suites: ${DEBIAN_SUITE} ${DEBIAN_SUITE}-updates
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${DEBIAN_SECURITY_FINAL}
Suites: ${DEBIAN_SUITE}-security
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  cat > "${r}/etc/apt/sources.list.d/${DEBIAN_SUITE}-backports.sources" <<EOF
# Reachable for exactly the packages named in preferences.d/kmscon-backports and
# preferences.d/mesa-backports; everything else stays on ${DEBIAN_SUITE}.
Types: deb
URIs: ${DEBIAN_MIRROR_FINAL}
Suites: ${DEBIAN_SUITE}-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  chmod 0644 "${r}"/etc/apt/sources.list.d/*.sources
  ! grep -rqsF -e "${DEBIAN_MIRROR}" -e "${DEBIAN_SECURITY_MIRROR}" -e snapshot.debian.org "${r}/etc/apt" \
    || die "a build-time apt source is still in the rootfs's apt configuration"
  ! grep -rqs 'Acquire::http::Proxy' "${r}/etc/apt" || die "an apt proxy is configured in the rootfs"
}

# No file of an installed package differs from what the package shipped: the
# image adds files, it never edits a package's. Non-conffiles under /var are
# state and tolerated.
debian_dpkg_verify() {  # <root>
  local r="$1" out line vattr vpath bad=""
  out="$(in_root "${r}" dpkg --verify 2>&1)" || true
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    vattr="${line:10:1}" vpath="${line:12}"
    if [ "${vattr}" != c ] && [[ "${vpath}" == /var/* ]]; then continue; fi
    bad+="    ${line}"$'\n'
  done <<<"${out}"
  [ -z "${bad}" ] || die "the rootfs changes files that Debian packages own (dpkg --verify):"$'\n'"${bad}"
  log "dpkg --verify: no file of an installed package changed"
}

# What must not ship, or would make two builds differ. mmdebstrap's own cleanup
# runs after this (package lists, apt caches, dpkg/apt/alternatives logs,
# ldconfig's aux-cache, /etc/machine-id emptied).
debian_cleanup() {  # <root>
  local r="$1"
  rm -f "${r}"/etc/ssh/ssh_host_*
  # As Debian's live images (live-build hooks 8090, 9000): ssl-cert's snakeoil
  # key, its certificate and hash link, and the icon caches; the board makes
  # them on its first boot (a7s-ssl-cert, a7s-icon-caches).
  find "${r}/etc/ssl/certs" -maxdepth 1 -type l -lname ssl-cert-snakeoil.pem -delete 2>/dev/null || true
  rm -f "${r}/etc/ssl/certs/ssl-cert-snakeoil.pem" "${r}/etc/ssl/private/ssl-cert-snakeoil.key"
  rm -f "${r}"/usr/share/icons/*/icon-theme.cache
  rm -f "${r}/etc/nvme/hostnqn" "${r}/etc/nvme/hostid"
  rm -f "${r}/etc/apt/apt.conf.d/99mmdebstrap"
  : > "${r}/etc/machine-id"; chmod 0444 "${r}/etc/machine-id"
  rm -f "${r}/var/lib/dbus/machine-id"
  rm -f "${r}"/var/cache/debconf/*-old "${r}"/var/lib/dpkg/*-old "${r}/etc/shadow-" "${r}/etc/gshadow-" \
        "${r}/etc/passwd-" "${r}/etc/group-" "${r}/etc/subuid-" "${r}/etc/subgid-"
  rm -rf "${r}"/var/cache/fontconfig/* "${r}"/var/cache/man/*
  rm -rf "${r:?}"/tmp/* "${r:?}"/var/tmp/* "${r}/root/.bash_history"
  find "${r}/var/log" -type f -delete
  # Package lists and apt's binary caches (mmdebstrap's own cleanup leaves them
  # once the hook has run apt in the chroot); `apt update` on the board.
  find "${r}/var/lib/apt/lists" -mindepth 1 -maxdepth 1 ! -name partial ! -name lock -exec rm -rf {} +
  rm -f "${r}"/var/cache/apt/*.bin
  find "${r}/usr" -name '__pycache__' -type d -prune -exec rm -rf {} +
  # The resolver last: apt in the hooks used the builder's, which mmdebstrap
  # copied in. On the board NetworkManager writes /etc/resolv.conf.
  rm -f "${r}/etc/resolv.conf"
}

# --- the rules the finished root filesystem must hold ---------------------------

distro_rootfs_assert() {  # <dir>
  local r="$1" u="${A7S_USER}" sh f
  [ -d "${r}/etc" ] || die "no root filesystem at ${r}"
  # Accounts: root locked, the user with an empty password that must be changed.
  sh="$(awk -F: '$1=="root" {print $2}' "${r}/etc/shadow")"
  case "${sh}" in '*'|'!'*) ;; *) die "root is not locked in /etc/shadow" ;; esac
  awk -F: -v u="${u}" '$1==u && $2=="" && $3=="0" {f=1} END {exit !f}' "${r}/etc/shadow" \
    || die "${u} has no empty, expired password in /etc/shadow: $(grep "^${u}:" "${r}/etc/shadow" | cut -d: -f1,3-)"
  local others
  others="$(awk -F: -v u="${u}" '$1!=u && $1!="root" && $2!~/^[*!]/ {print $1}' "${r}/etc/shadow")"
  [ -z "${others}" ] || die "accounts with a usable password in /etc/shadow: ${others}"
  for f in sudo video render; do
    awk -F: -v g="${f}" -v u="${u}" '$1==g { n=split($4, m, ","); for (i=1; i<=n; i++) if (m[i]==u) ok=1 } END { exit !ok }' "${r}/etc/group" \
      || die "group ${f} does not list ${u}"
  done
  grep -qx 'PermitEmptyPasswords no' "${r}/etc/ssh/sshd_config.d/10-a7s.conf" || die "sshd_config.d/10-a7s.conf lost PermitEmptyPasswords no"
  ! grep -rqsiE '^[[:space:]]*PermitEmptyPasswords[[:space:]]+yes' "${r}/etc/ssh" || die "an sshd configuration permits empty passwords"
  # Identity: no SSH host key, no machine ID.
  ! compgen -G "${r}/etc/ssh/ssh_host_*" >/dev/null || die "SSH host keys in the rootfs -- every board would share them"
  [ ! -e "${r}/etc/ssl/private/ssl-cert-snakeoil.key" ] && [ ! -e "${r}/etc/ssl/certs/ssl-cert-snakeoil.pem" ] \
    || die "ssl-cert's snakeoil key in the rootfs -- every board would share it"
  [ -z "$(find "${r}/etc/ssl/certs" -maxdepth 1 -type l -lname ssl-cert-snakeoil.pem -print -quit 2>/dev/null)" ] \
    || die "a hash link to the removed snakeoil certificate in /etc/ssl/certs"
  ! compgen -G "${r}/usr/share/icons/*/icon-theme.cache" >/dev/null || die "icon caches in the rootfs -- two builds would differ"
  [ ! -e "${r}/etc/nvme/hostnqn" ] && [ ! -e "${r}/etc/nvme/hostid" ] || die "an NVMe host NQN or host ID in the rootfs -- every board would share it"
  [ ! -s "${r}/etc/machine-id" ] || die "/etc/machine-id holds an ID"
  [ ! -e "${r}/var/lib/systemd/random-seed" ] || die "a random seed from the build is in the rootfs"
  [ ! -e "${r}/var/lib/dbus/machine-id" ] || [ "$(readlink "${r}/var/lib/dbus/machine-id")" = /etc/machine-id ] \
    || die "/var/lib/dbus/machine-id is a copy of the build's machine ID"
  [ ! -e "${r}/etc/resolv.conf" ] && [ ! -L "${r}/etc/resolv.conf" ] \
    || die "/etc/resolv.conf is in the rootfs -- the builder's resolver would ship (NetworkManager writes it on the board)"
  [ "$(stat -c %Y "${r}/usr/lib/clock-epoch" 2>/dev/null)" = "${SOURCE_DATE_EPOCH}" ] \
    || die "/usr/lib/clock-epoch is missing or its mtime is not SOURCE_DATE_EPOCH"
  [ "$(cat "${r}/etc/hostname")" = "${A7S_HOSTNAME}" ] || die "/etc/hostname is not ${A7S_HOSTNAME}"
  # Residue of the build.
  ! compgen -G "${r}/var/cache/apt/archives/*.deb" >/dev/null || die "cached .deb files in the rootfs"
  [ -z "$(find "${r}/var/lib/apt/lists" -maxdepth 1 -type f ! -name lock -print -quit 2>/dev/null)" ] || die "apt package lists in the rootfs"
  [ -z "$(find "${r}/var/log" -type f -print -quit)" ] || die "log files in the rootfs: $(find "${r}/var/log" -type f | head -3 | tr '\n' ' ')"
  ! grep -rqs 'snapshot\.debian\.org' "${r}/etc/apt" || die "a snapshot source in the rootfs's apt configuration"
  [ ! -e "${r}/etc/apt/apt.conf.d/99mmdebstrap" ] || die "mmdebstrap's build-time apt options are in the rootfs"
  # Ownership: nothing outside /home belongs to a regular uid/gid (a leak of
  # the builder's).
  f="$(find "${r}" -xdev -path "${r}/home" -prune -o \( \( -uid +999 -uid -60000 \) -o \( -gid +999 -gid -60000 \) \) -print | head -5)"
  [ -z "${f}" ] || die "files outside /home owned by a regular uid/gid: ${f}"
  log "rootfs rules hold: root locked, ${u} must set a password, no host keys, no machine ID, no build residue"
}
