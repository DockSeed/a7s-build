# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# Boot-chain stages: bootchain (= fetch-bootchain + build-bootchain),
# fetch-bootchain, build-bootchain, bootchain-key. Sourced by scripts/inner.sh
# after scripts/lib/common.sh; defines functions and pins only.
#
# This repository holds no boot-chain source. The chain (U-Boot SPL with the
# vendor DRAM blob, BL31 built from TF-A, U-Boot, packed into one
# u-boot-sunxi-with-spl.bin) is the stand-alone recipe a733-bootchain, pinned
# here to a commit. docs/bootchain.md says what it builds.
#
# Output: OUT_DIR/bootchain/{u-boot-sunxi-with-spl.bin,BOOTCHAIN-ID} and, beside
# them, licences/: the licence texts, copyright lines and source commits of what
# the file holds (U-Boot, TF-A), taken from the built trees for the image's
# copyright file.

# The recipe, pinned to a COMMIT (main moves). To bump it: build,
# compare the sha256 in docs/bootchain.md, test on a board, then change it here.
BOOTCHAIN_URL="https://github.com/DockSeed/a733-bootchain.git"
BOOTCHAIN_COMMIT="797a561442a471d67985474fed440ed1dce18fa3"

# Where the pinned recipe is checked out; its own work tree (the U-Boot package
# clone) lives beside it in WORK_DIR.
bootchain_dir() { printf '%s\n' "${WORK_DIR}/a733-bootchain"; }

pins_bootchain() {
  log "bootchain: ${BOOTCHAIN_URL} @ ${BOOTCHAIN_COMMIT} (its own pins: build.sh pins in that checkout)"
}

# Fetch the recipe at the pinned commit (git_fetch_pinned proves HEAD).
stage_fetch_bootchain() {
  git_fetch_pinned "${BOOTCHAIN_URL}" "${BOOTCHAIN_COMMIT}" "$(bootchain_dir)"
}

# The recipe's own key (upstream commit + overlay hash), a function of the
# checkout alone. Needs the checkout.
stage_bootchain_key() {
  local dir; dir="$(bootchain_dir)"
  [ -x "${dir}/scripts/build.sh" ] || die "boot chain recipe missing -- run fetch-bootchain first"
  "${dir}/scripts/build.sh" key
}

# Run the recipe's scripts/build.sh (the stage that runs in its own container)
# here, in this builder: it needs the packages of container/packages.d/bootchain.txt,
# which the recipe lists in its container/packages.txt. It fetches U-Boot and
# TF-A itself, builds, asserts, and writes OUT_DIR/bootchain/. Its SOURCE_DATE_EPOCH
# is derived from the pinned package commit and replaces any ambient value.
stage_build_bootchain() {
  local dir; dir="$(bootchain_dir)"
  [ -x "${dir}/scripts/build.sh" ] || die "boot chain recipe missing -- run fetch-bootchain first"
  [ "$(git -C "${dir}" rev-parse HEAD 2>/dev/null)" = "${BOOTCHAIN_COMMIT}" ] \
    || die "${dir} is not at ${BOOTCHAIN_COMMIT} -- run fetch-bootchain again"
  WORK_DIR="${WORK_DIR}" OUT_DIR="${OUT_DIR}" "${dir}/scripts/build.sh" all \
    || die "build-bootchain failed (reason above)"
  bootchain_collect_licences
}

# The sources the chain was built from are the ones that carry its licence
# texts and copyright notices. Copied beside the chain, so the image stage needs
# neither the work tree nor the network:
#   SOURCES            recipe, package, U-Boot and TF-A commits as built
#   COPYING.u-boot     U-Boot's COPYING (the GPL-2 text), and Licenses/ (the
#                      texts it refers to, and Licenses/README, U-Boot's own
#                      statement)
#   tf-a-license.rst   TF-A's docs/license.rst (BSD-3-Clause and the list of the
#                      other licences inside it)
#   tf-a-files         the TF-A sources that go into BL31 (below)
#   tf-a-copyright     their copyright lines, sorted and without duplicates
#   tf-a-other/        one record per source whose licence is not TF-A's
#                      BSD-3-Clause text, with the text where the file has it
#   tf-a-no-notice     sources that carry no copyright line
# The recipe builds in ${WORK_DIR}/u-boot-dlan17 (U-Boot in src/, TF-A in atf/).
BOOTCHAIN_TFA_BUILD="build/sun60i_a733/release"

# The TF-A source files BL31 is made of, from the link map and the dependency
# files the compiler wrote beside the objects: the objects the linker took, and
# the members of the libraries (libc, libfdt, ...) that contribute bytes.
# Run in atf/. Prints paths relative to it, sorted.
bootchain_tfa_sources() {
  local b="${BOOTCHAIN_TFA_BUILD}" map d
  local -
  set -o pipefail
  map="${b}/bl31/bl31.map"
  [ -s "${map}" ] || die "boot chain: no ${PWD}/${map} -- the licence notices of BL31 are collected from its link map"
  {
    sed -n 's|^LOAD .*/release/\(.*\)\.o$|\1.d|p' "${map}"
    grep -E '\.a\([^)]*\)$' "${map}" | grep -vE ' 0x0+ ' \
      | sed -n 's|.*/release/lib/\(lib[a-z_]*\)\.a(\(.*\)\.o)$|\1/\2.d|p'
  } | LC_ALL=C sort -u | while IFS= read -r d; do
    [ -f "${b}/${d}" ] || die "boot chain: ${PWD}/${b}/${d} (named in the link map) does not exist"
    sed -e 's/\\$//' "${b}/${d}" | tr -s ' \t' '\n\n'
  done | grep -vE '(^$|:$|^/)' | LC_ALL=C sort -u | while IFS= read -r d; do
    [ -f "${d}" ] || die "boot chain: ${PWD}/${d} (named in a dependency file) does not exist"
    printf '%s\n' "${d}"
  done
}

# The copyright lines of the files given on stdin (one path per line). A line
# that ends after the years carries its holder on the next one ("Copyright (c)
# 1988, 1993 / The Regents of the University of California"); both are kept.
bootchain_copyright_lines() {
  local f
  while IFS= read -r f; do
    awk '
      function clean(s) { sub(/^[ \t\/*#-]+/, "", s); sub(/[ \t]+$/, "", s); return s }
      join { print prev " " clean($0); join = 0; next }
      /[Cc]opyright +(\([cC]\) *)?[0-9][0-9][0-9][0-9]/ || /^[ \t\/*#-]*\([cC]\) [A-Z]/ {
        prev = clean($0)
        if (prev ~ /[0-9,-]$/) { join = 1; next }
        print prev
      }' "${f}"
  done | LC_ALL=C sort -u
}

# Run in atf/. A source is "other" when its licence is not the BSD-3-Clause text
# of TF-A: it carries a text of its own (errno.h, uuid.h, strlcpy.c ...), or it
# is dual licensed and used under BSD-2-Clause (libfdt). Anything else with an
# SPDX identifier that is not BSD-3-Clause stops the stage, so that a new pin
# cannot bring a licence in unseen.
bootchain_tfa_notices() {  # <out>
  local out="$1" f spdx n=0 std="$1/std.tmp" rec own
  bootchain_tfa_sources > "${out}/tf-a-files" || return 1
  [ "$(wc -l < "${out}/tf-a-files")" -gt 100 ] || { echo "::error:: fewer than 100 sources of BL31 found" >&2; return 1; }
  install -d -m0755 "${out}/tf-a-other"
  : > "${std}"; : > "${out}/tf-a-no-notice"
  while IFS= read -r f; do
    spdx="$(sed -n '1,40s/.*SPDX-License-Identifier: *\(.*[^ */]\)[ */]*$/\1/p' "${f}" | head -1)"
    own=""
    if grep -qE 'Redistribution and use|Permission to use, copy' "${f}"; then
      own=text
    else
      case "${spdx}" in
        BSD-3-Clause|"") ;;
        "(GPL-2.0-or-later OR BSD-2-Clause)") own=ref ;;
        *) echo "::error:: ${f} is under '${spdx}', which this stage does not know -- extend bootchain_tfa_notices" >&2; return 1 ;;
      esac
    fi
    if [ -z "${own}" ]; then
      printf '%s\n' "${f}" >> "${std}"
      grep -qE '[Cc]opyright +(\([cC]\) *)?[0-9]{4}' "${f}" || printf '%s\n' "${f}" >> "${out}/tf-a-no-notice"
      continue
    fi
    n=$(( n + 1 )); rec="${out}/tf-a-other/$(printf '%02d' "${n}")"
    {
      echo "path=${f}"
      echo "spdx=${spdx}"
      printf '%s\n' "${f}" | bootchain_copyright_lines | sed 's/^/copyright=/'
      echo "--"
      if [ "${own}" = text ]; then
        sed -n '/Redistribution and use\|Permission to use, copy/,/SUCH DAMAGE\|PERFORMANCE OF THIS SOFTWARE/p' "${f}" \
          | sed -E 's/^[[:space:]]*(\/\*-?|\*)[[:space:]]?//; s/[[:space:]]+$//'
      fi
    } > "${rec}" || return 1
  done < "${out}/tf-a-files"
  bootchain_copyright_lines < "${std}" > "${out}/tf-a-copyright" && rm -f "${std}"
}

bootchain_collect_licences() {
  local tree="${WORK_DIR}/u-boot-dlan17" out="${OUT_DIR}/bootchain/licences" f n
  for f in src/COPYING src/Licenses/gpl-2.0.txt src/Licenses/README src/Licenses/bsd-2-clause.txt atf/docs/license.rst; do
    [ -s "${tree}/${f}" ] || die "boot chain: ${tree}/${f} missing -- its licence text cannot be collected"
  done
  rm -rf "${out}"
  install -d -m0755 "${out}"
  cp "${tree}/src/COPYING" "${out}/COPYING.u-boot"
  cp -r "${tree}/src/Licenses" "${out}/Licenses"
  cp "${tree}/atf/docs/license.rst" "${out}/tf-a-license.rst"
  {
    echo "recipe=${BOOTCHAIN_COMMIT}"
    echo "package=$(git -C "${tree}" rev-parse HEAD)"
    echo "u-boot=$(git -C "${tree}/src" rev-parse HEAD)"
    echo "tf-a=$(git -C "${tree}/atf" rev-parse HEAD)"
  } > "${out}/SOURCES" || die "boot chain: cannot write ${out}/SOURCES"
  # BL31's sources and their notices, read in atf/.
  ( cd "${tree}/atf" && bootchain_tfa_notices "${out}" ) || die "boot chain: cannot collect the notices of BL31"
  bootchain_licences_check "${out}"
  log "boot chain licences: $(tr '\n' ' ' < "${out}/SOURCES")"
  n="$(find "${out}/tf-a-other" -type f | wc -l)"
  log "BL31: $(wc -l < "${out}/tf-a-files") sources, $(wc -l < "${out}/tf-a-copyright") copyright lines, ${n} under their own licence, $(wc -l < "${out}/tf-a-no-notice") without a notice"
}

# The licence directory is complete, and its commits are the pinned ones:
# the package is BOOTCHAIN-ID's upstream=, U-Boot is the submodule pin in
# BOOTCHAIN-ID's submodules=, TF-A is ATF_BASE of the recipe.
bootchain_licences_check() {  # <dir>
  local out="$1" k v id="${OUT_DIR}/bootchain/BOOTCHAIN-ID" atf
  for k in COPYING.u-boot Licenses/gpl-2.0.txt Licenses/README Licenses/bsd-2-clause.txt tf-a-license.rst tf-a-files tf-a-copyright SOURCES; do
    [ -s "${out}/${k}" ] || die "boot chain: ${out}/${k} missing -- run the bootchain stage again"
  done
  [ -d "${out}/tf-a-other" ] && [ -f "${out}/tf-a-no-notice" ] \
    || die "boot chain: ${out} is incomplete -- run the bootchain stage again"
  for k in recipe package u-boot tf-a; do
    v="$(sed -n "s/^${k}=//p" "${out}/SOURCES")"
    case "${#v}" in 40|64) [ -z "${v//[0-9a-f]/}" ] ;; *) false ;; esac \
      || die "boot chain: ${out}/SOURCES has no commit for ${k}"
  done
  atf="$(sed -n 's/^ATF_BASE="\([0-9a-f]\{40\}\)".*/\1/p' "$(bootchain_dir)/overlay/apply.sh")"
  [ -n "${atf}" ] || die "boot chain: no ATF_BASE in $(bootchain_dir)/overlay/apply.sh"
  [ "$(sed -n 's/^recipe=//p' "${out}/SOURCES")" = "${BOOTCHAIN_COMMIT}" ] \
    && [ "$(sed -n 's/^package=//p' "${out}/SOURCES")" = "$(sed -n 's/^upstream=//p' "${id}")" ] \
    && [ "src:$(sed -n 's/^u-boot=//p' "${out}/SOURCES")" = "$(sed -n 's/^submodules=//p' "${id}")" ] \
    && [ "$(sed -n 's/^tf-a=//p' "${out}/SOURCES")" = "${atf}" ] \
    || die "boot chain: ${out}/SOURCES does not name the commits of the pinned recipe (package, U-Boot, TF-A) -- run the bootchain stage again"
  grep -q 'BSD-3-Clause' "${out}/tf-a-license.rst" && grep -q 'GNU GENERAL PUBLIC LICENSE' "${out}/COPYING.u-boot" \
    || die "boot chain: the collected licence texts are not TF-A's and U-Boot's"
}

# Used by the image stage: the chain in OUT_DIR/bootchain must come from the
# pinned recipe commit. BOOTCHAIN-ID carries `upstream=` and `overlay=`; the
# recipe's `key` is <upstream 12>-<overlay 12> of the checkout. Also sources the
# recipe's layout check, so the offsets have one source.
bootchain_verify_output() {
  local dir id key want
  dir="$(bootchain_dir)"; id="${OUT_DIR}/bootchain/BOOTCHAIN-ID"
  [ -s "${OUT_DIR}/bootchain/u-boot-sunxi-with-spl.bin" ] && [ -s "${id}" ] \
    || die "boot chain missing in ${OUT_DIR}/bootchain -- run the bootchain stage"
  [ -f "${dir}/scripts/lib/bootchain-layout.sh" ] \
    || die "boot chain recipe missing in ${dir} -- run fetch-bootchain"
  [ "$(git -C "${dir}" rev-parse HEAD 2>/dev/null)" = "${BOOTCHAIN_COMMIT}" ] \
    || die "${dir} is not at ${BOOTCHAIN_COMMIT} -- run fetch-bootchain again"
  want="$("${dir}/scripts/build.sh" key)" || die "bootchain key failed"
  key="$(sed -n 's/^upstream=\(.\{12\}\).*/\1/p' "${id}")-$(sed -n 's/^overlay=\(.\{12\}\).*/\1/p' "${id}")"
  [ "${key}" = "${want}" ] \
    || die "the boot chain in ${OUT_DIR}/bootchain (${key}) was not built by the pinned recipe commit (${want}) -- run the bootchain stage again"
  # shellcheck source=/dev/null
  . "${dir}/scripts/lib/bootchain-layout.sh"
  bootchain_layout_check "${OUT_DIR}/bootchain/u-boot-sunxi-with-spl.bin" \
    || die "the boot chain does not fit the image layout (${dir}/scripts/lib/bootchain-layout.sh)"
  bootchain_licences_check "${OUT_DIR}/bootchain/licences"
}

# Group stage run by the full chain (inner.sh all).
stage_bootchain() { stage_fetch_bootchain && stage_build_bootchain; }
