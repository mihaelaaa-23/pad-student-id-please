'use strict';

// The load an instance reports on /status (Lab 3, grade 8). Service Discovery reads
// only load.critical; the other fields are for people reading the registry. The
// shape and the rule are the ones Moderation and Discord DMs already publish:
// {inFlight, maxConcurrent, percent, critical}, where critical means at least
// LOAD_CRITICAL_PERCENT of MAX_CONCURRENT_TASKS are in flight.

const DEFAULT_CRITICAL_PERCENT = 80;

/**
 * LOAD_CRITICAL_PERCENT, an integer from 1 to 100; anything else falls back to 80.
 * A value that is set but invalid (`8O`, or `0.8` meant as a fraction) is logged at
 * WARN through `log` when one is given, so a typo does not go unnoticed.
 */
function criticalPercentFromEnv(value = process.env.LOAD_CRITICAL_PERCENT, log) {
  const percent = Number(value);
  if (Number.isInteger(percent) && percent >= 1 && percent <= 100) return percent;
  if (log && value !== undefined && value !== '') {
    log.warn({ loadCriticalPercent: value }, `invalid LOAD_CRITICAL_PERCENT, using ${DEFAULT_CRITICAL_PERCENT}`);
  }
  return DEFAULT_CRITICAL_PERCENT;
}

/**
 * Pure: the load object for `inFlight` requests out of `maxConcurrent`.
 * `critical` is decided on the exact ratio, not on the rounded percent, so 79.6%
 * is not reported as critical at an 80% threshold.
 */
function computeLoad({ inFlight, maxConcurrent, criticalPercent }) {
  return {
    inFlight,
    maxConcurrent,
    percent: Math.round((inFlight * 100) / maxConcurrent),
    critical: inFlight * 100 >= criticalPercent * maxConcurrent,
  };
}

module.exports = { computeLoad, criticalPercentFromEnv, DEFAULT_CRITICAL_PERCENT };
