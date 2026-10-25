'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');

const { CircuitBreaker, classify } = require('../src/lib/circuitBreaker');

// A clock the test moves by hand, and a logger that keeps every line.
function setup(options = {}) {
  let now = 1_000_000;
  const lines = [];
  const trips = [];
  const breaker = new CircuitBreaker({
    targetService: 'university-record-service',
    timeoutMs: 2500,
    now: () => now,
    log: (level, message, fields) => lines.push({ level, message, ...fields }),
    onInstanceTrip: (instance) => trips.push(instance),
    ...options,
  });
  return { breaker, lines, trips, advance: (ms) => { now += ms; } };
}

const noResponse = { status: null, body: null, error: 'connect ECONNREFUSED', instanceId: null, cancelled: false };
const ok = { status: 200, body: {}, error: null, instanceId: 'urs-a', cancelled: false };
const errorFrom = (status, code, instanceId = null) => ({
  status, body: { error: { code, message: 'x' } }, error: null, instanceId, cancelled: false,
});

test('the window is HTTP_TIMEOUT_MS x 3.5', () => {
  assert.equal(setup().breaker.windowMs, 8750);
  assert.equal(setup({ timeoutMs: 4500 }).breaker.windowMs, 15750);
});

test('classify follows the contract table', () => {
  assert.equal(classify(noResponse).counted, true);
  assert.equal(classify({ ...noResponse, error: 'timeout after 2500ms' }).counted, true);
  for (const [status, code] of [[500, 'INTERNAL_ERROR'], [502, 'BAD_GATEWAY'], [504, 'GATEWAY_TIMEOUT'], [504, 'TASK_TIMEOUT'], [500, undefined]]) {
    assert.equal(classify(errorFrom(status, code)).counted, true, `${status} ${code}`);
  }
  for (const [status, code] of [
    [502, 'DEPENDENCY_REFUSED'], [503, 'CONCURRENCY_LIMIT_REACHED'], [503, 'DEPENDENCY_UNAVAILABLE'],
    [503, 'WS_NEGOTIATION_DISABLED'], [404, 'NOT_FOUND'], [401, 'UNAUTHORIZED'], [422, 'VALIDATION_FAILED'],
  ]) {
    assert.equal(classify(errorFrom(status, code)).counted, false, `${status} ${code}`);
  }
  assert.equal(classify(ok).counted, false);
  // codes the contract does not list: any 5xx counts, no 4xx does
  assert.equal(classify(errorFrom(503, 'SOMETHING_ELSE')).counted, true);
  assert.equal(classify({ ...ok, status: 503, body: null }).counted, true);
  assert.equal(classify(errorFrom(418, 'TEAPOT')).counted, false);
  assert.equal(classify({ ...noResponse, cancelled: true }).ignored, true);
});

test('three failures without an instance id within the window open the breaker', async () => {
  const { breaker, lines, advance } = setup();
  for (let i = 0; i < 3; i += 1) {
    await breaker.execute(async () => noResponse);
    advance(1000);
  }
  assert.equal(breaker.state, 'open');

  let called = false;
  const result = await breaker.execute(async () => { called = true; return ok; });
  assert.equal(called, false);
  assert.equal(result.rejected, true);
  // opened 1000 ms ago, window 8750 ms: 7.75 s left, rounded up
  assert.equal(result.retryAfterSeconds, 8);

  const change = lines.find((l) => l.message === 'circuit breaker state changed');
  assert.deepEqual(change, {
    level: 'warn', message: 'circuit breaker state changed', targetService: 'university-record-service',
    previousState: 'closed', state: 'open', failures: 3, windowMs: 8750,
  });
  assert.equal(lines.at(-1).message, 'call rejected by circuit breaker');
});

test('failures spread over more than one window do not open it', async () => {
  const { breaker, advance } = setup();
  for (let i = 0; i < 5; i += 1) {
    await breaker.execute(async () => noResponse);
    advance(4500);
  }
  assert.equal(breaker.state, 'closed');
});

test('successes in between do not clear the window', async () => {
  const { breaker } = setup();
  await breaker.execute(async () => noResponse);
  await breaker.execute(async () => ({ ...ok, instanceId: null }));
  await breaker.execute(async () => noResponse);
  await breaker.execute(async () => noResponse);
  assert.equal(breaker.state, 'open');
});

test('after one window it lets a single trial call through, and success closes it', async () => {
  const { breaker, advance } = setup();
  for (let i = 0; i < 3; i += 1) await breaker.execute(async () => noResponse);
  advance(8750);

  let release;
  const trial = breaker.execute(() => new Promise((resolve) => { release = resolve; }));
  assert.equal(breaker.state, 'half_open');
  const meanwhile = await breaker.execute(async () => ok);
  assert.equal(meanwhile.rejected, true);

  release(ok);
  await trial;
  assert.equal(breaker.state, 'closed');
  assert.equal((await breaker.execute(async () => ok)).status, 200);
});

test('a failed trial opens it again for another window', async () => {
  const { breaker, advance } = setup();
  for (let i = 0; i < 3; i += 1) await breaker.execute(async () => noResponse);
  advance(8750);

  await breaker.execute(async () => noResponse);
  assert.equal(breaker.state, 'open');
  assert.equal((await breaker.execute(async () => ok)).retryAfterSeconds, 9);
});

test('a 4xx on the trial still closes it: the callee is reachable', async () => {
  const { breaker, advance } = setup();
  for (let i = 0; i < 3; i += 1) await breaker.execute(async () => noResponse);
  advance(8750);

  await breaker.execute(async () => errorFrom(404, 'NOT_FOUND', 'urs-a'));
  assert.equal(breaker.state, 'closed');
});

test('three failures of one instance trip that instance, never block calls', async () => {
  const { breaker, lines, trips } = setup();
  for (let i = 0; i < 3; i += 1) {
    const result = await breaker.execute(async () => errorFrom(502, 'BAD_GATEWAY', 'urs-a'));
    assert.equal(result.rejected, undefined);
  }
  assert.equal(breaker.state, 'closed');
  assert.deepEqual(trips, [{ targetService: 'university-record-service', targetInstanceId: 'urs-a', failures: 3, windowMs: 8750 }]);
  const tripped = lines.find((l) => l.message === 'instance failure threshold reached');
  assert.equal(tripped.mode, 'log');

  // the count starts again: two more failures do not trip it a second time
  await breaker.execute(async () => errorFrom(500, 'INTERNAL_ERROR', 'urs-a'));
  await breaker.execute(async () => errorFrom(500, 'INTERNAL_ERROR', 'urs-a'));
  assert.equal(trips.length, 1);
});

test('failures of different instances are counted apart', async () => {
  const { breaker, trips } = setup();
  for (const id of ['urs-a', 'urs-b', 'urs-a', 'urs-b']) {
    await breaker.execute(async () => errorFrom(504, 'GATEWAY_TIMEOUT', id));
  }
  assert.equal(trips.length, 0);
  assert.equal(breaker.state, 'closed');
});

test('responses that do not count never open it or trip an instance', async () => {
  const { breaker, trips, lines } = setup();
  for (const [status, code] of [[503, 'CONCURRENCY_LIMIT_REACHED'], [503, 'DEPENDENCY_UNAVAILABLE'], [502, 'DEPENDENCY_REFUSED']]) {
    for (let i = 0; i < 3; i += 1) {
      await breaker.execute(async () => errorFrom(status, code, 'urs-a'));
      await breaker.execute(async () => errorFrom(status, code));
    }
  }
  assert.equal(breaker.state, 'closed');
  assert.equal(trips.length, 0);
  assert.equal(lines.length, 0);
});

test('a call cancelled by our own task timeout is not counted', async () => {
  const { breaker } = setup();
  for (let i = 0; i < 5; i += 1) {
    await breaker.execute(async () => ({ ...noResponse, error: 'cancelled: task timed out', cancelled: true }));
  }
  assert.equal(breaker.state, 'closed');
});

test('a throwing call is recorded as a failure and the error is passed on', async () => {
  const { breaker } = setup();
  for (let i = 0; i < 3; i += 1) {
    await assert.rejects(breaker.execute(async () => { throw new Error('boom'); }), /boom/);
  }
  assert.equal(breaker.state, 'open');
});

test('refuses a timeout that is not a positive number', () => {
  assert.throws(() => setup({ timeoutMs: 0 }), /timeoutMs/);
});
