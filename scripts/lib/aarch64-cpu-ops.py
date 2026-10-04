#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only OR MIT
#
# aarch64-cpu-ops.py -- list the cpu_ops entries a TF-A BL31 links: for each,
# its MIDR and the functions its two power-down slots point to, read from the
# linked image, so an assert can name what PSCI calls on a power-down rather
# than what a source file declares.
#
# The input is always the project's OWN BL31, built from source in this build
# (upstream TF-A plus this project's patches); it is never used on a vendor
# binary.
#
# usage:  aarch64-cpu-ops.py <toolchain prefix or ''> <bl31.elf>
# stdout: one line per entry, in link order:
#           <midr> <pwr_dwn_ops[0]> <pwr_dwn_ops[1]>
#         each slot a symbol name, or its address if no symbol sits there.
# exit 2, with the reason on stderr, if the entries cannot be read: no
#         __CPU_OPS_START__/__CPU_OPS_END__, a size that is not a whole number
#         of entries, or bytes objdump does not print.
#
# The layout is include/lib/cpus/cpu_ops.h for an AArch64 BL31 (IMAGE_AT_EL3,
# IMAGE_BL31): midr at 0, reset_func at 8, e_handler_func at 16,
# pwr_dwn_ops[2] at 24 and 32. The entry size depends on build options
# (REPORT_ERRATA and CRASH_REPORTING add fields), so it is the smallest size
# that divides the table into entries which all start with a MIDR value
# (implementer set, architecture 0xF); the local cpu_ops_<core> labels do not
# survive the link.
import re
import subprocess
import sys

MIDR_SLOT, PWR_DWN_SLOTS = 0, (24, 32)
MIN_ENTRY = 40                     # midr, reset, e_handler, two power-down slots


def fail(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(2)


def run(*cmd):
    try:
        return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        fail("%s failed: %s" % (cmd[0], e))


def symbols(tc, elf):
    by_addr, by_name = {}, {}
    for line in run(tc + "nm", elf).splitlines():
        p = line.split()
        if len(p) == 3:
            by_addr.setdefault(int(p[0], 16), p[2])
            by_name[p[2]] = int(p[0], 16)
    return by_addr, by_name


def table(tc, elf, lo, hi):
    """The bytes of [lo, hi) as objdump -s prints them."""
    data = bytearray()
    for line in run(tc + "objdump", "-s", "--start-address=%#x" % lo,
                    "--stop-address=%#x" % hi, elf).splitlines():
        m = re.match(r"\s([0-9a-f]+)((?: [0-9a-f]{2,8}){1,4})", line)
        if m and lo <= int(m.group(1), 16) < hi:
            data += bytes.fromhex(m.group(2).replace(" ", ""))
    if len(data) != hi - lo:
        fail("objdump printed %d of the %d bytes of the cpu_ops table" % (len(data), hi - lo))
    return bytes(data)


def word(data, off):
    return int.from_bytes(data[off:off + 8], "little")


def looks_like_midr(v):            # implementer [31:24] set, architecture [19:16] = 0xF
    return v >> 32 == 0 and (v >> 24) & 0xff != 0 and (v >> 16) & 0xf == 0xf


def entry_size(data):
    for size in range(MIN_ENTRY, len(data) + 1, 8):
        if len(data) % size == 0 and all(looks_like_midr(word(data, o))
                                         for o in range(0, len(data), size)):
            return size
    fail("the cpu_ops table (%d B) does not divide into entries that each start with a MIDR" % len(data))


def main(argv):
    if len(argv) != 3:
        fail("usage: %s <toolchain prefix or ''> <bl31.elf>" % argv[0])
    tc, elf = argv[1], argv[2]
    by_addr, by_name = symbols(tc, elf)
    if "__CPU_OPS_START__" not in by_name or "__CPU_OPS_END__" not in by_name:
        fail("%s has no __CPU_OPS_START__/__CPU_OPS_END__" % elf)
    data = table(tc, elf, by_name["__CPU_OPS_START__"], by_name["__CPU_OPS_END__"])
    size = entry_size(data)
    for off in range(0, len(data), size):
        slots = [word(data, off + s) for s in PWR_DWN_SLOTS]
        print("%#x %s" % (word(data, off + MIDR_SLOT),
                          " ".join(by_addr.get(a, "%#x" % a) for a in slots)))


if __name__ == "__main__":
    main(sys.argv)
