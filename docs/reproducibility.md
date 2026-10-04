# Reproducibility

Two builds of the same commit on the same host architecture give the same
bytes. Known exceptions are listed below.

## What is pinned

| Input | Pinned by | Checked |
|---|---|---|
| Builder base image | digest of the Debian `trixie` multi-arch index in `container/Containerfile` | by the engine on pull |
| Builder packages | `container/packages.lock`: one snapshot.debian.org timestamp and the exact `name:arch=version` of every package, both architectures | image build fails unless the installed set equals the lock |
| Builder package list | `container/packages.d/*.txt` | image build fails while a package is not in the lock |
| Root filesystem packages | `A7S_SNAPSHOT` (APT sources point at that snapshot) | APT, against the signed `InRelease` |
| Downloaded files | sha256 in the repository, `fetch_verified` | before entering the cache and on every use |
| Git sources | full commit id, `git_fetch_pinned` | git checks every object; `HEAD` is compared with the pin |
| Time stamps | `SOURCE_DATE_EPOCH` = commit time of `HEAD` (`A7S_SOURCE_DATE_EPOCH` overrides) | exported to every stage |
| Build identity | `A7S_BUILD_COMMIT` = `HEAD` id, `-dirty` if modified | stamped into the image |

A mirror (`A7S_DOWNLOAD_MIRROR`) and the cache are only places to look; a
mismatch with the pinned sha256 is discarded. The build never sees the host
environment (only the switches in `config/defaults.conf`); locale `C.UTF-8`,
time zone `UTC`.

## Not bit-identical

- **The builder image itself** (layers carry write times); its package set is
  checked on every build, and nothing the stages produce depends on it.
- **`A7S_SNAPSHOT=` empty** (live archive).
- **A modified tree** (marked `-dirty`, builds from the changed files).

## Moving a pin

- **Image packages:** change `A7S_SNAPSHOT` in `config/defaults.conf`.
- **Builder packages and base image:** pinned in `container/packages.lock` and
  the `FROM` line of `container/Containerfile`; the maintainers move them.
  The lock is one `<builder arch> <package>:<arch>=<version>` line per package; the
  image build refuses any installed set that differs from it.
