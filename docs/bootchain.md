<!-- SPDX-License-Identifier: GPL-2.0-only OR MIT -->
# Boot chain

`./build.sh bootchain` builds three files in `out/bootchain/`:

| File | Goes to |
|---|---|
| `boot0_sdcard.bin` | the card at 128 KiB (the boot ROM loads it from sector 256) |
| `boot_package.fex` | the card at 12 MiB (boot0 loads it from there) |
| `BOOTCHAIN-ID` | `/boot/bootchain-id` in the image: package commit, overlay hash, build epoch, sha256 of both files |

The first partition starts at 16 MiB. The offsets live in
`scripts/lib/bootchain-layout.sh`; the stage refuses a chain that does not fit,
and the image stage checks again before it writes.

```
BROM -> boot0 (vendor blob, DRAM init) -> SPL -> BL31 (TF-A, built here, SRAM 0x62000)
     -> U-Boot (built here) -> kernel          SCP firmware in DRAM @ 0x48100000
```

## What is built from source, what is a blob

| Part | Source |
|---|---|
| boot0 with the DRAM init (libdram) | **vendor blob**, taken unchanged from Radxa's package tree |
| BL31 | upstream TF-A master `3d425f4f4598` + 16 patches (`bootchain/patches/tf-a/`) |
| U-Boot | Radxa's fork (`dlan17/u-boot` `6a998fbcf809`) + Radxa's 33 patches + 7 of ours (`bootchain/patches/u-boot/`) |
| SCP (ar100s, RISC-V) | built from Radxa's `allwinner-arisc` source, but links the closed `libar100s.a` |
| `dragonsecboot` (packs `boot_package.fex`) | **vendor tool**, runs during the build only, ends up in no file |

The frame is Radxa's package `radxa-pkg/u-boot-dlan17` at commit `7bfda4c83180`,
built with its own Makefile. `bootchain/overlay/apply.sh` rewires it: BL31 is
built from TF-A instead of taken from the package's prebuilt `bl31.bin`, the
package's patch 0019 is cut down to relocate only the SCP to DRAM, and our patch
series are added. Patches taken from other authors keep their author and
sign-off and name the commit they come from (`Link:`), with `[ adapted: ... ]`
where we changed them.

## Pins and checks

Every input is fetched from its public origin by commit id or sha256 and cached:
the package and its submodules (`pins/bootchain-submodules.txt`), TF-A
(`ATF_BASE` in `bootchain/overlay/apply.sh`), the RISC-V toolchain for the SCP
(sha256 in `scripts/stages/bootchain.sh`). Every prebuilt file taken from the
package is checked against `pins/bootchain-blobs.sha256`.

The stage then checks the result, not just the exit code: the BL31 inside
`boot_package.fex` is the source-built one and comes from the pinned TF-A commit;
every build time in it is the pinned epoch (the commit date of the package, see
`scripts/lib/bootchain-epoch.sh`); and our own `bl31.elf` links what the patches
promise -- native CPU_SUSPEND, the CPU_BACK_PLL enable, no SCPI path, the
Cortex-A76 errata and CVE workarounds, the security-register writes, a power-down
hook that cannot return, the EL3 stack size. Two builds of one commit are
byte-identical. `A7S_BUILD_WITHOUT_ERRATUM_3888013=1` builds without the one
workaround that costs the A76 about half its uncached read bandwidth; the stage
then warns that this is not the shipping chain.

## Tested on the board

The chain built from this recipe is byte-identical to one that was tested on
the 6 GiB board, booting from SD: `boot_package.fex` sha256
`829fbf1720af916026307c4a3fec67964c43071945629c6fae26f254d0369cde`,
`boot0_sdcard.bin` sha256
`85fcc9b1b8ebd7a4c06c63810a207339d21fc766919e049f2a72a018463ad893`. Tested:
cold boot and warm reset, all 8 cores up, CPU_SUSPEND including cluster sleep
on all cores, a load/idle and CPU hotplug soak without errors, `poweroff`.
Compare the sha256 in your `BOOTCHAIN-ID`: if they differ, your chain is not
the tested one (a changed pin or patch, or a bug in the recipe).

## Known limits

- **x86-64 only.** `dragonsecboot`, two SCP build tools and Radxa's RISC-V
  toolchain are x86-64 programs, so the boot chain builds only on an x86-64
  builder. On arm64 the stage stops at the start with a message.
- **The U-Boot commit is reachable only by hash.** `dlan17/u-boot`
  `6a998fbcf809` is on no branch or tag any more (the fork rebases); GitHub
  serves it by its commit id until it garbage-collects it. If it disappears, the
  fetch fails naming it. A clone of it hosted elsewhere works: change the URL in
  `pins/bootchain-submodules.txt`, the commit id still decides.
- **Transitional.** U-Boot is still Radxa's fork inside Radxa's package tree,
  and boot0 and the SCP library stay closed (`docs/help-wanted.md`).
