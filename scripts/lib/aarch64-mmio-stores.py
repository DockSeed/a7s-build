#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only OR MIT
#
# aarch64-mmio-stores.py -- list every store a stretch of AArch64 code makes,
# with the address and value resolved from its disassembly, so an assert can
# name the MMIO writes a BL31 really makes rather than what its source or
# platform.mk says it should.
#
# The input is always the project's OWN BL31, built from source in this build
# (upstream TF-A plus this project's patches); it is never used on a vendor
# binary.
#
# Two modes, both reading `objdump -d` output on stdin:
#
#   aarch64-mmio-stores.py
#       stdin is one function (the lines from `<name>:` to the blank line
#       after it); its code must be straight-line up to its first ret.
#
#   aarch64-mmio-stores.py --anchor ADDR
#       stdin is the disassembly of a whole ELF. The code is cut into
#       straight-line regions: a region ends at a ret, an unconditional or
#       indirect branch, a forward conditional branch, and a backward one
#       that leaves the region; it starts after such an instruction and at
#       every branch target other than the head of a loop inside the region.
#       Calls (bl, blr) stay inside a region. Exactly one region of the whole
#       ELF must make a store whose address resolves to the 32-bit word ADDR;
#       that region is then listed as in the first mode. No region, or more
#       than one, fails. The region is reported on stderr. This finds the
#       code wherever the compiler put it -- with link-time optimisation a
#       small function is inlined into its caller and has no symbol left.
#
# stdout: one line per 32-bit word stored, in program order:
#           <word address> <value>[ loop]
#         <value> is a constant (`0x7`), `[A]|0xB&0xC` for a word loaded from
#         address A with bits B set and only the bits C kept (a read-modify-
#         write: `0x7010290 [0x7010290]|0x7` is mmio_setbits_32(0x07010290,
#         0x7)), or `?`. A 64-bit store is two words, a byte or halfword store
#         is its aligned word with value `?`. Stores through sp (the stack)
#         are left out.
# exit 2, with the reason on stderr, on anything it cannot follow in the
#         code it lists -- a store whose address it cannot resolve, a store
#         form it does not model, a forward, unconditional or indirect branch
#         (first mode). An unexpected compiler output fails the caller; it
#         never passes as "no such store".
#
# How: constants are followed through mov/movz/movn/movk, add/sub/orr/eor/and
# with an immediate, and adr/adrp; a 32-bit ldr from a resolved address gives
# a loaded word, which orr/and with an immediate keep track of; any other
# instruction that writes a general register makes it unknown, a call makes
# x0-x18 and x30 unknown. Every register is unknown where the code starts. The
# one branch allowed inside the code is a loop, a backward conditional branch:
# its stores are listed once, with their first-iteration address and " loop",
# and every register written inside it is unknown after it.
import re
import sys

MASK64 = (1 << 64) - 1
STORES = {"str": 0, "stur": 0, "strb": 1, "sturb": 1, "strh": 2, "sturh": 2, "stp": 0}
MEM = re.compile(r"(.*?),\s*\[([^\]]*)\](!?)(?:,\s*(#\S+))?")
INSN = re.compile(r"\s*([0-9a-f]+):\s+[0-9a-f]{8}\s+(\S+)\s*(.*)$")
FUNC = re.compile(r"([0-9a-f]+) <(.+)>:$")
COND_BRANCHES = ("cbz", "cbnz", "tbz", "tbnz")


class Unfollowable(Exception):
    pass


class Loaded:                      # (word at addr & keep) | ones, 32 bits
    def __init__(self, addr, ones=0, keep=0xffffffff):
        self.addr, self.ones, self.keep = addr, ones, keep

    def __str__(self):
        return "[%#x]%s%s" % (self.addr, "|%#x" % self.ones if self.ones else "",
                              "&%#x" % self.keep if self.keep != 0xffffffff else "")


class Insn:
    def __init__(self, pc, op, args):
        self.pc, self.op, self.args = pc, op, args
        self.ops = [t.strip() for t in args.split(",")] if args else []
        self.here = "%#x: '%s %s'" % (pc, op, args)

    def is_branch(self):
        return self.op in ("b", "br") or self.op in COND_BRANCHES or self.op.startswith("b.")

    def target(self):              # direct branch target, None if indirect
        t = self.ops[-1] if self.ops else ""
        return int(t, 16) if self.op != "br" and re.fullmatch(r"(0x)?[0-9a-f]+", t) else None

    def ends_region(self):         # control never falls through, or may jump ahead
        if self.op.startswith("ret") or self.op.startswith("br") or self.op in ("b", "eret"):
            return True
        t = self.target() if self.is_branch() else None
        return self.is_branch() and (t is None or t > self.pc)


def fail(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(2)


def parse(line):
    m = INSN.match(line)
    if not m:
        return None
    args = re.sub(r"\s*<[^>]*>", "", re.sub(r"\s*//.*$", "", m.group(3))).strip()
    return Insn(int(m.group(1), 16), m.group(2), args)


def num(r):                        # register name -> number, "zr", "sp" or None
    r = r.strip()
    if r in ("xzr", "wzr"):
        return "zr"
    if r in ("sp", "wsp"):
        return "sp"
    m = re.fullmatch(r"[xw]([0-9]+)", r)
    return int(m.group(1)) if m else None


def imm(s):
    return int(s.strip().lstrip("#"), 0)


def lsl(rest):                     # trailing "lsl #n" operand, if any
    for t in rest:
        m = re.fullmatch(r"lsl #(\S+)", t.strip())
        if m:
            return int(m.group(1), 0)
    return 0


class Machine:
    """Register tracking over a list of instructions; collects the stores."""

    def __init__(self, strict):
        self.strict = strict
        self.regs, self.wrote, self.stores, self.loops = {}, {}, [], []

    def get(self, r):
        n = num(r)
        if n == "zr":
            return 0
        return self.regs.get(n) if isinstance(n, int) else None

    def addr_of(self, r):          # only a constant can be an address
        v = self.get(r)
        return v if isinstance(v, int) else None

    def put(self, r, v, pc):
        n = num(r)
        if not isinstance(n, int):
            return
        if isinstance(v, int):
            v &= 0xffffffff if r.strip()[0] == "w" else MASK64
        elif isinstance(v, Loaded) and r.strip()[0] != "w":
            v = None               # only 32-bit loaded words are tracked
        self.regs[n], self.wrote[n] = v, pc

    def unfollowable(self, i, why):
        # Strict: the end. While searching for the anchor, a store that
        # cannot be followed is only not a candidate; a branch ends the search
        # in this region.
        if self.strict:
            fail(i.here + ": " + why)
        if not i.op.startswith("st"):
            raise Unfollowable(why)

    def store(self, i):
        s = MEM.fullmatch(i.args)
        if i.op not in STORES or not s:
            return self.unfollowable(i, "store form not modelled")
        rts = [t.strip() for t in s.group(1).split(",")]
        mem = [t.strip() for t in s.group(2).split(",")]
        if num(mem[0]) == "sp":
            return
        if any(num(t) is None for t in rts):
            return self.unfollowable(i, "store from a register that is not x/w")
        base, off = self.addr_of(mem[0]), 0
        if len(mem) > 1:
            if mem[1].startswith("#"):
                off = imm(mem[1])
            else:
                off = self.addr_of(mem[1])
                off = None if off is None else off << lsl(mem[2:])
        if base is None or off is None:
            return self.unfollowable(i, "cannot resolve the address")
        addr = (base + (0 if s.group(4) else off)) & MASK64
        size = STORES[i.op] or (8 if rts[0][0] == "x" else 4)
        for k, rt in enumerate(rts):
            at, v = addr + k * size, self.get(rt)
            if size < 4:
                at, v = at & ~3, None
            for w in range(max(size // 4, 1)):
                word = (v >> (32 * w)) & 0xffffffff if isinstance(v, int) else v if size == 4 else None
                self.stores.append((i.pc, at + 4 * w, word))
        if s.group(3):
            self.put(mem[0], addr, i.pc)
        if s.group(4):
            self.put(mem[0], base + imm(s.group(4)), i.pc)

    def load(self, i):
        s = MEM.fullmatch(i.args)
        for t in (s.group(1) if s else i.ops[0]).split(","):
            self.put(t, None, i.pc)
        if s and i.op in ("ldr", "ldur") and s.group(1).strip()[0] == "w":
            mem = [t.strip() for t in s.group(2).split(",")]
            b = self.addr_of(mem[0])
            if b is not None and (len(mem) == 1 or mem[1].startswith("#")):
                a = (b + (0 if s.group(4) or len(mem) == 1 else imm(mem[1]))) & MASK64
                self.put(s.group(1), Loaded(a), i.pc)
        if s and (s.group(3) or s.group(4)):
            self.put(s.group(2).split(",")[0], None, i.pc)

    def alu(self, i):
        op, ops = i.op, i.ops
        v, k = self.get(ops[1]), imm(ops[2]) << lsl(ops[3:])
        if isinstance(v, int):
            v = {"add": v + k, "sub": v - k, "orr": v | k, "eor": v ^ k, "and": v & k}[op]
        elif isinstance(v, Loaded) and op == "orr":
            v = Loaded(v.addr, (v.ones | k) & 0xffffffff, v.keep)
        elif isinstance(v, Loaded) and op == "and":
            v = Loaded(v.addr, v.ones & k, v.keep & k)
        else:
            v = None
        self.put(ops[0], v, i.pc)

    def branch(self, i, start):
        t = i.target()
        if i.op in ("b", "br") or t is None or t > i.pc or t < start:
            return self.unfollowable(i, "not straight-line code")
        self.loops.append((t, i.pc))
        for n, w in list(self.wrote.items()):
            if t <= w <= i.pc:
                self.regs[n] = None

    def step(self, i, start):
        op, ops = i.op, i.ops
        if op.startswith("st"):
            self.store(i)
        elif op.startswith("ld"):
            self.load(i)
        elif op in ("mov", "movz", "movn") and len(ops) >= 2:
            if ops[1].startswith("#"):
                v = imm(ops[1]) << lsl(ops[2:])
                self.put(ops[0], ~v if op == "movn" else v, i.pc)
            else:
                self.put(ops[0], self.get(ops[1]), i.pc)
        elif op == "movk":
            v, sh = self.get(ops[0]), lsl(ops[2:])
            self.put(ops[0], None if v is None else (v & ~(0xffff << sh)) | (imm(ops[1]) << sh), i.pc)
        elif op in ("add", "sub", "orr", "eor", "and") and len(ops) >= 3 and ops[2].startswith("#"):
            self.alu(i)
        elif op in ("adr", "adrp"):
            self.put(ops[0], int(ops[1], 16), i.pc)
        elif op in ("bl", "blr"):
            for n in list(range(19)) + [30]:
                self.regs[n], self.wrote[n] = None, i.pc
        elif i.is_branch():
            self.branch(i, start)
        elif ops and isinstance(num(ops[0]), int) and op not in ("cmp", "cmn", "tst", "msr"):
            self.put(ops[0], None, i.pc)

    def run(self, code):
        for i in code:
            if i.op.startswith("ret"):
                break
            self.step(i, code[0].pc if code else 0)
        return self


def functions(lines):
    """objdump -d of an ELF -> [(name, [Insn])]."""
    out = []
    for line in lines:
        f = FUNC.match(line.strip())
        if f:
            out.append((f.group(2), []))
            continue
        i = parse(line)
        if i and out:
            out[-1][1].append(i)
    return out


def regions(code):
    """Cut one function into the straight-line regions described above."""
    if not code:
        return []
    pcs = {i.pc for i in code}
    leaders, ends = {code[0].pc}, set()
    for k, i in enumerate(code):
        t = i.target() if i.is_branch() else None
        if t in pcs and (t > i.pc or i.op == "b"):
            leaders.add(t)
        if i.ends_region():
            ends.add(i.pc)
            if k + 1 < len(code):
                leaders.add(code[k + 1].pc)
    while True:
        blocks, cur = [], []
        for i in code:
            if i.pc in leaders and cur:
                blocks.append(cur)
                cur = []
            cur.append(i)
            if i.pc in ends:
                blocks.append(cur)
                cur = []
        if cur:
            blocks.append(cur)
        moved = False
        for b in blocks:           # a backward branch that leaves its region
            for k, i in enumerate(b):
                t = i.target() if i.is_branch() else None
                if t is not None and t < b[0].pc and i.pc not in ends:
                    ends.add(i.pc)
                    leaders.update({t} & pcs)
                    moved = True
        if not moved:
            return blocks


def body(block):                   # the region without the branch that ends it
    return block[:-1] if block and block[-1].ends_region() else block


def anchor_mode(anchor, lines):
    hits = []
    for name, code in functions(lines):
        for b in regions(code):
            try:
                m = Machine(strict=False).run(body(b))
            except Unfollowable:
                m = None
            if m and any(at == anchor for _, at, _ in m.stores):
                hits.append((name, b))
    where = ", ".join("%s %#x-%#x" % (n, b[0].pc, b[-1].pc) for n, b in hits)
    if len(hits) != 1:
        fail("anchor %#x: %d regions store to it, need exactly one%s" %
             (anchor, len(hits), (": " + where) if where else ""))
    sys.stderr.write("anchor %#x: region %s\n" % (anchor, where))
    return Machine(strict=True).run(body(hits[0][1]))


def main(argv):
    if argv[1:2] == ["--anchor"] and len(argv) == 3:
        m = anchor_mode(int(argv[2], 0), sys.stdin)
    elif len(argv) == 1:
        m = Machine(strict=True).run([i for i in map(parse, sys.stdin) if i])
    else:
        fail("usage: %s [--anchor ADDR] < objdump-d-output" % argv[0])
    for pc, at, v in m.stores:
        print("%#x %s%s" % (at, "?" if v is None else "%#x" % v if isinstance(v, int) else v,
                            " loop" if any(t <= pc <= e for t, e in m.loops) else ""))


if __name__ == "__main__":
    main(sys.argv)
