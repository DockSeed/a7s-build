<!--
SPDX-License-Identifier: GPL-2.0-only OR MIT
-->
# aic8800 - the board's WiFi/BT part, built out of tree

The Cubie A7S carries an AICSemi AIC8800D80 WiFi/Bluetooth part behind its
on-board USB hub. This directory holds our patches against Radxa's packaging of
the vendor driver (`radxa-pkg/aic8800`) and the hashes that pin its firmware.
The vendor source and the firmware blobs are **never committed here**; the
build fetches them from the pinned upstream commit and applies `patches/` in
the order of `patches/series`.

## Why out of tree

There is no mainline driver for this part. An RFC series on linux-wireless
covers the SDIO variant only; there is no upstream support for USB yet.

The vendor driver is about 130 files, which we have not reviewed in full. It is
built out of tree as shipped, with only the delta in `patches/` applied, and
not imported as kernel patches.

## The pin

| | |
|---|---|
| Source | `radxa-pkg/aic8800`, tag `5.0+git20260123.5f7be68d-8` |
| Commit | `df4c783b663eba1956579c681acd5e45f25c671d` |
| Driver subdir | `src/USB/driver_fw/drivers/aic8800` (the part is a USB device on this board) |
| Firmware subdir | `src/USB/driver_fw/fw/aic8800D80` |
| Modules built | `aic_load_fw` (firmware loader) and `aic8800_fdrv` (WiFi FullMAC) |
| Built against | Linux 6.18 |

`aic_btusb` is deliberately not built. It brings a private HCI stack and
exposes `/dev/aicbt_dev` instead of an `hci0`. The in-tree `btusb` driver binds
this part through its generic interface entry (class `e0/01/01`), so Bluetooth
costs no extra code.

Chip facts a maintainer needs: the USB id before firmware download is
`a69c:8d80`; after download the part re-enumerates as `a69c:8d81` with three
interfaces (two Bluetooth `e0/01/01`, one vendor-specific `ff/ff/ff`). The
loader reports `chip_id=7` and `chip_mcu_id=0` on the board.

## Firmware

The firmware is vendor-supplied binary without a licence statement. We claim no
right to redistribute it: it is fetched at build time from the pinned upstream
commit, verified against `firmware.sha256`, and never committed.

The driver does not use `request_firmware()`; it opens
`/lib/firmware/aic8800D80/<name>` directly (overridable with the `aic_fw_path`
module parameter), so the build installs the files there. The seven files the
load path opens on this part:

- `fw_adid_8800d80_u02.bin`
- `fw_patch_8800d80_u02.bin`
- `fw_patch_8800d80_u02_ext0.bin`
- `fw_patch_table_8800d80_u02.bin`
- `fmacfw_8800d80_u02.bin`
- `fmacfw_8800d80_h_u02.bin` (shipped although the non-H image is the one used
  here: the choice is made at runtime from `chip_id`)
- `aic_userconfig_8800d80.txt`

`firmware.sha256` carries our own hashes, which the build verifies. The vendor
manifest (`src/firmware_version.md`) does not list
`aic_userconfig_8800d80.txt`, so it cannot cover the full set.

## Patches

Applied in this order (`patches/series`). Each patch carries its own
explanation in its header.

1. `compat-build-against-linux-6.18` - the pinned tag guards most kernel API
   changes itself; what remains is `rwnx_cfg80211_get_tx_power()`, which needs
   the 6.18 prototype, plus a few removed timer calls in code that is not
   compiled.
2. `aic_load_fw-set-cache-bit-before-firmware-upload` - based on the change by
   bnister (pull request 35 of shenmintao/aic8800d80, merged 2026-03-04): on parts reporting an MCU id, bit 0 at `0x40100020`
   must be set before upload or BT firmware load fails with `-110`. Does not
   execute on the board (`chip_mcu_id=0`); kept for other parts.
3. `aic_load_fw-match-only-the-vendor-interface` - the loader's table matched
   whole devices, so after download USB probed it on all three interfaces and
   each refusal was logged as an error. It now matches only `ff/ff/ff`, the
   interface its parser accepts.
4. `aic_load_fw-track-firmware-upload-per-part` - the "firmware already
   loaded" flag was one module-wide global; it is now kept per part, keyed by
   USB topology path, so two parts do not depend on enumeration order.
5. `aic8800-lower-the-default-log-level` - `AICWFDBG()` has no `KERN_` prefix,
   so every debug line printed at warning level (about 40 % of a boot log,
   including SSIDs). Both modules now default to `LOGERROR`; the level stays
   adjustable at runtime through `aicwf_dbg_level`. Radxa's package carries the
   same change in its quilt series, which a plain git checkout does not run;
   this patch is that change. The rest of the quilt series is not applied:
   `fix-usb-firmware-path.patch` would move the firmware path away from
   `/lib/firmware/aic8800D80`, where this image installs the files.
6. `regulatory-let-cfg80211-govern-the-radio` - the wiphy was self-managed
   (`custregd` compiled in as true, while the parameter text says the default
   is 0), so `regulatory.db` governed nothing. The default now matches the
   text: `custregd` is opt-in.
7. `aic8800_fdrv-keep-draining-rx-after-a-bad-aggregate` - after an aggregate
   header that claims more than the buffer holds, the rx consumer thread was
   not woken again and all rx URBs eventually failed to resubmit; the loop now
   breaks instead of returning with buffers queued.
8. `aic8800_fdrv-drop-the-disconnect-handshake-from-rx-completion` - a port of
   Radxa's `fix-usb-suspend-reboot-hang.patch`: a failed bulk-IN completion
   took a semaphore inside URB completion and left scanning returning
   `-EBUSY`; the handshake is removed from the completion path.
9. `aic_load_fw-bound-the-rx-parser-to-the-buffer` - the loader's rx parser and
   message dispatch did not bound frame headers against the buffer (endless
   loop with an skb leak, handler-table index, `memcpy` length); every header,
   pull and copy is now bounded.
10. `aic8800_fdrv-do-not-advertise-monitor-mode` - monitor mode is removed from
    the supported interface modes: this build compiles the driver without its
    monitor-data support, the guard in `change_iface()` refuses monitor mode
    once a second vif exists, and the monitor paths were measured to oops, so
    a working monitor mode needs a series of its own.
11. `aic8800_fdrv-print-the-mgmt-tx-status-through-dynamic-debug` - a
    `trace_printk()` in the management tx-status path made every boot print the
    kernel's DEBUG-kernel notice; it is now `pr_debug()`.
12. `aic8800-give-the-boot-path-prints-a-log-level` - bare `printk()` lines of
    a normal boot (firmware paths, md5, upload progress) all came out at warn;
    they now have meaningful levels, text unchanged.
13. `aic_load_fw-no-rx-refill-after-the-bus-has-stopped` - a pending rx refill
    could run after the post-download bus stop and log `bus is not up` at error
    level on a working radio; the work is cancelled after the stop.
14. `aic8800-init-the-rx-refill-work-before-the-first-error-path` - a failed
    allocation in probe cancelled a work item that was never initialised;
    initialised first now, and `-ENOMEM` is returned as a negative errno.
15. `aic_load_fw-no-rx-urb-in-flight-after-the-bus-stop` - closes the remaining
    race where a refill submits an rx URB after the stop killed them and the
    error path frees the device under it.
16. `aic_load_fw-return-an-errno-from-a-failed-configuration-or-upload` - a
    failed configuration or firmware upload returned 0 from probe, leaving the
    interface "bound" and the radio dead until re-plug.
17. `aic_load_fw-a-timed-out-firmware-message-fails-and-is-freed` - a timed-out
    firmware message was reported as confirmed, leaked the command, and a killed
    wait freed it while still on the list; it now returns `-ETIMEDOUT`.
18. `aic8800_fdrv-count-received-data-frames-in-the-interface-statistics` -
    `rx_packets`/`rx_bytes` were only counted under `CONFIG_BR_SUPPORT`
    (disabled), so a station's receive counters did not follow its traffic.

Several patches add small module parameters or counters under
`/sys/module/<module>/parameters/` to inject the failure they fix; they are
described in the patch headers.

## Licence

The vendor driver is GPL-2.0 by Radxa's `debian/copyright` stanza for `src/*`
(relayed from AICSemi); both modules declare `MODULE_LICENSE("GPL")`. The
upstream SDK ships no licence file of its own. Our patches are GPL-2.0-only,
matching the code they modify. The firmware is not covered by
any of this (see above).

## Bumping the pin

1. Pick the new upstream tag and resolve its full commit id.
2. Update the tag, commit and subdirectory pins in the build script that
   fetches this tree, and the table above.
3. Re-derive the firmware list from the new tree: the load path in
   `aic_compat_8800d80.c` decides which files are opened. Regenerate
   `firmware.sha256` from the fetched files and compare against the vendor
   manifest, noting any file it does not list.
4. Apply `patches/series` in order. A patch that no longer applies fails the
   build; rebase it rather than loosening the match. Drop patches that upstream
   has absorbed.
5. Build against the kernel pin, load the modules on the board, and check that
   the firmware md5 prints of the driver match `firmware.sha256`, WiFi
   associates and `hci0` comes up.
