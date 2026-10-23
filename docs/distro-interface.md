# The distro interface

The image has two halves:

- the **root filesystem** comes from `scripts/distro/<name>/`, picked with
  `A7S_DISTRO` (only `debian` exists);
- **everything else** (kernel, modules, firmware, `/boot`, `/etc/fstab`,
  partition table, boot chain) comes from `scripts/stages/image.sh`, which
  knows nothing about any distro.

A new distro is a new directory that keeps this contract.

## `scripts/distro/<name>/distro.sh` defines

| Name | Contract |
|---|---|
| `DISTRO_NAME`, `DISTRO_RELEASE` | used in the image name |
| `distro_rootfs_inputs` | prints everything the root filesystem is made from (own files by content, package source and timestamp, switches, sha256 of every `OUT_DIR` file it installs); the `rootfs` stage reuses a tree only while this is unchanged |
| `distro_rootfs_build <dir>` | builds the complete root filesystem into `<dir>` |
| `distro_rootfs_assert <dir>` | fails (`die`) when the tree breaks a rule below; also run on the finished image tree |

Every `*.sh` in the directory is sourced at start-up: define functions and
variables only. Programs that are run (hooks) must not end in `.sh`.
Available: everything `scripts/lib/common.sh` exports (`SRC` read-only,
`WORK_DIR`, `OUT_DIR`, `CACHE_DIR`, `SOURCE_DATE_EPOCH`, `A7S_*`, `log`,
`warn`, `die`, `fetch_verified`). Build tools go into
`container/packages.d/<name>.txt`.

## The build environment

- uid 0 of a user namespace: no `mknod`, no loop devices, no fresh `proc` or
  `sysfs` mount. Use `mount --rbind /proc|/sys|/dev <dir>/…`; `tmpfs` and
  `devpts` work.
- arm64 programs run through a private qemu binfmt handler: `chroot <dir> …`
  works.
- Downloads only from signed archives or against a sha256 in the repo.
- Files from `OUT_DIR` may belong to uid 0 or to the host user: install them
  with `install` / `cp --no-preserve=ownership` or chown them.

## The root filesystem must

1. boot with `root=PARTUUID=… rootwait rw console=ttyS0,115200` and no initrd,
   with a login on `ttyS0`;
2. feed the hardware watchdog from PID 1 (at least every 16 s);
3. clear the boot counter once a boot is good: write `0` to physical address
   `0x0709011C` (RTC `GP_DATA_REG7`), unless `a7s.fallback` is on the kernel
   command line — otherwise every board ends in safe mode after three boots;
4. grow the root partition to the end of the card on first boot;
5. ship no password: root locked, the user account without a usable password
   until its owner sets one on the console, no autologin, no network login
   before that;
6. ship no per-board identity: no SSH host keys, empty or no
   `/etc/machine-id`, no D-Bus machine ID, no NVMe host NQN/ID, no random
   seed, no network profile;
7. fetch updates from the distro's public archive (not the build snapshot);
8. carry no logs, caches, package lists, or builder data (hostname, resolver,
   file owners) — the content must be the same in every build. File times
   need no care: the image stage clamps them.

## The root filesystem must not write

`/boot/`, `/usr/lib/modules/`, `/usr/lib/firmware/{aic8800D80,powervr}/`,
`/etc/modprobe.d/aic8800-keep-cfg80211.conf`, `/etc/fstab`. The image stage
writes these. `/lib` may be a link to `usr/lib`.

## Adding a distro

1. `scripts/distro/<name>/distro.sh` with the four names above.
2. `container/packages.d/<name>.txt`; the maintainers then update
   `container/packages.lock` (the image build refuses a package that is not in it).
3. `A7S_DISTRO=<name> ./build.sh rootfs image`, twice; compare the sha256.
