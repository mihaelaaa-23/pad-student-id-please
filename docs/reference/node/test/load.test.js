'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');

const { computeLoad, criticalPercentFromEnv } = require('../src/lib/load');

test('the load has the shape Service Discovery stores: inFlight, maxConcurrent, percent, critical', () => {
  assert.deepEqual(
    computeLoad({ inFlight: 10, maxConcurrent: 50, criticalPercent: 80 }),
    { inFlight: 10, maxConcurrent: 50, percent: 20, critical: false },
  );
});

test('critical starts exactly at LOAD_CRITICAL_PERCENT of the limit', () => {
  assert.equal(computeLoad({ inFlight: 39, maxConcurrent: 50, criticalPercent: 80 }).critical, false);
  assert.equal(computeLoad({ inFlight: 40, maxConcurrent: 50, criticalPercent: 80 }).critical, true);
  assert.equal(computeLoad({ inFlight: 50, maxConcurrent: 50, criticalPercent: 80 }).critical, true);
});

test('critical is decided on the exact ratio, not on the rounded percent', () => {
  // 199/250 is 79.6%: rounded to 80, but still below an 80% threshold.
  const load = computeLoad({ inFlight: 199, maxConcurrent: 250, criticalPercent: 80 });

  assert.equal(load.percent, 80);
  assert.equal(load.critical, false);
});

test('LOAD_CRITICAL_PERCENT takes an integer from 1 to 100 and falls back to 80', () => {
  assert.equal(criticalPercentFromEnv('60'), 60);
  assert.equal(criticalPercentFromEnv('100'), 100);
  for (const value of [undefined, '', '0', '101', '75.5', 'high']) {
    assert.equal(criticalPercentFromEnv(value), 80, String(value));
  }
});
