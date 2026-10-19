#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <math.h>
typedef void * SEXP;
typedef struct { int pid; double create_time; } ps_handle_t;
typedef struct { unsigned long starttime; } psl_stat_t;
static double psll_linux_clock_period = 0.01;
static double psll_linux_boot_time = 1000000000.999;
static double psll_linux_boot_time_legacy = 1000000000.0;
static void * R_ExternalPtrAddr(SEXP p) { return p; }
#define ScalarLogical(value) ((SEXP)(uintptr_t)((value) != 0))
static void error(const char * message) { fputs(message, stderr); abort(); }
static int psll__parse_stat_file(int pid, psl_stat_t * s, int flags) {
    if (pid != 17 || flags != 0) abort(); s->starttime = 500; return 0;
}
static int psll_linux_get_clock_period(void) { return 0; }
static int psll_linux_get_boot_time(void) { return 0; }
static void psll_linux_get_boot_time_legacy(void) {}

SEXP psll_is_running(SEXP p) {
  ps_handle_t *handle = R_ExternalPtrAddr(p);
  psl_stat_t stat;
  double ticks;

  if (!handle) error("Process pointer cleaned up already");

  if (psll__parse_stat_file(handle->pid, &stat, 0)) return ScalarLogical(0);

  if (!psll_linux_clock_period) {
    if (psll_linux_get_clock_period()) return ScalarLogical(0);
  }
  ticks = (double)stat.starttime * psll_linux_clock_period;

  /* Try precise boot time (CLOCK_REALTIME - CLOCK_MONOTONIC). */
  if (!psll_linux_boot_time) psll_linux_get_boot_time(); /* ignore failure */
  if (psll_linux_boot_time &&
      fabs(psll_linux_boot_time + ticks - handle->create_time)
          <= psll_linux_clock_period)
    return ScalarLogical(1);

  /* Try legacy boot time (integer seconds from /proc/stat btime).
     This handles handles created by old processx, which used the legacy
     integer boot time for create_time. */
  if (!psll_linux_boot_time_legacy) psll_linux_get_boot_time_legacy();
  return ScalarLogical(
    psll_linux_boot_time_legacy != 0 &&
    fabs(psll_linux_boot_time_legacy + ticks - handle->create_time)
        <= psll_linux_clock_period);
}


static void check(const char * label, double birth, int expected) {
    ps_handle_t h = {17, birth}; int actual = (int)(uintptr_t)psll_is_running(&h);
    printf("%s birth=%.6f actual=%d expected=%d\n", label, birth, actual, expected);
    if (actual != expected) abort();
}
int main(void) {
    double birth = psll_linux_boot_time + 5.0;
    check("precise_owner", birth, 1);
    check("legacy_owner", psll_linux_boot_time_legacy + 5.0, 1);
    check("old_minus_one_fixture_is_alive", birth - 1.0, 1);
    check("epoch_fixture_is_not_alive", 0.0, 0);
    check("unrelated_future_identity", birth + 2.0, 0);
    check("original_owner_survives", birth, 1);
    puts("PS_PINNED_IDENTITY_CONTROL_OK cases=6 original_fixture_counterexample=true");
}
