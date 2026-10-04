# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# xfwm4 stages: fetch-xfwm4, build-xfwm4, check-xfwm4-deb. Sourced by
# scripts/inner.sh. Part of the desktop image (A7S_DESKTOP=1).
#
# Debian trixie's xfwm4 4.20.0-1 starts the compositor without vsync on a user's
# first login and logs "Another compositing manager is running"
# (loadXfconfData() writes the defaults back, xfconf emits property-changed in the
# same call, and the callback starts the compositor in the middle of
# loadSettings(); the patch header has the account). build-xfwm4 builds Debian's
# own source package with that patch as a quilt patch, for arm64, and the image
# stage installs the .deb over Debian's. It is a package and not a /usr/local
# overlay like liborc, because xfwm4 is a program that is started by name and by
# path: nothing orders two copies of it the way ld.so orders two libraries.
#
# The three source files are pinned by sha256, and the chain is anchored twice:
# the archive's signed Sources index lists these three sums for xfwm4 4.20.0-1
# (InRelease verified with gpgv against the Debian archive key; dscverify against
# debian-keyring says "Good signature" for the .dsc), and the orig tarball is
# byte-identical to the release tarball archive.xfce.org serves over TLS. The
# sha256 decides, whichever URL delivers: the pool drops a superseded version,
# snapshot.debian.org keeps it.
#
# The version sorts ABOVE Debian's 4.20.0-1 and BELOW its next security build
# (4.20.0-1+deb13u1 > 4.20.0-1+a7s1: 'd' sorts after 'a'), which is why the image
# stage pins it in apt's preferences as well.
XFWM4_DEBIAN_VERSION="4.20.0-1"
XFWM4_DEB_VERSION="4.20.0-1+a7s1"
XFWM4_SOURCE_SHA256=(
  "bd654a06380c243dcc24391cb126ef734144cef6e52a824d1b7f70ded6f2ff3c  xfwm4_4.20.0-1.dsc"
  "a58b63e49397aa0d8d1dcf0636be93c8bb5926779aef5165e0852890190dcf06  xfwm4_4.20.0.orig.tar.bz2"
  "10f368a75a64e7dbf3b6a17207473ebd2728bac71a3798cb5a5d049b17c9ca94  xfwm4_4.20.0-1.debian.tar.xz"
)
XFWM4_DSC_NAME="xfwm4_${XFWM4_DEBIAN_VERSION}.dsc"
XFWM4_SNAPSHOT_URL="https://snapshot.debian.org/archive/debian/20260918T000000Z/pool/main/x/xfwm4"
# The patches by content, by count and in series order, as for ORC.
XFWM4_PATCH_SHA256=(
  "692cc5e04636b9fa5dc5dfc9416f9b8bb013cf7e9d6a1da415251c690af91737  settings-block-channel-callback-while-writing-defaults.patch"
)
# What the patch leaves in the binary that Debian's build lacks: it calls
# g_signal_handlers_block_matched() and g_signal_handlers_unblock_matched() (the
# macros' targets), and Debian's xfwm4 4.20.0-1 imports neither (checked on its
# arm64 .deb). xfwm4_elf_missing_fix_symbols reads the dynamic symbol table.
XFWM4_FIX_SYMBOLS=(g_signal_handlers_block_matched g_signal_handlers_unblock_matched)
# The one changelog entry build-xfwm4 puts on top of Debian's, fixed text and
# fixed date. The date becomes SOURCE_DATE_EPOCH, which clamps every mtime in
# the package: it must lie BEFORE any build, or the files keep the time they
# were built at and two builds of the same inputs differ. It becomes the epoch
# only while the environment carries none, so the build runs with
# SOURCE_DATE_EPOCH unset: an inherited one would change the package's sha256.
XFWM4_CHANGELOG_DATE="Sat, 03 Oct 2026 00:00:00 +0000"
XFWM4_CHANGELOG_TEXT="Block the xfconf channel callback while loadXfconfData() writes the defaults back (userspace/xfwm4/patches): the compositor started in the middle of loadSettings() without vsync on a user's first login, and init_compositor_screen() then logged 'Another compositing manager is running'."
XFWM4_MAINTAINER="DockSeed <dockseed@proton.me>"
XFWM4_APT_PIN="/etc/apt/preferences.d/xfwm4-a7s"
XFWM4_DOC_DIR="/usr/local/share/doc/xfwm4-a7s"

# shellcheck source=../lib/series.sh
. "${SRC}/scripts/lib/series.sh"

pins_xfwm4() {
  log "xfwm4    : ${XFWM4_DEB_VERSION} (Debian ${XFWM4_DEBIAN_VERSION}'s source, dsc sha256 ${XFWM4_SOURCE_SHA256[0]%% *}), + ${#XFWM4_PATCH_SHA256[@]} patch(es) in userspace/xfwm4/patches/"
}

# --- xfwm4 checks (also used by the image stage) ---------------------------------

xfwm4_elf_missing_fix_symbols() {  # <elf>
  local elf="$1" syms s missing=()
  syms="$(readelf -W --dyn-syms "${elf}")" || die "readelf --dyn-syms failed on ${elf}"
  for s in "${XFWM4_FIX_SYMBOLS[@]}"; do
    grep -Eq "[[:space:]]${s}(@|\$)" <<<"${syms}" || missing+=("${s}")
  done
  echo "${missing[*]}"
}

# Reads <deb>'s control and its /usr/bin/xfwm4, says what they are, and fails
# unless the package is xfwm4 at XFWM4_DEB_VERSION for arm64 with the fix in its
# binary. Used by build-xfwm4 on what it built, and runnable on any .deb:
# `inner.sh check-xfwm4-deb xfwm4_4.20.0-1_arm64.deb` (Debian's own) must fail.
xfwm4_check_deb() {  # <deb>
  local deb="$1" f missing tmp
  [ -f "${deb}" ] || die "xfwm4 check: no such file ${deb}"
  for f in Package Version Architecture; do
    log "xfwm4 check: ${f}: $(dpkg-deb -f "${deb}" "${f}")"
  done
  [ "$(dpkg-deb -f "${deb}" Package)" = xfwm4 ] || die "xfwm4 check: ${deb##*/} is not the xfwm4 package"
  [ "$(dpkg-deb -f "${deb}" Architecture)" = arm64 ] || die "xfwm4 check: ${deb##*/} is not an arm64 package"
  [ "$(dpkg-deb -f "${deb}" Version)" = "${XFWM4_DEB_VERSION}" ] \
    || die "xfwm4 check: ${deb##*/} is version $(dpkg-deb -f "${deb}" Version), not ${XFWM4_DEB_VERSION} -- Debian's package, not ours"
  tmp="$(mktemp -d)"
  dpkg-deb --fsys-tarfile "${deb}" | tar -xf - -C "${tmp}" ./usr/bin/xfwm4 \
    || { rm -rf "${tmp:?}"; die "xfwm4 check: ${deb##*/} carries no /usr/bin/xfwm4"; }
  missing="$(xfwm4_elf_missing_fix_symbols "${tmp}/usr/bin/xfwm4")"
  rm -rf "${tmp:?}"
  [ -z "${missing}" ] \
    || die "xfwm4 check: /usr/bin/xfwm4 in ${deb##*/} does not import ${missing} -- it does not carry the first-login fix (Debian's build does not)"
  log "xfwm4 check: ${deb##*/} carries the first-login fix (imports ${XFWM4_FIX_SYMBOLS[*]})"
}

# The image's xfwm4 is ours. Reads the dpkg database of <root> (a rootfs,
# or a mounted image) from the host, and the files under it. Fails when
#   - xfwm4 is not installed, or is not exactly XFWM4_DEB_VERSION,
#   - another package built from the xfwm4 source has another version,
#   - /usr/bin/xfwm4 does not import the symbols the fix leaves in the binary
#     (xfwm4_elf_missing_fix_symbols; Debian's build lacks them),
#   - preferences.d/xfwm4-a7s does not pin exactly that version at 990, so that
#     `apt upgrade` would put Debian's xfwm4 back.
assert_xfwm4_ours() {  # <root>
  local r="$1" adm="$1/var/lib/dpkg" st ver bad missing pin="$1${XFWM4_APT_PIN}"
  [ -d "${adm}" ] || die "assert_xfwm4_ours: no dpkg database in ${r}"
  st="$(dpkg-query --admindir="${adm}" -W -f='${db:Status-Status}' xfwm4 2>/dev/null || true)"
  [ "${st}" = installed ] || die "xfwm4 is not installed (status '${st}') -- the desktop image has no window manager"
  ver="$(dpkg-query --admindir="${adm}" -W -f='${Version}' xfwm4)" || die "dpkg-query: no xfwm4 in ${r}"
  [ "${ver}" = "${XFWM4_DEB_VERSION}" ] \
    || die "xfwm4 is ${ver}, the image is to carry ${XFWM4_DEB_VERSION} (Debian's does not have the first-login fix)"
  bad="$(dpkg-query --admindir="${adm}" -W -f='${Package}\t${Version}\t${source:Package}\n' \
           | awk -F'\t' -v v="${XFWM4_DEB_VERSION}" '$3 == "xfwm4" && $2 != v {print $1 " " $2}')" \
    || die "dpkg-query failed on ${adm}"
  [ -z "${bad}" ] || die "packages built from the xfwm4 source at another version than ours: $(tr '\n' ';' <<<"${bad}")"
  [ -f "${r}/usr/bin/xfwm4" ] || die "xfwm4 ${ver} is installed but ${r}/usr/bin/xfwm4 is not there"
  missing="$(xfwm4_elf_missing_fix_symbols "${r}/usr/bin/xfwm4")"
  [ -z "${missing}" ] \
    || die "/usr/bin/xfwm4 does not import ${missing} -- it does not carry the first-login fix"
  [ -f "${pin}" ] || die "no ${XFWM4_APT_PIN} -- apt upgrade would replace our xfwm4 with Debian's next build"
  grep -Fxq "Package: xfwm4" "${pin}" && grep -Fxq "Pin: version ${XFWM4_DEB_VERSION}" "${pin}" \
    && grep -Fxq "Pin-Priority: 990" "${pin}" \
    || die "${XFWM4_APT_PIN} does not pin xfwm4 at exactly ${XFWM4_DEB_VERSION}, priority 990"
}

stage_check_xfwm4_deb() {
  [ -n "${1:-}" ] || die "usage: inner.sh check-xfwm4-deb <xfwm4 .deb>"
  command -v dpkg-deb >/dev/null && command -v readelf >/dev/null || die "check-xfwm4-deb needs dpkg-deb and readelf"
  xfwm4_check_deb "$1"
}

# Debian's xfwm4 source package (.dsc, orig, debian tarball) into
# WORK_DIR/xfwm4/dl, every file held against XFWM4_SOURCE_SHA256, unpacked with
# dpkg-source (which checks the sums the .dsc lists once more) into
# WORK_DIR/xfwm4/src, and userspace/xfwm4/patches/ put in as the quilt series
# Debian's source does not have, on top of a changelog entry for
# XFWM4_DEB_VERSION. dpkg-buildpackage applies the series itself, at fuzz 0.
stage_fetch_xfwm4() {
  local dir="${WORK_DIR}/xfwm4" src="${WORK_DIR}/xfwm4/src" dl="${WORK_DIR}/xfwm4/dl"
  local ent sum file p n i pinned top
  for p in patch dpkg-source dpkg-parsechangelog fold; do
    command -v "${p}" >/dev/null || die "fetch-xfwm4 needs '${p}' (trixie: dpkg-dev patch coreutils)"
  done
  mkdir -p "${dl}"
  for ent in "${XFWM4_SOURCE_SHA256[@]}"; do
    sum="${ent%% *}"; file="${ent##* }"
    fetch_verified "${sum}" "${dl}/${file}" \
      "${DEBIAN_MIRROR}/pool/main/x/xfwm4/${file}" \
      "https://deb.debian.org/debian/pool/main/x/xfwm4/${file}" \
      "${XFWM4_SNAPSHOT_URL}/${file}"
  done

  # The patches: content, count and order pinned, as for liborc.
  local pdir="${SRC}/userspace/xfwm4/patches"
  ( cd "${pdir}" && printf '%s\n' "${XFWM4_PATCH_SHA256[@]}" | sha256sum -c --quiet - ) \
    || die "xfwm4 patches: a patch differs from its pinned sha256 (XFWM4_PATCH_SHA256) -- a changed patch is a different artefact from the one tested"
  n="$(find "${pdir}" -name '*.patch' | wc -l)"
  [ "${n}" = "${#XFWM4_PATCH_SHA256[@]}" ] \
    || die "userspace/xfwm4/patches holds ${n} patches, ${#XFWM4_PATCH_SHA256[@]} are pinned"
  series_load "${pdir}" || die "userspace/xfwm4/patches/series is missing, empty or malformed"
  [ "${#SERIES[@]}" = "${#XFWM4_PATCH_SHA256[@]}" ] \
    || die "xfwm4 patch series lists ${#SERIES[@]} patches, ${#XFWM4_PATCH_SHA256[@]} are pinned"
  for i in "${!SERIES[@]}"; do
    pinned="${XFWM4_PATCH_SHA256[$i]##* }"
    [ "${SERIES[$i]}" = "${pinned}" ] || die "xfwm4 patch series entry $((i + 1)) is ${SERIES[$i]}, the pin says ${pinned}"
  done

  rm -rf "${src:?}"
  ( cd "${dl}" && dpkg-source -x "${XFWM4_DSC_NAME}" "${src}" >"${dir}/dpkg-source.log" 2>&1 ) \
    || { cat "${dir}/dpkg-source.log" >&2; die "dpkg-source -x ${XFWM4_DSC_NAME} failed"; }
  top="$(dpkg-parsechangelog -l "${src}/debian/changelog" -SVersion)"
  [ "${top}" = "${XFWM4_DEBIAN_VERSION}" ] \
    || die "the unpacked source is ${top}, the pin says ${XFWM4_DEBIAN_VERSION}"
  [ ! -e "${src}/debian/patches" ] \
    || die "Debian's xfwm4 ${XFWM4_DEBIAN_VERSION} carries debian/patches now -- our patches would have to be merged into its series, not copied over it"
  for p in "${SERIES[@]}"; do
    patch -d "${src}" -p1 --fuzz=0 --dry-run -s < "${pdir}/${p}" \
      || die "xfwm4: ${p} does not apply at --fuzz=0 to Debian's ${XFWM4_DEBIAN_VERSION}"
  done
  install -d "${src}/debian/patches"
  for p in "${SERIES[@]}"; do install -m0644 "${pdir}/${p}" "${src}/debian/patches/${p}"; done
  printf '%s\n' "${SERIES[@]}" > "${src}/debian/patches/series"
  {
    printf 'xfwm4 (%s) trixie; urgency=medium\n\n' "${XFWM4_DEB_VERSION}"
    printf '%s\n' "${XFWM4_CHANGELOG_TEXT}" | fold -s -w 72 | sed '1s/^/  * /; 2,$s/^/    /; s/[[:space:]]*$//'
    printf '\n -- %s  %s\n\n' "${XFWM4_MAINTAINER}" "${XFWM4_CHANGELOG_DATE}"
    cat "${src}/debian/changelog"
  } > "${src}/debian/changelog.new"
  mv "${src}/debian/changelog.new" "${src}/debian/changelog"
  top="$(dpkg-parsechangelog -l "${src}/debian/changelog" -SVersion)"
  [ "${top}" = "${XFWM4_DEB_VERSION}" ] || die "debian/changelog starts with ${top}, expected ${XFWM4_DEB_VERSION}"
  log "xfwm4: Debian's ${XFWM4_DEBIAN_VERSION} source + ${#SERIES[@]} patch(es) -> ${src} (${XFWM4_DEB_VERSION})"
}

# A dedicated build chroot under WORK_DIR, and why it is a chroot.
#
# xfwm4's debian/control says `Build-Depends: xfce4-dev-tools` (no `:native`), so
# `apt-get build-dep -a arm64` asks for xfce4-dev-tools:arm64, whose
# `Depends: python3` (an arm64 package without Multi-Arch, so it takes python3 of
# its own architecture) pulls python3:arm64 -- and that cannot sit beside the
# builder's python3:amd64. apt would remove python3, python3-minimal,
# python3-yaml, python3.13 and others from the shared builder, which the image
# stage needs afterwards. Even without the removal the closure adds ~76 foreign
# packages (debhelper, dbus, gettext, perl modules). So the cross build
# dependencies are installed in a minimal Debian chroot of their own, created
# with mmdebstrap from the same archive snapshot as the image, and the shared
# builder is never touched. On an arm64 builder the chroot is arm64 and the
# build is native, with the same steps minus `--add-architecture`.
xfwm4_chroot() {
  local root="${WORK_DIR}/xfwm4/chroot" host_arch
  host_arch="$(dpkg --print-architecture)"
  if [ ! -f "${root}/.a7s-ready" ]; then
    command -v mmdebstrap >/dev/null || die "build-xfwm4 needs mmdebstrap (container/packages.d/xfwm4.txt)"
    rm -rf "${root:?}"
    mkdir -p "${WORK_DIR}/xfwm4"
    log "xfwm4: creating the build chroot (${host_arch}, ${A7S_SUITE}, ${DEBIAN_MIRROR})" >&2
    # --mode=root: uid 0 of the container's user namespace, as the root
    # filesystem stage does. The archive snapshot's Release files are old: apt
    # must not refuse them.
    TMPDIR="${WORK_DIR}" mmdebstrap --mode=root --variant=minbase --format=directory \
      --architectures="${host_arch}" --include=ca-certificates,dpkg-dev \
      --aptopt='Acquire::Check-Valid-Until "false"' --aptopt='APT::Install-Recommends "false"' \
      "${A7S_SUITE}" "${root}" "deb ${DEBIAN_MIRROR} ${A7S_SUITE} main" \
      >"${WORK_DIR}/xfwm4/mmdebstrap.log" 2>&1 \
      || { tail -30 "${WORK_DIR}/xfwm4/mmdebstrap.log" >&2; die "xfwm4: creating the build chroot failed"; }
    printf 'Acquire::Check-Valid-Until "false";\nAPT::Install-Recommends "false";\n' \
      > "${root}/etc/apt/apt.conf.d/99a7s"
    printf 'deb %s %s main\ndeb-src %s %s main\n' "${DEBIAN_MIRROR}" "${A7S_SUITE}" "${DEBIAN_MIRROR}" "${A7S_SUITE}" \
      > "${root}/etc/apt/sources.list"
    touch "${root}/.a7s-ready"
  fi
  printf '%s' "${root}"
}

# Run a command in the build chroot with /dev, /proc and /sys of the build
# environment bound in (a fresh proc or sysfs mount is refused inside the build,
# a recursive bind is not), and unbound again whatever the command does.
xfwm4_in_chroot() {  # <root> <command...>
  local root="$1" rc=0 d; shift
  for d in dev proc sys; do
    mkdir -p "${root}/${d}"
    mount --rbind "/${d}" "${root}/${d}" || die "xfwm4: cannot bind /${d} into the build chroot"
  done
  "$@" || rc=$?
  for d in sys proc dev; do umount -R "${root}/${d}" || true; done
  return "${rc}"
}

# xfwm4 4.20.0-1+a7s1 for arm64 into OUT_DIR/xfwm4, from Debian's own source
# package with the patch on top, as Debian builds it: dpkg-buildpackage, debhelper
# compat 13, the package's own debian/rules (hardening=+all and the linker flags
# are in it). Cross on any other host, native on arm64. What lands in
# OUT_DIR/xfwm4, flat: the .deb and XFWM4-ID (versions, source and patch sums,
# what was built with, the deb's and the binary's sha256).
#
# The fix is checked by what it leaves in the binary (xfwm4_check_deb): the
# binary imports g_signal_handlers_block_matched / _unblock_matched, which
# Debian's does not. That says the patch is compiled in, not that it works.
stage_build_xfwm4() {
  local dir="${WORK_DIR}/xfwm4" dst="${OUT_DIR}/xfwm4" root
  local arch_opt="" how=native deb="xfwm4_${XFWM4_DEB_VERSION}_arm64.deb" sum bin cross=0
  local host_arch; host_arch="$(dpkg --print-architecture)"
  if [ "${host_arch}" != arm64 ]; then
    arch_opt="-a arm64"; cross=1
    how="cross (arm64 from ${host_arch})"
  fi
  for t in dpkg-deb readelf chroot mount; do
    command -v "${t}" >/dev/null || die "build-xfwm4 needs '${t}'"
  done
  stage_fetch_xfwm4
  root="$(xfwm4_chroot)"
  # The source tree goes into the chroot; the build runs there as root.
  rm -rf "${root}/build"
  mkdir -p "${root}/build"
  cp -a "${dir}/src" "${root}/build/src"
  log "xfwm4: installing the cross build dependencies in the chroot"
  xfwm4_in_chroot "${root}" chroot "${root}" /bin/sh -e -c "
    $([ "${cross}" = 1 ] && echo 'dpkg --add-architecture arm64')
    apt-get update -q
    apt-get install -y -q --no-install-recommends $([ "${cross}" = 1 ] && echo crossbuild-essential-arm64 || echo build-essential) fakeroot
    apt-get build-dep -y -q ${arch_opt} /build/src
  " >"${dir}/chroot-deps.log" 2>&1 \
    || { tail -40 "${dir}/chroot-deps.log" >&2; die "build-xfwm4: installing the build dependencies in the chroot failed (log: ${dir}/chroot-deps.log)"; }

  rm -f "${dir:?}"/xfwm4_*.deb "${dir:?}"/xfwm4_*.buildinfo "${dir:?}"/xfwm4_*.changes
  # noautodbgsym: nothing ships the -dbgsym package. nocheck: xfwm4 has no test
  # suite to run. SOURCE_DATE_EPOCH is unset on purpose (see XFWM4_CHANGELOG_DATE).
  xfwm4_in_chroot "${root}" env -u SOURCE_DATE_EPOCH chroot "${root}" /bin/sh -e -c "
    cd /build/src
    DEB_BUILD_OPTIONS='nocheck noautodbgsym parallel=${XFWM4_JOBS:-4}' \
      dpkg-buildpackage ${arch_opt} -b -uc -us
  " >"${dir}/build.log" 2>&1 \
    || { tail -40 "${dir}/build.log" >&2; die "build-xfwm4: dpkg-buildpackage failed (log: ${dir}/build.log)"; }
  [ -f "${root}/build/${deb}" ] || die "build-xfwm4: the build did not produce ${deb}"
  local p
  for p in "${root}"/build/xfwm4_*.deb; do
    [ "${p##*/}" = "${deb}" ] || die "build-xfwm4: the build also produced ${p##*/}, which is not ours"
  done
  cp "${root}/build/${deb}" "${dir}/${deb}"
  xfwm4_check_deb "${dir}/${deb}"

  rm -rf "${dst:?}"
  install -d -m0755 "${dst}"
  install -m0644 "${dir}/${deb}" "${dst}/"
  sum="$(sha256sum "${dst}/${deb}" | cut -d' ' -f1)"
  bin="$(dpkg-deb --fsys-tarfile "${dst}/${deb}" | tar -xOf - ./usr/bin/xfwm4 | sha256sum | cut -d' ' -f1)"
  {
    echo "version=${XFWM4_DEB_VERSION}"
    echo "debian_source=${XFWM4_DEBIAN_VERSION}"
    printf '%s\n' "${XFWM4_SOURCE_SHA256[@]}" | awk '{print "source=" $2 " " $1}'
    printf '%s\n' "${XFWM4_PATCH_SHA256[@]}" | awk '{print "patch=" $2 " " $1}'
    echo "build=dpkg-buildpackage -b, ${how}, in a dedicated ${A7S_SUITE} chroot, debhelper compat 13 (Debian's debian/rules)"
    echo "fix_symbols=${XFWM4_FIX_SYMBOLS[*]}"
    echo "deb=${deb}"
    echo "deb_sha256=${sum}"
    echo "binary_sha256=${bin}"
  } > "${dst}/XFWM4-ID"
  chmod 0644 "${dst}/XFWM4-ID"
  log "xfwm4 ${XFWM4_DEB_VERSION} (Debian's ${XFWM4_DEBIAN_VERSION} source + ${#SERIES[@]} patch(es)) -> ${dst}/${deb}, sha256 ${sum}, ${how}"
}

# Group stage run by the full chain (inner.sh all).
stage_xfwm4() { stage_build_xfwm4; }
