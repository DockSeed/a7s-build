# SPDX-License-Identifier: GPL-2.0-only OR MIT
# shellcheck shell=bash
#
# The one reader of a patch `series` file. Sourced, never run. Every place that
# applies or checks a patch set goes through it: the kernel (apply-patches),
# aic8800 (fetch-wifi), U-Boot and TF-A (bootchain/overlay/apply.sh), ORC
# (build-orc) and xfwm4 (fetch-xfwm4).
#
# Why one reader: with a series file, "the file is there" does not mean "the
# file is applied". A line lost in a merge, a typo in a path or a new file
# nobody listed builds a tree without that patch and stays green. Several
# hand-written loops would drift apart on exactly those cases; one strict
# reader cannot.
#
# FORMAT (quilt-compatible, minus quilt's per-line options)
#   - one path per line, relative to the patch directory, ending in `.patch`;
#     subdirectories allowed (soc/clk/x.patch)
#   - a line that starts with `#` is a comment; an empty line is ignored
#   - `#test: <path>` is a comment to every applier, and names a patch that
#     lives in the directory ON PURPOSE without being applied; a checker can
#     count it as listed, so it is not an orphan; nothing ever applies it
#   - the last line may lack its newline
#
# REFUSED, never normalised (each is a line somebody meant differently):
#   CR (a CRLF file), leading or trailing blanks, an inline comment or quilt
#   option after the path, an absolute path, an empty, `.` or `..` component, a
#   name not ending in `.patch`, a path that is not a regular file, a path
#   listed twice (also between an entry and a `#test:` line), a missing series
#   file, a series with no entry.
#
# API
#   series_load <patch-dir> [<series-file>]
#       default series file: <patch-dir>/series. Fills the global arrays
#       SERIES (entries, in order) and SERIES_TEST (`#test:` paths). On any
#       refusal: one `::error::` line per problem on stderr, return 1.
#   series_resolve_skip <comma-separated tokens>
#       after series_load. A token is a series path (with or without `.patch`)
#       or a basename (with or without `.patch`) that exactly one entry has.
#       Compared as fixed strings. Fills the global associative array
#       SERIES_SKIP[<entry>]=<token>. Every token must hit exactly one entry and
#       no two tokens the same one; otherwise `::error::` and return 1.

series_load() {
  local dir="${1:?series_load: patch directory}" file="${2:-${1}/series}"
  SERIES=()
  SERIES_TEST=()
  if [ ! -f "${file}" ]; then
    echo "::error:: ${file}: series file missing" >&2
    return 1
  fi
  local line path n=0 bad=0 what
  local -A seen=()
  while IFS= read -r line || [ -n "${line}" ]; do
    n=$((n + 1))
    what=""
    case "${line}" in
      *$'\r'*) echo "::error:: ${file}:${n}: carriage return (CRLF file?)" >&2; bad=1; continue ;;
      '') continue ;;
      '#test: '*) path="${line#'#test: '}"; what="test" ;;
      '#'*) continue ;;
      *) path="${line}"; what="entry" ;;
    esac
    if ! series_path_ok "${dir}" "${path}" "${file}:${n}"; then
      bad=1; continue
    fi
    if [ -n "${seen[${path}]:-}" ]; then
      echo "::error:: ${file}:${n}: '${path}' listed twice (first on line ${seen[${path}]})" >&2
      bad=1; continue
    fi
    seen[${path}]=${n}
    if [ "${what}" = test ]; then SERIES_TEST+=("${path}"); else SERIES+=("${path}"); fi
  done < "${file}"
  if [ "${bad}" = 0 ] && [ "${#SERIES[@]}" -eq 0 ]; then
    echo "::error:: ${file}: no entry -- an empty series would apply nothing and still succeed" >&2
    bad=1
  fi
  [ "${bad}" = 0 ]
}

# series_path_ok <dir> <path> <where> -- one line's path, checked; errors to stderr.
series_path_ok() {
  local dir="$1" path="$2" where="$3" comp
  case "${path}" in
    *[[:space:]]*) echo "::error:: ${where}: blank inside or around '${path}' (no trimming, no inline comments, no quilt options)" >&2; return 1 ;;
    /*) echo "::error:: ${where}: absolute path '${path}'" >&2; return 1 ;;
    *.patch) ;;
    *) echo "::error:: ${where}: '${path}' does not end in .patch" >&2; return 1 ;;
  esac
  local -a comps
  IFS=/ read -r -a comps <<< "${path}"
  for comp in "${comps[@]}"; do
    case "${comp}" in
      ''|.|..) echo "::error:: ${where}: '${path}' has an empty, '.' or '..' component" >&2; return 1 ;;
    esac
  done
  case "${path}" in */) echo "::error:: ${where}: '${path}' ends in /" >&2; return 1 ;; esac
  case "${path}" in *//*) echo "::error:: ${where}: '${path}' has an empty component" >&2; return 1 ;; esac
  if [ ! -f "${dir}/${path}" ] || [ -L "${dir}/${path}" ]; then
    echo "::error:: ${where}: '${path}' is not a regular file under ${dir}" >&2
    return 1
  fi
  return 0
}

series_resolve_skip() {
  local tokens="$1" tok e hit bad=0
  local -a hits list
  declare -gA SERIES_SKIP=()
  IFS=, read -r -a list <<< "${tokens}"
  for tok in "${list[@]}"; do
    # Surrounding blanks are separators, not part of a name: no name has one.
    tok="${tok#"${tok%%[![:space:]]*}"}"; tok="${tok%"${tok##*[![:space:]]}"}"
    if [ -z "${tok}" ]; then
      echo "::error:: A7S_SKIP_PATCHES: empty token in '${tokens}'" >&2
      bad=1; continue
    fi
    hits=()
    for e in "${SERIES[@]}"; do
      if [ "${e}" = "${tok}" ] || [ "${e}" = "${tok}.patch" ] \
         || [ "${e##*/}" = "${tok}" ] || [ "${e##*/}" = "${tok}.patch" ]; then
        hits+=("${e}")
      fi
    done
    case "${#hits[@]}" in
      1) hit="${hits[0]}"
         if [ -n "${SERIES_SKIP[${hit}]:-}" ]; then
           echo "::error:: A7S_SKIP_PATCHES: '${tok}' and '${SERIES_SKIP[${hit}]}' both name ${hit}" >&2
           bad=1; continue
         fi
         SERIES_SKIP[${hit}]="${tok}" ;;
      0) case "${tok}" in
           [0-9][0-9][0-9][0-9])
             echo "::error:: A7S_SKIP_PATCHES: '${tok}' looks like a patch number; patches are named, pass the name" >&2 ;;
           *)
             echo "::error:: A7S_SKIP_PATCHES: '${tok}' names no series entry" >&2 ;;
         esac
         bad=1 ;;
      *) echo "::error:: A7S_SKIP_PATCHES: '${tok}' is ambiguous, it names ${#hits[@]} entries: ${hits[*]} -- pass the path" >&2
         bad=1 ;;
    esac
  done
  [ "${bad}" = 0 ]
}
