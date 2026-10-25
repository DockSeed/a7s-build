# Reproducibility

Two builds of the same commit on the same host architecture give the same
bytes. Known exceptions are listed below.

Checked on 2026-10-04: the desktop image of the first commit, built from a
fresh clone with the same switches on Fedora 44 and on SteamOS 3.8 (both
x86_64, rootless podman 5.8 and 5.5), came out the same to the byte.

Checked on 2026-10-25: the minimal image of commit `165c0e0`, built twice
from fresh clones on each host architecture, came out the same to the byte
per architecture. sha256 of `a7s-debian-trixie-minimal.img.xz`:

| Host | sha256 |
|---|---|
| x86_64, Fedora 44, rootless podman 5.8 | `330cfb393112f570e526d60a1e1bc50add5ac48b8e6eafb00901d2a4c28f3e5b` |
| aarch64, Debian 13, rootless podman 5.4 | `07227f22a3ec51879148ee77dc08e977de226b4280ce6b49033b84446640615e` |

## What is pinned

| Input | Pinned by | Checked |
|---|---|---|
| Builder base image | digest of the Debian `trixie` multi-arch index in `container/Containerfile` | by the engine on pull |
| Builder packages | `container/packages.lock`: one snapshot.debian.org timestamp and the exact `name:arch=version` of every package, both architectures | image build fails unless the installed set equals the lock |
| Builder package list | `container/packages.d/*.txt` | image build fails while a package is not in the lock |
| Root filesystem packages | `A7S_SNAPSHOT` (APT sources point at that snapshot) | APT, against the signed `InRelease` |
| Downloaded files | sha256 in the repository, `fetch_verified` | before entering the cache and on every use |
| Git sources | full commit id, `git_fetch_pinned` | git checks every object; `HEAD` is compared with the pin |
| Time stamps | `SOURCE_DATE_EPOCH` = commit time of `HEAD` (`A7S_SOURCE_DATE_EPOCH` overrides) | exported to every stage (the kernel takes the commit time of its own recipe); a time in the future is refused, because file times are only clamped downwards |
| Build identity | `A7S_BUILD_COMMIT` = `HEAD` id, `-dirty` if modified | stamped into the image |

A mirror (`A7S_DOWNLOAD_MIRROR`) and the cache are only places to look; a
mismatch with the pinned sha256 is discarded. The build never sees the host
environment (only the switches in `config/defaults.conf`); locale `C.UTF-8`,
time zone `UTC`.

## Not bit-identical

- **The builder image itself** (layers carry write times); its package set is
  checked on every build, and nothing the stages produce depends on it.
- **`A7S_SNAPSHOT=` empty** (live archive).
- **Different host architectures.** The kernel records the compiler's name
  (`aarch64-linux-gnu-gcc` on x86_64, `gcc` on aarch64) in
  `CONFIG_CC_VERSION_TEXT`, and the debug info of `xor-neon.ko` and
  `raid6_pq.ko` holds the path of the compiler's `arm_neon.h`, which differs
  between the cross and the native compiler.
- **A modified tree** (marked `-dirty`, builds from the changed files).

## Moving a pin

- **Image packages:** change `A7S_SNAPSHOT` in `config/defaults.conf`.
- **Builder packages and base image:** pinned in `container/packages.lock` and
  the `FROM` line of `container/Containerfile`; the maintainers move them.
  The lock is one `<builder arch> <package>:<arch>=<version>` line per package; the
  image build refuses any installed set that differs from it.
