// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * orc-loadupdb-check.c -- does a liborc carry the aarch64 loadupdb fix?
 *
 * build-orc compiles this against the liborc it just built and runs it (under
 * qemu-aarch64 off an aarch64 host). One ORC program of the shape of
 * gst-plugins-base's video_orc_convert_I420_BGRA -- a 4-byte destination, so
 * the NEON JIT runs loadupdb at loop_shift 2 -- reads a chroma row of n/2 bytes
 * that ends exactly at an inaccessible page. Without the fix the last block
 * loads 2 bytes past the row and the process dies with SIGSEGV; with it, it
 * prints "ok, target neon". Measured on the fixed and the unfixed 0.4.41 under
 * qemu-aarch64: the unfixed one dies with SIGSEGV.
 *
 * A run on any target other than neon proves nothing (ORC_CODE=backup, or a
 * CPU without NEON), so build-orc also requires the target name.
 *
 * exit 0 ok, 2 the program did not compile, 3 no guard page; SIGSEGV = overread
 */
#include <orc/orc.h>
#include <orc/orcparse.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int
main (void)
{
  static const char *code =
      ".function up\n.dest 4 d\n.source 1 y\n.source 1 u\n"
      ".temp 1 t\n.temp 2 w\n"
      "loadupdb t, u\nmergebw w, y, t\nmergewl d, w, w\n";
  static orc_uint32 d[1920] __attribute__ ((aligned (16)));
  static orc_uint8 y[1920];
  const int n = 1920;
  long pg = sysconf (_SC_PAGESIZE);
  OrcProgram **p;
  OrcExecutor *ex;
  orc_uint8 *page, *u;

  orc_init ();
  if (orc_parse (code, &p) != 1 ||
      !ORC_COMPILE_RESULT_IS_SUCCESSFUL (orc_program_compile (p[0])))
    return 2;

  /* n / 2 chroma bytes that end exactly at an inaccessible page */
  if (pg <= 0 || pg < n / 2)
    return 3;
  page = mmap (NULL, 2 * pg, PROT_READ | PROT_WRITE,
      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (page == MAP_FAILED || mprotect (page + pg, pg, PROT_NONE))
    return 3;
  u = page + pg - n / 2;
  memset (u, 0x80, n / 2);

  ex = orc_executor_new (p[0]);
  orc_executor_set_n (ex, n);
  orc_executor_set_array_str (ex, "d", d);
  orc_executor_set_array_str (ex, "y", y);
  orc_executor_set_array_str (ex, "u", u);
  orc_executor_run (ex);        /* SIGSEGV without the fix */

  printf ("ok, target %s\n", orc_target_get_name (orc_target_get_default ()));
  return 0;
}
