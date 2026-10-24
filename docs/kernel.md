<!-- SPDX-License-Identifier: GPL-2.0-only OR MIT -->
# Kernel: Linux 6.18 LTS

The kernel is not built from source in this repository. It is the stand-alone
recipe [a7s-linux-lts](https://github.com/DockSeed/a7s-linux-lts), pinned here
to one commit (`KERNEL_RECIPE_COMMIT` in `scripts/stages/kernel.sh`):

| | |
|---|---|
| Repository | `https://github.com/DockSeed/a7s-linux-lts` |
| Pinned commit | `9715c609b022` |
| Result | `Image`, `sun60i-a733-cubie-a7s.dtb`, `config`, `System.map`, `modules/` (with aic8800), `KERNEL-ID` |

`./build.sh kernel` fetches the recipe at the pin and runs its
`scripts/build.sh all` in the builder, with the kernel tree in the work
directory (`work/linux-<version>`), and writes the result to `out/`. What the
kernel is made of (the pinned tarball, the patch series, the config, the checks
after the build) is described there (`docs/kernel.md`). Changes to the series
are made there only; here the pin moves.

Stages: `fetch-kernel` (the recipe at the pin), `build-kernel` (its `all`),
`kernel` (both), `compile-check` (the recipe's fast compile gate, after a
build), `kernel-key` (the recipe's key).

The recipe also builds the AIC8800 WLAN/BT driver against its kernel tree; the
two modules are in `out/modules/`, and `KERNEL-ID` names the driver's upstream
commit (`aic8800=`). The firmware the driver loads is the `wifi` stage's:
`out/aic8800/`, from the same commit and verified against
`out-of-tree/aic8800/firmware.sha256`.

The image stage takes `Image`, the dtb and `modules/` as they are. Before it
does, it checks that the `key=` field of `KERNEL-ID` is the key
(`scripts/build.sh key`) of the pinned checkout, that `Image` and the dtb match
the hashes in `KERNEL-ID`, that the kernel is not a variant build (developer
switches of the recipe set) and, when the firmware is present, that the driver
was built from the commit the firmware comes from.

The recipe takes its build time from its own commit, not from this repository:
the kernel does not change when only this repository does.
