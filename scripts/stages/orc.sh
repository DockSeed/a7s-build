# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# ORC stage: build-orc. Sourced by scripts/inner.sh.
#
# Debian trixie's liborc-0.4-0t64 1:0.4.41-1 overreads a source row in its NEON
# JIT (loadupdb on aarch64) and crashes videoconvert on exactly-sized dma-bufs.
# build-orc builds the same release with userspace/orc/patches/ applied; the
# image stage installs it under /usr/local, which ld.so searches before
# /usr/lib. Debian's package carries no patch of its own and its orig tarball is
# the file pinned here, so the patch is the whole source difference.
#
# The sha256 is anchored twice: the .sha256sum gstreamer.freedesktop.org
# publishes beside the tarball over TLS, and `apt-get source orc=1:0.4.41-1` in a
# trixie container, which checks the same file through the archive's signed
# Sources. Either URL serves it; the sha256 decides. A bump changes version,
# Debian version, sha256 and debian/rules' two flag variables below, if Debian
# changed them.
ORC_VERSION="0.4.41"
ORC_DEBIAN_VERSION="1:0.4.41-1"
ORC_TARBALL="orc-${ORC_VERSION}.tar.xz"
ORC_URLS=(
  "https://gstreamer.freedesktop.org/src/orc/${ORC_TARBALL}"
  "https://deb.debian.org/debian/pool/main/o/orc/orc_${ORC_VERSION}.orig.tar.xz"
)
ORC_SHA256="cb1bfd4f655289cd39bc04642d597be9de5427623f0861c1fc19c08d98467fa2"
# The patches by content, by count and in series order: a changed file is a
# different artefact from the one measured.
ORC_PATCH_SHA256=(
  "5d820a94507b8b70714d3c5ff6fbfaa144ed2518c53d5a35bba976e72aeb8f67  neon-fix-loadupdb-reading-past-the-end-of-the-source-on-aarch64.patch"
)
ORC_SONAME="liborc-0.4.so.0"
ORC_LIBFILE="liborc-0.4.so.0.41.0"
# What debian/rules of 1:0.4.41-1 adds to dpkg-buildflags' defaults. build-orc
# builds with exactly the flags Debian's arm64 package gets (see stage_build_orc).
ORC_DEB_BUILD_MAINT_OPTIONS="hardening=+all"
ORC_DEB_LDFLAGS_MAINT_APPEND="-Wl,-O1 -Wl,-z,defs"

# shellcheck source=../lib/series.sh
. "${SRC}/scripts/lib/series.sh"

pins_orc() {
  log "orc      : ${ORC_VERSION} (Debian ${ORC_DEBIAN_VERSION}'s source), sha256 ${ORC_SHA256}, + ${#ORC_PATCH_SHA256[@]} patch(es) in userspace/orc/patches/"
}

# The hardening Debian's arm64 flags leave in a shared library, read off the ELF:
# one word per property present. build-orc requires all six in our liborc, and
# Debian's own liborc-0.4.so.0.41.0 (1:0.4.41-1, arm64) shows the same six.
# -fstack-clash-protection leaves no mark in the ELF; build-orc checks the flag.
orc_hardening() {  # <lib>
  local lib="$1" dyn ph notes syms have=()
  dyn="$(readelf -dW "${lib}")" && ph="$(readelf -lW "${lib}")" \
    && notes="$(readelf -nW "${lib}")" && syms="$(readelf --dyn-syms -W "${lib}")" \
    || return 1
  grep -q 'GNU_RELRO' <<<"${ph}" && have+=(relro)
  grep -Eq '\(FLAGS\)[[:space:]]+.*BIND_NOW' <<<"${dyn}" \
    && grep -Eq '\(FLAGS_1\)[[:space:]]+Flags:.*\bNOW\b' <<<"${dyn}" && have+=(bindnow)
  grep -Eq '[[:space:]]UND[[:space:]]+__stack_chk_fail(@|$)' <<<"${syms}" && have+=(stack-protector)
  # Filter into a variable first, not `grep -v … | grep -q …`: under pipefail
  # the -q grep exits at its first match, the filter still writing dies of
  # SIGPIPE, and the pipeline fails -- `fortify` then went missing at random
  # (302 of 1000 runs on one core). Same idiom as the nm check above.
  local nochk
  nochk="$(grep -v '__stack_chk_fail' <<<"${syms}")" || true
  grep -Eq '[[:space:]]UND[[:space:]]+__[a-z0-9_]+_chk(@|$)' <<<"${nochk}" && have+=(fortify)
  grep -Eq 'AArch64 feature:.*\bBTI\b' <<<"${notes}" && have+=(bti)
  grep -Eq 'AArch64 feature:.*\bPAC\b' <<<"${notes}" && have+=(pac)
  echo "${have[*]}"
}

# liborc with userspace/orc/patches/ applied, for arm64, into OUT_DIR/orc. No
# root. Cross on any other host, native on aarch64. What lands in OUT_DIR/orc:
# liborc-0.4.so.0.41.0 (+ the liborc-0.4.so.0 link), COPYING, the applied
# patches and ORC-ID; the image stage installs it under /usr/local, which ld.so
# searches before /usr/lib.
#
# BUILT LIKE DEBIAN'S PACKAGE, because it replaces Debian's library for every
# process that loads it, a JIT among them: a build with weaker defaults would be
# a silent step back. So the flags are the ones Debian's arm64 build of this
# package gets -- dpkg-buildflags for arm64 with what debian/rules adds
# (hardening=+all, -Wl,-O1 -Wl,-z,defs) -- and meson runs as debhelper runs it
# at compat 13: --buildtype=plain, so the optimisation is the -O2 in CFLAGS, in
# obj-aarch64-linux-gnu inside the source tree. The result is stripped as
# dh_strip strips a shared library. What that must leave in the ELF is checked
# (orc_hardening); the flags alone are only a promise.
#
# THE FIX IS CHECKED BY BEHAVIOUR, not only by the patch stamp: the library is
# linked into userspace/orc/loadupdb-check.c and run, under qemu off an aarch64
# host. An unfixed liborc dies there with SIGSEGV.
stage_build_orc() {
  local dir="${WORK_DIR}/orc" tarball="${WORK_DIR}/${ORC_TARBALL}"
  local src="${WORK_DIR}/orc/src" dst="${OUT_DIR}/orc"
  local bld="${WORK_DIR}/orc/src/obj-aarch64-linux-gnu"
  local tc="" cross=() run=() t u p n f
  if [ "$(uname -m)" != aarch64 ]; then
    tc=aarch64-linux-gnu-
    run=(qemu-aarch64-static -L /usr/aarch64-linux-gnu)
  fi
  for t in "${tc}gcc" "${tc}strip" meson ninja patch readelf sha256sum dpkg-buildflags ${run[0]:+"${run[0]}"}; do
    command -v "${t}" >/dev/null \
      || die "build-orc needs '${t}' (trixie: meson ninja-build patch binutils dpkg-dev, and off aarch64 gcc-aarch64-linux-gnu libc6-dev-arm64-cross qemu-user-static)"
  done

  mkdir -p "${WORK_DIR}"
  fetch_verified "${ORC_SHA256}" "${tarball}" "${ORC_URLS[@]}"
  log "orc ${ORC_VERSION}: tarball sha256 verified"

  # The patches: content, count and order pinned (ORC_PATCH_SHA256), the order
  # read through the one series reader and compared with the pin.
  local pdir="${SRC}/userspace/orc/patches"
  ( cd "${pdir}" && printf '%s\n' "${ORC_PATCH_SHA256[@]}" | sha256sum -c --quiet - ) \
    || die "userspace/orc/patches: a patch differs from its pinned sha256 (ORC_PATCH_SHA256) -- a changed patch is a different artefact from the one measured"
  n="$(find "${pdir}" -name '*.patch' | wc -l)"
  [ "${n}" = "${#ORC_PATCH_SHA256[@]}" ] \
    || die "userspace/orc/patches holds ${n} patches, ${#ORC_PATCH_SHA256[@]} are pinned"
  series_load "${pdir}" || die "userspace/orc/patches/series is missing, empty or malformed"
  [ "$(printf '%s\n' "${SERIES[@]}")" = "$(printf '%s\n' "${ORC_PATCH_SHA256[@]}" | awk '{print $2}')" ] \
    || die "userspace/orc/patches/series does not list the pinned patches in the pinned order"

  rm -rf "${dir}"
  mkdir -p "${src}"
  tar -xf "${tarball}" -C "${src}" --strip-components=1 || die "unpacking ${ORC_TARBALL} failed"
  for p in "${SERIES[@]}"; do
    log "orc: applying ${p}"
    patch -d "${src}" -p1 --fuzz=0 --no-backup-if-mismatch < "${pdir}/${p}" \
      || die "orc: ${p} does not apply at --fuzz=0 to ${ORC_VERSION}"
  done

  # Debian's flags for this package on arm64, asked in the source directory as
  # dh asks, so -ffile-prefix-map maps it to ".". A clean environment: no
  # DEB_BUILD_OPTIONS (noopt, nostrip) or DEB_*FLAGS_* of the caller leaks in.
  local cflags cppflags ldflags
  for f in CFLAGS CPPFLAGS LDFLAGS; do
    t="$(cd "${src}" && env -i PATH="${PATH}" DEB_HOST_ARCH=arm64 \
           DEB_BUILD_MAINT_OPTIONS="${ORC_DEB_BUILD_MAINT_OPTIONS}" \
           DEB_LDFLAGS_MAINT_APPEND="${ORC_DEB_LDFLAGS_MAINT_APPEND}" \
           dpkg-buildflags --get "${f}")" || die "dpkg-buildflags --get ${f} failed"
    case "${f}" in CFLAGS) cflags="${t}" ;; CPPFLAGS) cppflags="${t}" ;; LDFLAGS) ldflags="${t}" ;; esac
  done
  for f in -O2 -fstack-protector-strong -fstack-clash-protection -mbranch-protection=standard; do
    [[ " ${cflags} " == *" ${f} "* ]] || die "orc: dpkg-buildflags gave CFLAGS without ${f} for arm64 (${cflags})"
  done
  [[ " ${cppflags} " == *" -D_FORTIFY_SOURCE="* ]] || die "orc: dpkg-buildflags gave CPPFLAGS without -D_FORTIFY_SOURCE (${cppflags})"
  for f in -Wl,-z,relro -Wl,-z,now; do
    [[ " ${ldflags} " == *" ${f} "* ]] || die "orc: dpkg-buildflags gave LDFLAGS without ${f} (${ldflags})"
  done
  log "orc: Debian's arm64 flags -- CPPFLAGS ${cppflags} | CFLAGS ${cflags} | LDFLAGS ${ldflags}"
  # meson takes them as array options: CPPFLAGS then CFLAGS into c_args, as
  # meson itself merges the environment. Split on blanks on purpose; no flag
  # dpkg-buildflags emits contains one.
  local cargs="" largs=""
  # shellcheck disable=SC2086
  for f in ${cppflags} ${cflags}; do cargs+="'${f}', "; done
  # shellcheck disable=SC2086
  for f in ${ldflags}; do largs+="'${f}', "; done

  if [ -n "${tc}" ]; then
    cat > "${dir}/aarch64-cross.ini" <<-'EOF'
	[binaries]
	c = 'aarch64-linux-gnu-gcc'
	ar = 'aarch64-linux-gnu-ar'
	strip = 'aarch64-linux-gnu-strip'

	[host_machine]
	system = 'linux'
	cpu_family = 'aarch64'
	cpu = 'aarch64'
	endian = 'little'
	EOF
    cross=(--cross-file "${dir}/aarch64-cross.ini")
  fi
  # The library and nothing else: no tools, tests, orc-test, examples or docs.
  env -u CFLAGS -u CPPFLAGS -u LDFLAGS meson setup "${bld}" "${src}" "${cross[@]}" \
      --buildtype=plain --wrap-mode=nodownload \
      -Dc_args="[${cargs%, }]" -Dc_link_args="[${largs%, }]" \
      -Dorc-test=disabled -Dtests=disabled -Dtools=disabled \
      -Dbenchmarks=disabled -Dexamples=disabled -Dgtk_doc=disabled \
    || die "orc: meson setup failed"
  ninja -C "${bld}" || die "orc: build failed"

  [ -f "${bld}/orc/${ORC_LIBFILE}" ] \
    || die "orc: ${ORC_LIBFILE} was not produced -- the version in its file name is the ABI Debian ships"
  rm -rf "${dst}"
  install -d -m0755 "${dst}/patches"
  install -m0644 "${bld}/orc/${ORC_LIBFILE}" "${dst}/"
  # dh_strip's command for a shared library (debhelper 13, dh_strip).
  "${tc}strip" --remove-section=.comment --remove-section=.note --strip-unneeded "${dst}/${ORC_LIBFILE}" \
    || die "orc: strip failed"
  ln -s "${ORC_LIBFILE}" "${dst}/${ORC_SONAME}"
  install -m0644 "${src}/COPYING" "${dst}/"
  for p in "${SERIES[@]}"; do install -m0644 "${pdir}/${p}" "${dst}/patches/"; done

  local lib="${dst}/${ORC_LIBFILE}" hdr hard
  hdr="$(readelf -h -d "${lib}")" || die "orc: readelf failed on ${lib}"
  grep -Eq 'Machine:[[:space:]]+AArch64' <<<"${hdr}" || die "orc: ${ORC_LIBFILE} is not an AArch64 ELF"
  grep -q "Library soname: \[${ORC_SONAME}\]" <<<"${hdr}" \
    || die "orc: ${ORC_LIBFILE} does not carry the soname ${ORC_SONAME}"
  hard="$(orc_hardening "${lib}")" || die "orc: readelf failed on ${lib}"
  [ "${hard}" = "relro bindnow stack-protector fortify bti pac" ] \
    || die "orc: ${ORC_LIBFILE} lacks hardening Debian's liborc has -- found '${hard}', want 'relro bindnow stack-protector fortify bti pac'"

  # The fix, by behaviour: a row that ends at an unmapped page, NEON JIT on.
  local chk="${dir}/orc-loadupdb-check" out rc=0
  "${tc}gcc" -O2 -Wall -Werror -I "${src}" -o "${chk}" "${SRC}/userspace/orc/loadupdb-check.c" "${lib}" \
    || die "orc: building userspace/orc/loadupdb-check.c failed"
  out="$(env -u ORC_CODE -u ORC_DEBUG LD_LIBRARY_PATH="${dst}" "${run[@]}" "${chk}" 2>&1)" || rc=$?
  [ "${rc}" = 0 ] && [ "${out}" = "ok, target neon" ] \
    || die "orc: ${ORC_LIBFILE} fails the loadupdb check (rc ${rc}, 139 = SIGSEGV = the overread is still there): ${out}"

  local sum; sum="$(sha256sum "${lib}" | cut -d' ' -f1)"
  {
    echo "version=${ORC_VERSION}"
    echo "debian_source=${ORC_DEBIAN_VERSION}"
    echo "source_sha256=${ORC_SHA256}"
    printf '%s\n' "${ORC_PATCH_SHA256[@]}" | awk '{print "patch=" $2 " " $1}'
    echo "build=Debian's arm64 flags (dpkg-buildflags, ${ORC_DEB_BUILD_MAINT_OPTIONS}), meson plain, stripped as dh_strip"
    echo "hardening=${hard}"
    echo "loadupdb_check=${out}"
    echo "lib=${ORC_LIBFILE}"
    echo "lib_sha256=${sum}"
  } > "${dst}/ORC-ID"
  chmod 0644 "${dst}/ORC-ID"

  log "orc ${ORC_VERSION} + ${#SERIES[@]} patch(es) -> ${dst}/${ORC_LIBFILE}, sha256 ${sum} ($("${tc}gcc" -dumpfullversion), meson $(meson --version))"
  log "orc: hardening ${hard} (as Debian's liborc); loadupdb check: ${out}"
}

# --- xfwm4: Debian's source, patches-xfwm4/ on top, built as Debian's package ---

# The XFWM4_FIX_SYMBOLS an ELF does not import, space separated, empty = it
# carries the fix. The table is read once into a variable, not piped into
# `grep -q`, which under pipefail is a race and not a test.

# Group stage run by the full chain (inner.sh all).
stage_orc() { stage_build_orc; }
