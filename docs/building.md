# Building the image

```sh
git clone <this repository> a7s-build
cd a7s-build
./build.sh            # = ./build.sh all
```

The result lands in `out/`. `./build.sh --help` lists every stage and switch.

## What the host needs

- x86_64 Linux (the boot-chain stage packs with `dragonsecboot`, an x86-64
  binary, and stops on any other host); bash, coreutils, git.
- **podman >= 4 or docker >= 24.** Tested: rootless podman 5.8; docker 29.8
  running inside a podman container (not yet on a real docker host).
- **Linux >= 6.7**, or a `qemu-aarch64` binfmt handler already
  registered on the host with the `F` flag (see [arm64 emulation](#arm64-emulation)).
- Network access to the public origins of the inputs (docker.io, snapshot.debian.org,
  cdn.kernel.org, github.com, ...). Everything is checked against a committed
  sha256 or commit id.
- Disk: about 20 GB free (work, out, cache, builder image). Measured pieces:
  kernel tree 2.7 GB, other stage work 8 GB, image 1.5 GB, cache about 1 GB.
- RAM: 8 GB is comfortable; lower `A7S_JOBS` on a small machine.
- Time: a first full build takes on the order of an hour on 4 cores (kernel
  compile, root filesystem under emulation); root filesystem plus image from a
  warm cache took about 5 minutes. Later builds reuse the cache.

## Usage

```
./build.sh [<stage>...]                run stages in order (default: all)
./build.sh shell [<cmd> [<arg>...]]    shell, or one command, in the builder
./build.sh --help                      stages and switches
```

| Stage | What it does |
|---|---|
| `all` | `bootchain kernel wifi gpu-firmware orc xfwm4 rootfs image compress`; `xfwm4` only with `A7S_DESKTOP=1` |
| `pins` | print every pinned input |
| `clean` | delete the work directory (from inside the container, which can delete files your user cannot) |

Other stages are `stage_<name>` functions in `scripts/stages/*.sh` or
`scripts/distro/<distro>/*.sh`. `./build.sh shell` gives the exact environment
the stages see.

## Switches

Environment variables, defaults in `config/defaults.conf` (printed by
`--help`). Only the switches listed there reach the container.

| Switch | Default | Meaning |
|---|---|---|
| `A7S_ENGINE` | podman, else docker | container engine (host only) |
| `A7S_WORK`, `A7S_OUT`, `A7S_CACHE` | `work`, `out`, `cache` | scratch, artefact and download-cache directories (host only); the cache can be shared between checkouts |
| `A7S_DISTRO` | `debian` | root filesystem flavour (`scripts/distro/<name>/`) |
| `A7S_SUITE` | `trixie` | Debian suite |
| `A7S_SNAPSHOT` | `20261002T000000Z` | snapshot.debian.org timestamp of the image's packages; empty = live archive, not reproducible |
| `A7S_DESKTOP` | `0` | `1`: Xfce desktop and patched xfwm4 |
| `A7S_USER`, `A7S_HOSTNAME` | `a7s`, `a7s` | login user and host name |
| `A7S_IMAGE_NAME` | `a7s-<distro>-<suite>-<minimal\|desktop>.img` | image file name |
| `A7S_IMAGE_SIZE_MB` | from the root filesystem | image size in MiB |
| `A7S_ROOTFS_REBUILD` | `0` | `1`: rebuild a cached root filesystem |
| `A7S_JOBS` | number of CPUs | parallel compile jobs |
| `A7S_DOWNLOAD_MIRROR` | empty | content-addressed mirror tried first (`<mirror>/<sha256>`); the pin still decides |
| `A7S_FETCH_MAX_TIME` | `3600` | seconds per download attempt |
| `A7S_SOURCE_DATE_EPOCH` | commit time of HEAD | `SOURCE_DATE_EPOCH` of every stage |
| `A7S_BUILD_COMMIT` | HEAD id (`-dirty` if modified) | build identity stamped into the image |

## Engines

`build.sh` builds the builder image from `container/` once and tags it
`localhost/a7s-builder:<hash of container/>`; an unchanged tree reuses it. The
repository is mounted read-only at `/src`; work, output and cache are mounted
read-write at `/work`, `/out`, `/cache`.

- **Rootless podman / docker:** the container's root is your user. Files the
  build creates for other users inside the root filesystem appear under a
  subordinate uid you cannot delete directly; `./build.sh clean` removes them.
- **Rootful docker / podman as root:** at the end of each run `out/` and
  `cache/` are handed back to the invoking user; `work/` keeps its owners
  (remove it with `./build.sh clean`).

The container runs with `--cap-add SYS_ADMIN` (user namespace and private
binfmt_misc, see below; confined to your user namespace under rootless
podman), `--security-opt label=disable` (use the bind mounts as they are on
SELinux hosts), `--security-opt apparmor=unconfined` (the default profile
forbids every mount) and `--init`. No `--privileged`, no host devices, no host
network. `build.sh` closes inherited file descriptors above stderr before
calling the engine, so locks held by the caller do not leak in.

## arm64 emulation

`scripts/inner.sh` runs the build in a child user namespace of the container.
On an x86_64 host it mounts a fresh binfmt_misc instance there and registers
the builder's `qemu-aarch64` with the `F` flag (works inside chroots without
qemu). Since Linux 6.7 that instance is private to the build and disappears
with it; the host's binfmt_misc and other containers are untouched. If the
private instance is impossible, an already active host `qemu-aarch64` handler
is used; otherwise the build stops. Fix with a kernel >= 6.7 or a one-time
registration:

```sh
sudo apt-get install qemu-user-static binfmt-support    # Debian, Ubuntu
sudo dnf install qemu-user-static-aarch64               # Fedora
sudo pacman -S qemu-user-static qemu-user-static-binfmt # Arch
```

Check what the build sees: `./build.sh shell cat /proc/sys/fs/binfmt_misc/qemu-aarch64`.

A handler left in rootless podman's shared namespace by something else
(`/proc/sys/fs/binfmt_misc/qemu-aarch64`) can be removed with:

```sh
podman run --rm --cap-add SYS_ADMIN --security-opt label=disable \
  docker.io/library/debian:trixie sh -c \
  'mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc &&
   echo -1 > /proc/sys/fs/binfmt_misc/qemu-aarch64'
```

## For stage authors

- Stages run as uid 0 of a user namespace: no `mknod`, no loop devices, no
  fresh `proc`/`sysfs` mount (bind them: `mount --rbind /proc <root>/proc`;
  detach with `umount --lazy`). `tmpfs`, `devpts`, bind mounts and `chroot`
  work; arm64 programs in an arm64 root run through the handler above.
- `TMPDIR` points into the work directory.
- Downloads: `fetch_verified <sha256> <dest> <url>...` or `fetch_cached`; git
  sources: `git_fetch_pinned <url> <commit> <dest>` (both in `scripts/lib/common.sh`).
- Builder packages are listed in `container/packages.d/<group>.txt` and pinned
  in `container/packages.lock`; the builder image refuses to build while a
  requested package is missing from the lock. See [reproducibility](reproducibility.md).
