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
