<!-- SPDX-License-Identifier: GPL-2.0-only OR MIT -->
# Downloads and their terms

The repository contains no vendor binary. Everything below is fetched at build
time from its public origin, checked against a sha256 or commit id committed here,
and kept in the download cache. Do not publish an image you built: several parts
may not be redistributed. "Unknown" means no licence text came with the file.

| What | Origin | Pin | Licence | Redistribute? |
|---|---|---|---|---|
| Kernel recipe `a7s-linux-lts` (Linux 6.18.59 and the patch series; fetches the row below itself) | github.com/DockSeed/a7s-linux-lts | commit `8b8606bebe63`, `scripts/stages/kernel.sh` | GPL-2.0 | yes |
| Linux 6.18.59 | cdn.kernel.org | by `a7s-linux-lts`: sha256 | GPL-2.0 | yes |
| Boot-chain recipe `a733-bootchain` (U-Boot, TF-A and the patches on both; fetches the rows below itself) | github.com/DockSeed/a733-bootchain | commit `03418865bde9`, `scripts/stages/bootchain.sh` | GPL / BSD-3-Clause, per file | yes |
| Boot-chain package `u-boot-dlan17` (build glue, with the DRAM blob `awbin/a733/ddr.bin`) | github.com/radxa-pkg/u-boot-dlan17 | by `a733-bootchain`: commit, `ddr.bin` sha256 | glue GPL; `ddr.bin` closed vendor code, no licence text | `ddr.bin`: no |
| U-Boot source | github.com/radxa/u-boot | by `a733-bootchain`: commit, by hash only | GPL-2.0+ | yes |
| TF-A | git.trustedfirmware.org/TF-A/trusted-firmware-a master | by `a733-bootchain`: commit | BSD-3-Clause | yes |
| AIC8800 driver | github.com/radxa-pkg/aic8800 | by `a7s-linux-lts`: commit `df4c783b663e` | GPL-2.0 | yes |
| AIC8800D80 firmware (7 files) | same | commit `df4c783b663e` in `scripts/stages/wifi.sh`, sha256 per file, `out-of-tree/aic8800/firmware.sha256` | vendor, no grant | no |
| GPU firmware `rogue_36.56.104.183_v1.fw` | gitlab.freedesktop.org/imagination/linux-firmware | commit `8a58f81883f7`, sha256 | `LICENSE.powervr`: binary redistribution unmodified, with notice | yes, with the licence file |
| ORC 0.4.41, xfwm4 4.20.0-1 sources | gstreamer.freedesktop.org, deb.debian.org / snapshot.debian.org | sha256 | BSD / GPL-2.0+ | yes |

A new download is added here in the same change that adds the fetch.
