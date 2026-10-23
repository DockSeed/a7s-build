# Benchmarks

One sbc-bench run of the image this recipe builds, to show where the board
stands. Other boards, kernels, DRAM clocks and cooling give other numbers.

## Run of 2026-10-04

| | |
|---|---|
| Image | desktop image of commit `b9f5896`, built from a fresh clone (`A7S_DESKTOP=1 A7S_BUILD_COMMIT=unknown`), xz sha256 `401fe12d745fe523…` |
| Kernel | Linux 6.18.54 |
| Board | Radxa Cubie A7S, 8 GB, DRAM at 2040 MHz |
| Cooling | 40 mm fan on 5 V, always on |
| State | desktop running as shipped, at least 5 min after boot, big cluster at or below 45 °C at the start |
| Tool | sbc-bench v0.9.72 (upstream commit `29708b54`, sha256 `c4f4be10…`), unchanged, `MODE=unattended` |

| 7-zip multi (3 runs) | 7-zip single | AES-256-CBC, A76 | memcpy A76 / A55 | memset A76 / A55 | Throttling | Peak |
|---|---|---|---|---|---|---|
| 11284 / 11239 / 11390 | 2604 | 1140993 KB/s | 6080 / 3648 MB/s | 12917 / 10525 MB/s | none | 68.2 °C |

Full log: [bench/2026-10-04-sbc-bench.txt](bench/2026-10-04-sbc-bench.txt).

## For comparison

The [sbc-bench results list](https://github.com/ThomasKaiser/sbc-bench/blob/master/Results.md)
has one Cubie A7S entry, on the vendor kernel 6.6 and a 6 GB board: 7-zip 11280
multi and 2480 single, AES 1141110 KB/s, memcpy 6900 MB/s, memset 8500 MB/s.
The CPU scores match. memcpy is lower here; the 8 GB board runs its DRAM at
2040 MHz, our 6 GB board at 2400 MHz.
