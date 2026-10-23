# Kernel: Linux 6.18.57

`kernel/6.18/` is the kernel input of the build:

- `series`: 256 patch paths, applied in this order to the pristine
  `linux-6.18.57.tar.xz` from cdn.kernel.org (sha256 in `scripts/stages/kernel.sh`).
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
  stay as debugging support. `SECURITY_DMESG_RESTRICT=y`
  as in Debian's kernel: only root reads the kernel log. ISO9660, UDF, exFAT and
  NTFS (ntfs3) are modules, as in Debian's kernel, for sticks, cards and DVDs;
  so are Btrfs, XFS, F2FS and the NFS and SMB clients, for disks and network
  shares (the tools come from Debian: `btrfs-progs`, `xfsprogs`, `f2fs-tools`,
  `nfs-common`, `cifs-utils`).

## Not carried

- Fault-injection test instruments (IOMMU, MMC, GPU scheduler, stmmac,
  thermal, cpufreq, display RCQ) and debug instrumentation (combo PHY DP,
  AUX/HPD PHY, COMB1 PCIe PMA).
- Writing to hardware: the debugfs knobs and module parameters DP `link`,
  `train`, `video`, `edid`, `sink_crc`; TCON_TV1 and display engine;
  `stop_after_link`, `rcq`. The code they drove stays, the default path is
  unchanged, and read-only status files remain (for example the display engine
  `state`).

## Checked

Against the pristine tree in a `debian:trixie` container: all 256 patches
apply at fuzz 0 without offsets; `make a7s_defconfig && make savedefconfig`
reproduces `config`; `make dtbs` and `make W=1` over the display, PHY, PCIe and
CCU code are warning-free.
