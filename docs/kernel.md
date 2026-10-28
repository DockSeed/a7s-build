<!-- SPDX-License-Identifier: GPL-2.0-only OR MIT -->
# Kernel: Linux 6.18 LTS

The kernel is not built from source in this repository. It is the stand-alone
recipe [a7s-linux-lts](https://github.com/DockSeed/a7s-linux-lts), pinned here
to one commit (`KERNEL_RECIPE_COMMIT` in `scripts/stages/kernel.sh`):

| | |
|---|---|
| Repository | `https://github.com/DockSeed/a7s-linux-lts` |
| Pinned commit | `8b8606bebe63` |
| Result | `Image`, `sun60i-a733-cubie-a7s.dtb`, `config`, `System.map`, `modules/` (with aic8800), `KERNEL-ID` |

Changes to the series are made there only; here the pin moves. What the kernel
is made of (the pinned tarball, the patch series, the config, the checks after
the build) is described there (`docs/kernel.md`).

## Two sources for the image's kernel: `A7S_KERNEL`

| `A7S_KERNEL` | The image's kernel | The aic8800 driver |
|---|---|---|
| `build` (default) | built here from source by the recipe (`./build.sh kernel`), copied into the image | built by the recipe with the kernel, copied into the image |
| `release` | the Debian packages `linux-image` and `linux-headers` of a release of the recipe, downloaded and installed with dpkg | built by DKMS in the image, against the installed headers |

Stages: `fetch-kernel` (the recipe at the pin; with `release` also the
packages), `build-kernel` (the recipe's `all`; with `release` it checks the
packages), `kernel` (both), `compile-check` (the recipe's fast compile gate,
after a build), `kernel-key` (the recipe's key). Both sources need the recipe's
checkout: with `release`, the driver's patches come from it.

### `A7S_KERNEL=build`

`./build.sh kernel` fetches the recipe at the pin and runs its
`scripts/build.sh all` in the builder, with the kernel tree in the work
directory (`work/linux-<version>`), and writes the result to `out/`. The recipe
also builds the AIC8800 WLAN/BT driver against its kernel tree; the two modules
are in `out/modules/`, and `KERNEL-ID` names the driver's upstream commit
(`aic8800=`). `A7S_KERNEL_REVISION` (`r1`, `t2`, ...) gives the kernel a
revision as the recipe's release workflow does (kernel release `6.18.59-t2`);
empty, the kernel release is `6.18.59`.

The image stage takes `Image`, the dtb and `modules/` as they are. Before it
does, it checks that the `key=` field of `KERNEL-ID` is the key
(`scripts/build.sh key`) of the pinned checkout, that `Image` and the dtb match
the hashes in `KERNEL-ID`, that the kernel is not a variant build (developer
switches of the recipe set) and, when the firmware is present, that the driver
was built from the commit the firmware comes from. `/boot/Image` and
`/boot/sun60i-a733-cubie-a7s.dtb` are plain files, named in `extlinux.conf`.

The recipe takes its build time from its own commit, not from this repository:
the kernel does not change when only this repository does.

### `A7S_KERNEL=release`

The recipe's release workflow builds a tagged commit on GitHub and attaches the
result to a release. `scripts/stages/kernel.sh` pins one release:

| | |
|---|---|
| Release | `v6.18.59-T2` (kernel release `6.18.59-t2`), built from the pinned commit |
| Files | `linux-image-6.18.59-t2_6.18.59.t2-1_arm64.deb`, `linux-headers-6.18.59-t2_6.18.59.t2-1_arm64.deb` |
| Pin | the sha256 of each file, `KERNEL_RELEASE_*_SHA256` |
| URL | `https://github.com/DockSeed/a7s-linux-lts/releases/download/v6.18.59-T2/<file>` |

(GitHub serves the `~` of the package version, `6.18.59~t2-1`, as `.`.) The
download goes through `fetch_verified` like every other: the sha256 is checked
before a file enters the cache and again on every use; a mismatch stops the
build. A release that is not published yet cannot be downloaded anonymously. If
you have the files, put them where the build looks first:
`cache/sha256/<sha256>` (the file named by its hash), or any directory served as
`A7S_DOWNLOAD_MIRROR` (`file:///path` works; the files named by their hashes).
The pin decides in every case.

What the image gets:

- `linux-image-<release>` and `linux-headers-<release>` installed with dpkg, so
  `dpkg -l` knows the kernel: `/boot/vmlinuz-<release>` (the raw `Image`),
  `/boot/config-<release>`, `/boot/System.map-<release>`, the modules in
  `/usr/lib/modules/<release>`, the device trees in
  `/usr/lib/linux-image-<release>/allwinner/`, the build environment in
  `/usr/src/linux-headers-<release>`.
- `extlinux.conf` names those files directly (`kernel /boot/vmlinuz-<release>`,
  `fdt /usr/lib/linux-image-<release>/allwinner/sun60i-a733-cubie-a7s.dtb`), the
  paths Debian's tools use, instead of the copies `build` writes to `/boot`.
- The driver: the recipe's releases carry no AIC8800 driver. The wifi stage
  packages the driver's source (the upstream commit of `scripts/stages/wifi.sh`
  with the recipe's `out-of-tree/aic8800/patches`) as `a7s-aic8800-dkms`, with a
  `dkms.conf`. The image installs it with `dkms`, `gcc` and `make`; installing
  the kernel's headers package makes DKMS build `aic_load_fw.ko` and
  `aic8800_fdrv.ko` into `/usr/lib/modules/<release>/updates/dkms/`. The DKMS
  package's version names the patch series it was made from.
- The firmware stays as it is: the wifi stage's seven files, verified against
  `out-of-tree/aic8800/firmware.sha256`.

Instead of the key of `KERNEL-ID`, the rootfs stage checks the pinned sha256 of
both packages before dpkg sees them (and the image stage again), and the rootfs rules check that the packages are installed
and that the DKMS modules have the vermagic of the kernel's own modules.

What this gives: dpkg knows the kernel, its headers and the driver package.
It gives no update path, and none is promised: there is no apt repository and
no signing key. `extlinux.conf` and the safe-mode file name this release's
files, and nothing changes them, so booting another kernel needs an edit of
`extlinux.conf`, and removing these packages removes what the board boots. The
driver does not follow a new kernel by itself either: DKMS would build the
driver source that is in the image, without any later patches. Updating the
kernel on a board is not part of this recipe.

To move the release pin: tag in the recipe, build there, publish, then change
`KERNEL_RELEASE_*` here together with `KERNEL_RECIPE_COMMIT` (the build refuses
a release pin from another commit than the recipe pin).
