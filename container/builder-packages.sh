#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only OR MIT
#
# Package handling of the builder image, shared by the Containerfile and by
# the maintainers' lock maintenance. Runs inside a container from the pinned base image.
#
#   builder-packages.sh install <dir>
#       (Containerfile) point APT at the snapshot recorded in <dir>/packages.lock,
#       install exactly the locked package set for this architecture, and fail
#       unless the installed set equals the lock afterwards.
#   builder-packages.sh resolve <dir> <snapshot> <workdir> [<arch>...]
#       (maintainers' lock update; not part of a normal build) resolve the union of <dir>/packages.d/*.txt against
#       <snapshot> for every builder architecture, starting from that
#       architecture's base-image package database <workdir>/status.<arch>, and
#       print the new lock on stdout. Resolution only: nothing is installed, and
#       no foreign program runs, so one host can lock both architectures.
set -euo pipefail

BUILDER_ARCHES=(amd64 arm64)

die() { printf '::error:: %s\n' "$*" >&2; exit 1; }

# Foreign architectures a builder of <arch> carries (cross builds for the board).
extra_arches() { [ "$1" = amd64 ] && echo arm64 || true; }

# APT sources for one snapshot.debian.org timestamp. Plain http: every index is
# checked against the archive's signed InRelease, and the base image has no CA
# certificates yet. Check-Valid-Until is off because a snapshot's suites with a
# Valid-Until (updates, backports, security) expire a week after the timestamp.
write_sources() {  # <snapshot> <file>
  cat > "$2" <<EOF
Types: deb
URIs: http://snapshot.debian.org/archive/debian/$1
Suites: trixie trixie-updates trixie-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp
Check-Valid-Until: no

Types: deb
URIs: http://snapshot.debian.org/archive/debian-security/$1
Suites: trixie-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp
Check-Valid-Until: no
EOF
}

# The package names packages.d asks for on a builder of <arch>, one per line.
want_list() {  # <dir> <arch>
  local f
  for f in "$1"/packages.d/*.txt; do
    [ -e "${f}" ] || continue
    sed 's/#.*//' "${f}"
  done | awk -v a="$2" '
    NF == 0 { next }
    NF == 1 { print $1; next }
    NF == 2 && $2 ~ /^\[[a-z0-9 ]+\]$/ {
      gsub(/[][]/, "", $2); if ($2 == a) print $1; next }
    { printf "bad line in packages.d: %s\n", $0 > "/dev/stderr"; exit 1 }' | sort -u
}

lock_snapshot() {  # <dir>
  sed -n 's/^# snapshot \([0-9]\{8\}T[0-9]\{6\}Z\)$/\1/p' "$1/packages.lock"
}

# Installed packages of a dpkg database as name:arch=version, sorted.
installed_set() {  # [<admindir>]
  dpkg-query ${1:+--admindir="$1"} -W -f='${db:Status-Abbrev}|${Package}:${Architecture}=${Version}\n' \
    | sed -n 's/^ii *|//p' | LC_ALL=C sort
}

apt_conf() {
  cat > /etc/apt/apt.conf.d/80a7s-builder <<'EOF'
Acquire::Retries "5";
Acquire::Languages "none";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF
}

cmd_install() {
  local dir="$1" arch ts a want missing lockset
  arch="$(dpkg --print-architecture)"
  case " ${BUILDER_ARCHES[*]} " in *" ${arch} "*) ;; *) die "unsupported builder architecture ${arch}" ;; esac
  ts="$(lock_snapshot "${dir}")"
  [ -n "${ts}" ] || die "packages.lock names no snapshot"
  lockset="$(sed -n "s/^${arch} //p" "${dir}/packages.lock" | LC_ALL=C sort)"
  [ -n "${lockset}" ] || die "packages.lock has no entries for ${arch} -- the lock needs a maintainer update"

  # Every requested package must be in the lock, or the lock is stale.
  want="$(want_list "${dir}" "${arch}")"
  missing=""
  while read -r a; do
    [ -n "${a}" ] || continue
    case "${a}" in
      *:*) grep -qx "${a}=.*" <<<"${lockset}" || missing="${missing} ${a}" ;;
      *)   grep -q "^${a}:[a-z0-9]*=" <<<"${lockset}" || missing="${missing} ${a}" ;;
    esac
  done <<<"${want}"
  [ -z "${missing}" ] || die "not in container/packages.lock:${missing} -- the maintainers must update the lock after a change to packages.d"

  rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
  write_sources "${ts}" /etc/apt/sources.list.d/snapshot.sources
  apt_conf
  for a in $(extra_arches "${arch}"); do dpkg --add-architecture "${a}"; done
  apt-get update -qq

  # Install what the base image does not already have at the locked version.
  # Arch-independent packages are named without :all.
  local todo
  todo="$(LC_ALL=C comm -13 <(installed_set) <(printf '%s\n' "${lockset}") | sed 's/:all=/=/')"
  if [ -n "${todo}" ]; then
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends --allow-downgrades ${todo}
  fi

  if ! diff -u <(printf '%s\n' "${lockset}") <(installed_set) > /tmp/lockdiff; then
    cat /tmp/lockdiff >&2
    die "the installed package set differs from container/packages.lock (diff above: - lock, + installed)"
  fi
  printf '%s packages installed exactly as locked (%s, snapshot %s)\n' \
    "$(grep -c . <<<"${lockset}")" "${arch}" "${ts}"

  apt-get clean
  rm -rf /var/lib/apt/lists/* /var/log/apt /var/log/dpkg.log /var/log/alternatives.log \
         /var/cache/debconf/*-old /var/lib/dpkg/*-old /tmp/lockdiff
}

cmd_resolve() {
  local dir="$1" ts="$2" wd="$3" arch a d sim
  local arches=("${@:4}")
  [ "${#arches[@]}" -gt 0 ] || arches=("${BUILDER_ARCHES[@]}")
  rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
  write_sources "${ts}" /etc/apt/sources.list.d/snapshot.sources
  apt_conf
  for arch in "${arches[@]}"; do
    d="${wd}/apt-${arch}"
    rm -rf "${d}"
    mkdir -p "${d}/admin/updates" "${d}/admin/info" "${d}/lists/partial" "${d}/cache/archives/partial"
    cp "${wd}/status.${arch}" "${d}/admin/status"
    local opts=(-o "APT::Architecture=${arch}" -o "APT::Architectures::=${arch}"
                -o "Dir::State::status=${d}/admin/status" -o "Dir::State::Lists=${d}/lists"
                -o "Dir::Cache=${d}/cache" -o "Debug::NoLocking=1"
                -o "APT::Sandbox::User=root")
    for a in $(extra_arches "${arch}"); do opts+=(-o "APT::Architectures::=${a}"); done
    apt-get "${opts[@]}" update -qq >&2
    # shellcheck disable=SC2046
    sim="$(apt-get "${opts[@]}" -s install --no-install-recommends $(want_list "${dir}" "${arch}"))" \
      || die "apt cannot resolve the ${arch} builder package set against ${ts}"
    ! grep -q '^Remv ' <<<"${sim}" || die "resolving for ${arch} would remove packages: $(grep '^Remv ' <<<"${sim}" | tr '\n' ';')"
    {
      installed_set "${d}/admin" | sed 's/^/base /'
      # Inst <name>[:<arch>] [<old version>] (<version> <origins> [<arch>])
      awk '/^Inst / {
             name = $2; sub(/:.*/, "", name)
             i = 3; if ($i ~ /^\[/) i++
             ver = $i; sub(/^\(/, "", ver)
             # the architecture closes the parenthesis; a trailing "[]" may follow
             if (!match($0, /\[[a-z0-9]+\]\)/)) { print "unparsed: " $0 > "/dev/stderr"; exit 1 }
             arch = substr($0, RSTART + 1, RLENGTH - 3)
             print "inst " name ":" arch "=" ver }' <<<"${sim}"
    } | awk -v b="${arch}" '
          { split($2, kv, "="); key = kv[1]; val[key] = $2 }
          END { for (k in val) print b " " val[k] }' | LC_ALL=C sort
  done
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  resolve) shift; cmd_resolve "$@" ;;
  *) die "usage: $0 install <dir> | resolve <dir> <snapshot> <workdir> [<arch>...]" ;;
esac
