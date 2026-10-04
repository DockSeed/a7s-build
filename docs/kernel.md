# Kernel: Linux 6.18.54

`kernel/6.18/` is the kernel input of the build:

- `series`: 253 patch paths, applied in this order to the pristine
  `linux-6.18.54.tar.xz` from cdn.kernel.org (sha256 in `scripts/stages/kernel.sh`).
- `patches/`: `backport/` (other people's patches, to drop once 6.18.y has
  them), `soc/<subsystem>/` (A733 support, any A733 board) and `board/dts/`
  (Cubie A7S wiring). File names carry no numbers; the order lives in `series`.
- `config`: a defconfig (output of `make savedefconfig`). Install it as
  `arch/arm64/configs/a7s_defconfig` and run `make a7s_defconfig`.

Apply with `patch -p1 --fuzz=0` and treat any `offset` or `fuzz` line as a
failure: a moved hunk means the base changed, and the patch has to be
regenerated, not nudged (the device tree has many identical OPP blocks). The
`kernel` stage does exactly this.

## Changing the series

1. Apply the series to a pristine tree (`./build.sh shell`, then `patch` as above, or a git tree).
2. Edit, commit, regenerate the patch with `git format-patch`.
3. Put it into `kernel/6.18/patches/…` and list it in `series` at the right place.
4. Rebuild: `./build.sh kernel`.

Patches of ours carry `From: DockSeed <dockseed@proton.me>`, one
`Assisted-by: Claude` and no `Signed-off-by`. Third-party patches keep their
authorship and trailers and name their source (`[ Upstream commit <sha> ]` or
`Link:`); if we changed one, it also says `[ adapted: … ]`. Code ported from
Allwinner's BSP says so in its header.

## Good to know

- **MAC address.** The kernel carries none. U-Boot writes `local-mac-address`
  into `ethernet0` from its `ethaddr`; without one the boot chain's
  `CONFIG_NET_RANDOM_ETHADDR=y` gives a random address per boot, so DHCP sees a
  new machine after every reboot.
- **Config.** `MEMTEST=y` stays (`memtest=1` on the kernel command line
  excludes a bad DRAM window); `KPROBES`, `DEBUG_FS` and the default tracers
  stay as debugging support. No test-kernel switches. `SECURITY_DMESG_RESTRICT=y`
  as in Debian's kernel: only root reads the kernel log. ISO9660, UDF, exFAT and
  NTFS (ntfs3) are modules, as in Debian's kernel, for sticks, cards and DVDs.
- **Debugfs.** Only read-only status files remain (for example the display
  engine `state`); knobs that write to hardware are not carried.

## Not carried

| What | Why |
|---|---|
| 9 test instruments (IOMMU, MMC, GPU scheduler, stmmac, thermal, cpufreq, display RCQ, test switch) | fault injection for test kernels only |
| 3 pieces of debug instrumentation, not part of this series (combo PHY DP, AUX/HPD PHY, COMB1 PCIe PMA) | test kernels only |
| DP `link`, `train`, `video`, `edid`, `sink_crc` debugfs knobs; TCON_TV1 and display-engine debugfs knobs; `stop_after_link` and `rcq` module parameters | write to hardware; the code they drove stays, default path unchanged |

## Checked

Against the pristine tree in a `debian:trixie` container: all 253 patches
apply at fuzz 0 without offsets; `make a7s_defconfig && make savedefconfig`
reproduces `config`; `make dtbs` and `make W=1` over the display, PHY, PCIe and
CCU code are warning-free.
