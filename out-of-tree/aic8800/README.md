<!--
SPDX-License-Identifier: GPL-2.0-only OR MIT
-->
# aic8800 - firmware of the board's WiFi/BT part

The Cubie A7S carries an AICSemi AIC8800D80 WiFi/Bluetooth part behind its
on-board USB hub. The driver comes from the kernel recipe
[a7s-linux-lts](https://github.com/DockSeed/a7s-linux-lts) (patches and notes:
`out-of-tree/aic8800/` there). With `A7S_KERNEL=build` the recipe builds it
with the kernel. With `A7S_KERNEL=release` the kernel packages carry no driver:
the wifi stage packages the same source and patches for DKMS, and the image
builds it against the installed kernel headers ([docs/kernel.md](../../docs/kernel.md)).
This directory holds what the image recipe adds: the hashes that pin the
firmware the driver loads.

## The pin

| | |
|---|---|
| Source | `radxa-pkg/aic8800`, tag `5.0+git20260123.5f7be68d-8` |
| Commit | `df4c783b663eba1956579c681acd5e45f25c671d` (`AIC8800_COMMIT` in `scripts/stages/wifi.sh`) |
| Firmware subdir | `src/USB/driver_fw/fw/aic8800D80` |

The commit is the one the kernel recipe builds the driver from. The image stage
refuses a driver built from another commit (`KERNEL-ID` for `A7S_KERNEL=build`,
`DKMS-ID` of the DKMS package for `release`), so the two pins move together.
The DKMS package (`a7s-aic8800-dkms`) is made from this commit and from the
patches of the pinned recipe commit; its version is the tag above plus
`+a7s.<12 hex digits of a sha256 over the recipe's patch series>`, and the wifi
stage refuses a recipe whose `scripts/lib/aic8800.sh` names another commit,
tag or subdirectory.

## Firmware

The firmware is vendor-supplied binary without a licence statement. We claim no
right to redistribute it: it is fetched at build time from the pinned upstream
commit, verified against `firmware.sha256`, and never committed.

The driver does not use `request_firmware()`; it opens
`/lib/firmware/aic8800D80/<name>` directly, so the image installs the files
there. The seven files the load path opens on this part are listed in
`firmware.sha256`, which carries our own hashes. The vendor manifest
(`src/firmware_version.md`) does not list `aic_userconfig_8800d80.txt`, so it
cannot cover the full set.

## Bumping the pin

1. Move the commit in the kernel recipe first, then here: tag and commit in
   `scripts/stages/wifi.sh`.
2. Regenerate `firmware.sha256` from the fetched files and compare against the
   vendor manifest, noting any file it does not list.
