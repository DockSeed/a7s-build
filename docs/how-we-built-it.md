# How we built it

## What this is

A Debian (trixie, arm64) image for the Radxa Cubie A7S (Allwinner A733),
built from mainline Linux 6.18 plus our patch series. It was developed in a
private lab repository over about eleven weeks and is published here as a
recipe: you fetch the sources, build the image yourself, and no binary blob
is shipped.

## The story

**Before this repository.** The work started in May 2026, months before the
history shown here. Two earlier tracks came first:

- **An Armbian track** (mid-June): the vendor's 6.6 kernel overlaid on
  Armbian, with a small set of validated patches. It produced a bootable
  system quickly and taught us what the board needs: which drivers exist
  only in the vendor tree, and where mainline falls short.
- **A Fedora track** (late June): a from-scratch image recipe on a 6.18
  kernel with the vendor tree as a pinned source. It reached a login prompt
  and gave us the recipe architecture this build still follows.
- **A pile of reference material**: about 5 GB of manuals, guides and vendor
  sources. The A733 user manual and datasheet are published by Allwinner on
  its public GitLab (https://gitlab.com/tina5.0_aiot/product/docs; V0.92 in its
  history, V1.00/V1.01 current). The PDFs still carry Allwinner's
  "Confidential" footer and an all-rights-reserved notice, so this repository
  cites them by version, section and page and quotes only what a patch rests
  on: register, field and signal names, table values and short paraphrases.
  Values and code taken from the vendor's GPL kernel sources are credited in
  the patch that uses them; nothing else from the pile is republished here.

Both tracks depended on vendor code and blobs that cannot be published. So
in mid-July we chose the hard road: Debian on pristine mainline, with the
vendor tree dropped and the closed parts pushed to the edges, fetched rather
than shipped. That decision is the first commit of this history.

**One board, one person.** On 16 July there was a single board, an SD card
flashed by hand, and a person at the serial console watching the first kernel
messages scroll by. Every test meant pulling the card, writing it on a
laptop, putting it back and pressing the button. The first week produced a
boot, working storage and the rule that shaped everything after it: no
patch goes in until the board shows it works.

**A small lab.** Within days a second board joined, so the same code could be
checked on two different configurations: one with 6 GiB of RAM and an NVMe
drive, one with 8 GiB and on-board eMMC. Both boards got their UART wired to
one workstation, where each serial port is held open and logged
continuously, and both got a remotely switchable power supply. That
combination is what made a dead board recoverable without anyone touching
it: cut the power, catch U-Boot on the serial line, boot something else.
Next came automation. Home CI builds an image from any commit, a runner that
owns the boards flashes it, power-cycles the board and runs a self-test over
the network, and the serial log is kept as evidence. The first image run on
a board was on 16 August; by mid-September it was routine.

**Two agents, two areas.** On 9 September a second AI agent joined the first.
Each got its own area of work (and its own board), and both pick their
tasks from the issue tracker, work them off, and report back in the same
place. Nobody hands out individual jobs; the issue list is the queue. The
human reviews, decides and merges.

**Don't believe, measure.** The rule behind all of it: a green build proves
nothing, and "I think" is not a state that ships. Every value that reaches
hardware has to follow one chain:

1. **Reference**: where the number comes from (upstream code or the vendor
   source), cited.
2. **User manual**: what the SoC documentation says about it.
3. **Silicon**: the register read back on the running board.
4. **Hardware proof**: the effect observed and logged.

If a link in the chain is missing, the value is written down as open instead
of guessed. Some of the bigger finds (the USB 3 link that never came up, the
Ethernet that passed no frames at zero delay, a regulator window that would
have driven a memory rail to the wrong voltage) came from this habit, not
from luck.

**How the pace changed.** The numbers show the second agent and the
automation arriving:

| Month (2026) | Commits | Pull requests | Issues opened | CI runs |
|---|---|---|---|---|
| July (from 16th) | 516 | 93 | 14 | 229 |
| August | 612 | 152 | 0 | 493 |
| September | 1,638 | 443 | 240 | 3,135 |
| October (to the 3rd) | 204 | 57 | 120 | 338 |

July and August were one human and one agent working from notes and
branches; the issue tracker was barely used. September, with two agents
working from the tracker and a board run on nearly every change, produced
about one and a half times the commits of the previous two months
combined, and over four times their CI runs.

## How it was built

- **Mainline plus minimal patches**, not a vendor BSP. The first commits
  dropped the vendor tree and started from pristine 6.18.
- **Hardware proof first**: a feature counted as working only once its
  effect was observed on a board, not when it compiled.
- **Home CI built every change** (kernel, boot chain, image) and logged it.
- **Boot chain from source where possible**: TF-A (BL31) and U-Boot are
  built from source. DRAM init (boot0) and parts of the SCP firmware stay
  vendor blobs and are only fetched.
- **Blobs are fetched, never stored**, from their public origin and checked
  against a sha256.

| Date (2026) | Milestone |
|---|---|
| 20 May | First experiments (earliest repository) |
| 16 Jun | Armbian track on the vendor 6.6 kernel |
| 21 Jun | Fedora track, from scratch |
| 16 Jul | Debian on mainline: first commit; mainline 6.18 boots on the board |
| 18 Jul | SD card and eMMC work; USB 2 |
| 21 Jul | USB 3 (10 Gbit/s), Ethernet, Type-C, PMIC, CPU topology |
| 8-13 Aug | First image composed by our own build boots from SD |
| 13-15 Aug | Wi-Fi and Bluetooth; thermal zones and throttling |
| 23 Aug | Display: DisplayPort console |
| 8 Sep | GPU renders OpenGL on our own kernel |
| 21 Sep | PCIe / NVMe root drive |
| 25 Sep | Xfce desktop with hardware GL |
| 2 Oct | Audio and Bluetooth audio proven |
| 3 Oct | Freeze; recipe extracted |

## Who did what

One human and several AI coding agents (Claude and a few other assistants).

- **The human**: set the direction, made every decision, approved every
  merge, handled the hardware (cabling, flashing, power, serial).
- **Board agents**: one per test board. Each flashed images, booted the
  board, ran the hardware proofs and recorded the logs.
- **Build and CI agent**: kept the native arm64 build host and the CI runners
  working and watched the runs.
- **Kernel agents**: wrote and revised the driver, clock and device-tree
  patches.
- **Planning, review and staging sessions**: reviewed patches against
  upstream rules, decided what moves from test to the clean series, and
  prepared this recipe.
- **Small contributors**: a few other assistants added roughly 50 commits.

## What it cost

Measured in the lab repository, up to the freeze (3 Oct 2026):

| What | Amount |
|---|---|
| Calendar time | 77 days (16 Jul - 3 Oct), commits on 61 of them; 136 days since the first experiments (20 May) |
| Commits (main) | 2,970; about 270 more in the earlier tracks |
| Pull requests | 745, all closed |
| Issues | 374 (303 closed, 71 open at the freeze) |
| CI runs | 4,195: 3,727 passed, 234 failed, 234 cancelled |
| CI time | about 320 runner-hours (sum of run durations) |
| Kernel patches | 273 in the lab; recipe: 253 |
| Hardware proof and measurement logs | about 800 files |
| Boards | 2 |

## Boards tested

Two Cubie A7S boards. Every default is tuned and proven on these and nothing
else.

| Board | RAM | Storage used | Used for |
|---|---|---|---|
| The 6 GiB board | 6 GiB | SD card, one NVMe drive on the PCIe connector | PCIe / NVMe, desktop and GL soak, display, GPU |
| The 8 GiB board | 8 GiB | SD card, on-board eMMC | eMMC, USB 3 / Type-C, audio, Bluetooth, thermal, DVFS, Wi-Fi |

Other cards, drives and board revisions are not claimed.

## What the image offers

| Feature | Status | Note |
|---|---|---|
| Boot from SD card | works | Boot chain with source-built BL31 |
| Boot from eMMC | works | HS400, about 290 MB/s at 64 KiB requests |
| NVMe root over PCIe | works | Gen3 x1; U-Boot loads kernel and root from the drive after the card and eMMC; U-Boot itself stays on the card or eMMC |
| USB 2 | works | Both ports |
| USB 3 and Type-C | works | 10 Gbit/s, both plug orientations |
| Gigabit Ethernet | works | Line rate both ways |
| Wi-Fi | works | Vendor driver built out of tree; firmware fetched at build time |
| Bluetooth | works | LE and classic, A2DP, PAN; classic HID and HFP not tested |
| Display | partial | DisplayPort console and desktop up to 1920x1200 at 60 Hz (154 MHz pixel clock); higher modes need dual pixel mode, not done yet |
| GPU | works | Mesa OpenGL (GLES 2 / GL via zink); about 4x slower than the vendor driver |
| Desktop | opt-in | `A7S_DESKTOP=1`: Xfce with LightDM |
| CPU: 8 cores, DVFS, idle | works | DVFS measured on two silicon bins; other bins use the vendor's table |
| Thermal and throttling | works | Temperatures above about 74 C not calibrated |
| Audio (I2S, DMA) | partial | Proven by loopback and Bluetooth A2DP; DP audio on a sink untested |
| RTC, watchdog, PWM registers | works | PWM pin output not proven |
| Camera (CSI) | not yet | No device-tree nodes |
| Login | no default password | You set it at first login |
