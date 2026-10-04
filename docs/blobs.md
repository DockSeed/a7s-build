<!-- SPDX-License-Identifier: GPL-2.0-only OR MIT -->
# Downloads and their terms

The repository contains no vendor binary. Everything below is fetched at build
time from its public origin, checked against a sha256 or commit id committed here,
and kept in the download cache. Do not publish an image you built: several parts
may not be redistributed. "Unknown" means no licence text came with the file.

| What | Origin | Pin | Licence | Redistribute? |
|---|---|---|---|---|
| Linux 6.18.54 | cdn.kernel.org | sha256, `stages/kernel.sh` | GPL-2.0 | yes |
| Boot-chain package `u-boot-dlan17` (with boot0/libdram and other `awbin/` vendor blobs) | github.com/radxa-pkg/u-boot-dlan17 | commit `7bfda4c83180`, `stages/bootchain.sh`; its prebuilt files sha256, `pins/bootchain-blobs.sha256` | open parts GPL; `awbin/` blobs unknown | blobs: no |
| U-Boot source | github.com/dlan17/u-boot | commit `6a998fbcf809` (by hash only), `pins/bootchain-submodules.txt` | GPL-2.0+ | yes |
| TF-A | git.trustedfirmware.org/TF-A/trusted-firmware-a master | commit `3d425f4f4598`, `bootchain/overlay/apply.sh` | BSD-3-Clause | yes |
| SCP source and `libar100s.a`; DRAM library | github.com/radxa/allwinner-arisc, github.com/radxa/allwinner-dramlib | commits, `pins/bootchain-submodules.txt`; the closed parts also sha256, `pins/bootchain-blobs.sha256` | no licence file; closed vendor code | unknown: no |
| `tools` tree with **dragonsecboot** (packs `boot_package.fex`) | gitlab.com/tina5.0_aiot/lichee/tools | commit `2c5370f4574f`; `dragonsecboot` also sha256 | unclear | not shipped: used during the build only, in no artefact |
| RISC-V toolchain (SCP) | github.com/radxa/allwinner-toolchain release `aiot-linux-v1.4.6` | sha256, `stages/bootchain.sh` | GNU toolchain | tool only |
| AIC8800 driver | github.com/radxa-pkg/aic8800 | commit `df4c783b663e` | GPL-2.0 | yes |
| AIC8800D80 firmware (7 files) | same | sha256 per file, `out-of-tree/aic8800/firmware.sha256` | vendor, no grant | no |
| GPU firmware `rogue_36.56.104.183_v1.fw` | gitlab.freedesktop.org/imagination/linux-firmware | commit `8a58f81883f7`, sha256 | `LICENSE.powervr`: binary redistribution unmodified, with notice | yes, with the licence file |
| ORC 0.4.41, xfwm4 4.20.0-1 sources | gstreamer.freedesktop.org, deb.debian.org / snapshot.debian.org | sha256 | BSD / GPL-2.0+ | yes |

A new download is added here in the same change that adds the fetch.
