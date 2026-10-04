<!-- SPDX-License-Identifier: GPL-2.0-only OR MIT -->
# Help wanted: what is still a vendor blob

Some parts of the image are still closed vendor code (see [blobs.md](blobs.md)).
Where open work exists we point to it; where it does not, we say so.
State as of 2026-10. "Related" = a close relative of the A733 (sun60i), not the A733 itself.

| Area | Still a blob | Open work (link) | State | What helps |
|---|---|---|---|---|
| DRAM init (LPDDR4/5 training) | `libdram` inside boot0 | Related: U-Boot SPL driver for A523/T527, [`dram_sun55i_a523.c`](https://github.com/u-boot/u-boot/tree/master/arch/arm/mach-sunxi) (LPDDR4 + DDR3), [patch](https://lists.denx.de/pipermail/u-boot/2025-July/594555.html). Nothing for A733/LPDDR5 | A523: merged. A733: no public work found | A clean-room open implementation of the A733 controller/PHY from public documentation, LPDDR5 above all |
| boot0 / SPL, `dragonsecboot` | vendor boot0; packer of unclear licence | No A733/sun60i SPL in U-Boot `arch/arm/mach-sunxi` yet. An A733 support series for U-Boot was posted (v3, January 2026); we have not checked whether it covers SPL/DRAM | early | An open SPL (needs DRAM first), an open `boot_package` packer |
| SCP / ARISC (E902 RISC-V) | `libar100s.a` | crust (libre SCP firmware, [mirror](https://github.com/wgottwalt/crust)) targets the older AR100/OpenRISC parts only; nothing found for A523/A733 | no public work found | Clean-room firmware for the E902: power states, suspend, PSCI hooks |
| TF-A BL31 | none: BL31 is built from upstream TF-A master (commit in [bootchain.md](bootchain.md)) plus this project's patches (`bootchain/patches/tf-a/`) | Upstream [`plat/allwinner`](https://github.com/ARM-software/arm-trusted-firmware/tree/master/plat/allwinner) has A64, H6, H616, A133, R329; no A523/A733 upstream | none found | Send the A733 platform patches upstream to TF-A |
| GPU firmware (PowerVR BXM, BVNC 36.56.104.183) | `rogue_36.56.104.183_v1.fw` (redistributable) | Kernel `drm/imagination` + Mesa PowerVR Vulkan; [BXM-4-64 (36.52.104.182) promoted to "supported" in 7.3](https://www.phoronix.com/news/Imagination-BXM-4-64-Linux-7.3). Firmware: [imagination/linux-firmware](https://gitlab.freedesktop.org/imagination/linux-firmware) | Related BVNC: supported. 36.56.104.183 not found in the upstream driver | Test the BVNC on the A7S, add it to `drm/imagination`, run Vulkan CTS |
| Wi-Fi/BT (AIC8800D80, USB) | out-of-tree driver + 7 firmware files | Only community packaging, e.g. [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800); no mainline submission found | no public work found | Port to current cfg80211 (7.1 broke it), upstream submission, firmware licence grant from AICSemi |

## Kernel side

**The A733 is landing in mainline Linux right now (linux-sunxi, 7.3/7.4): the first series
are merged, more are under review. This is when help counts most** — test the series on a
real A7S, review them, report on the linux-sunxi list (state 2026-10-03):
- RTC + RTC clocks: [v7](https://lore.kernel.org/all/20260723-a733-rtc-v7-0-8fd68aab94ae@baylibre.com/), merged
- Power domains (PCK600): [v2](https://lore.kernel.org/all/20260305-b4-pck600-a733-v2-0-ba6bbed7d253@gmail.com/), accepted
- Pinctrl: [series](https://lore.kernel.org/all/20260910133519.459011-1-andre.przywara@arm.com/), applied for 7.4
- Clocks (CCU + R-CCU): [v5](https://lore.kernel.org/all/20260930-a733-clk-v5-0-11175b41cd2d@pigmoral.tech/), under review
- DMA: [v5](https://lore.kernel.org/all/20260826-sun60i-a733-dma-v5-0-abc5229b441e@gmail.com/), under review
- Ethernet (GMAC): [v3](https://lore.kernel.org/all/20260923-allwinner-a733-gmac-support-v3-0-15735155a789@baylibre.com/), under review
- PMIC regulators (AXP318): [v8](https://lore.kernel.org/all/20260910-axp318-regulator-v8-0-e906a61a7f3d@baylibre.com/), under review
- Device tree for the Cubie A7S: [v1](https://lore.kernel.org/all/20260613-a733-dts-v1-public-ready-v1-0-7787c94681db@gmail.com/), waiting for clocks and pinctrl

## How to help

- Test the series above on your A7S and report on the respective mailing list (linux-sunxi).
- Reverse engineering and clean-room work must work from public documentation and source only.
- Found a link we missed or a stale one? Open an issue or send a patch to this recipe.
