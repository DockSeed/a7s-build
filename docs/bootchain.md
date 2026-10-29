<!-- SPDX-License-Identifier: GPL-2.0-only OR MIT -->
# Boot chain

The boot chain is not built from source in this repository. It is the
stand-alone recipe
[a733-bootchain](https://github.com/DockSeed/a733-bootchain), pinned here to
one commit (`BOOTCHAIN_COMMIT` in `scripts/stages/bootchain.sh`):

| | |
|---|---|
| Repository | `https://github.com/DockSeed/a733-bootchain` |
| Pinned commit | `bd0f37556b82b780fdf4ed6471dfcd4fbc391e11` |
| Result | `u-boot-sunxi-with-spl.bin`, sha256 `4d60771167ca9da247b29a5945be68485b6b87dc844332e36b293c40da9819e8` |

`./build.sh bootchain` fetches the recipe at the pin and runs its
`scripts/build.sh all` in the builder, with its work tree in the work directory.
Output: `out/bootchain/u-boot-sunxi-with-spl.bin` and
`out/bootchain/BOOTCHAIN-ID`. What is built, what is a blob, the file layout, the
pins of U-Boot and TF-A and the post-build checks are described there
(`docs/boot-chain.md`, `docs/blobs.md`). Changes to the chain are made there
only; here the pin moves.

The image stage takes the file to 128 KiB (the boot ROM loads the SPL from
sector 256; the first partition starts at 16 MiB) and writes `BOOTCHAIN-ID`
without its `built=` line to `/boot/bootchain-id`. Before it does, it checks
that the `upstream=` and `overlay=` fields of `BOOTCHAIN-ID` are the key
(`scripts/build.sh key`) of the pinned checkout, and runs the recipe's own
`scripts/lib/bootchain-layout.sh` on the file.

A chain built from the pin has the sha256 above. Compare it in your
`BOOTCHAIN-ID` (`sha256_u-boot-sunxi-with-spl.bin=`): if it differs, your chain
is not the tested one.

The builder needs the packages of the recipe's `container/packages.txt`; they
are listed in `container/packages.d/bootchain.txt`.
Flashing only the chain to a card: `scripts/flash.sh` in the recipe.
