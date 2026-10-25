'use strict';

const { test, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const express = require('express');

const { createRegistration, registrationFromEnv } = require('../src/lib/serviceRegistration');

const TOKEN = 'service-token-that-must-never-be-logged-0123456789';

// A clock the test advances by hand: only the next scheduled call is kept, which is
// all the registration ever schedules.
function fakeTimers() {
  const state = { pending: null };
  return {
    state,
    timers: {
      setTimeout(fn, ms) { state.pending = { fn, ms }; return state.pending; },
      clearTimeout(handle) { if (handle && state.pending === handle) state.pending = null; },
    },
    async fire() {
      const { fn } = state.pending;
      state.pending = null;
      await fn();
    },
  };
}

// fetch that answers from a queue and records every call.
function fakeFetch(answers) {
  const calls = [];
  const fn = async (url, options) => {
    calls.push({ url, method: options.method, headers: options.headers, body: options.body && JSON.parse(options.body) });
    const next = answers.shift();
    if (next instanceof Error) throw next;
    return { status: next };
  };
  return { fn, calls };
}

function fakeLog() {
  const lines = [];
  const at = (level) => (fields, message) => lines.push({ level, message, ...fields });
  return { lines, log: { debug: at('debug'), info: at('info'), warn: at('warn'), error: at('error') } };
}

function setup(answers, options = {}) {
  const clock = fakeTimers();
  const http = fakeFetch(answers);
  const logs = fakeLog();
  const registration = createRegistration({
    sdUrl: 'http://service-discovery:3010/',
    serviceName: 'applicant-service',
    instanceId: 'applicant-service-abc123',
    url: 'http://abc123:3003',
    token: () => TOKEN,
    heartbeatMs: 10000,
    log: logs.log,
    fetchFn: http.fn,
    timers: clock.timers,
    ...options,
  });
  return { registration, clock, http, logs };
}

const messages = (logs) => logs.lines.map((line) => `${line.level} ${line.message}`);

test('registers with its url and the service token, then schedules a heartbeat', async () => {
  const { registration, clock, http, logs } = setup([201]);

  await registration.start();

  assert.equal(http.calls.length, 1);
  assert.equal(http.calls[0].method, 'POST');
  assert.equal(http.calls[0].url, 'http://service-discovery:3010/services/register');
  assert.deepEqual(http.calls[0].body, {
    serviceName: 'applicant-service', instanceId: 'applicant-service-abc123', url: 'http://abc123:3003', statusPath: '/status',
  });
  assert.equal(http.calls[0].headers.Authorization, `Bearer ${TOKEN}`);
  assert.equal(registration.isRegistered(), true);
  assert.equal(clock.state.pending.ms, 10000);
  assert.ok(messages(logs).includes('info registered with service discovery'));
});

test('sends a heartbeat every interval, logged at DEBUG', async () => {
  const { registration, clock, http, logs } = setup([201, 200, 200]);
  await registration.start();

  await clock.fire();
  await clock.fire();

  assert.deepEqual(http.calls.slice(1).map((c) => [c.method, c.url]), [
    ['PUT', 'http://service-discovery:3010/services/applicant-service/instances/applicant-service-abc123/heartbeat'],
    ['PUT', 'http://service-discovery:3010/services/applicant-service/instances/applicant-service-abc123/heartbeat'],
  ]);
  assert.equal(logs.lines.filter((l) => l.message === 'heartbeat sent' && l.level === 'debug').length, 2);
  assert.equal(clock.state.pending.ms, 10000);
});

test('a heartbeat answered 404 registers again: Service Discovery lost its registry', async () => {
  const { registration, clock, http, logs } = setup([201, 404, 201]);
  await registration.start();

  await clock.fire();

  assert.deepEqual(http.calls.map((c) => c.method), ['POST', 'PUT', 'POST']);
  assert.ok(messages(logs).includes('warn service discovery does not know this instance, registering again'));
  assert.equal(registration.isRegistered(), true);
  assert.equal(clock.state.pending.ms, 10000);
});

test('while Service Discovery is unreachable it retries with backoff 1, 2, 4 ... capped at 30 s', async () => {
  const down = () => Object.assign(new TypeError('fetch failed'), { cause: { code: 'ECONNREFUSED' } });
  const { registration, clock, logs } = setup([down(), down(), down(), down(), down(), 503, down(), 201]);

  await registration.start();
  const delays = [clock.state.pending.ms];
  for (let i = 0; i < 6; i += 1) {
    await clock.fire();
    delays.push(clock.state.pending.ms);
  }
  await clock.fire();

  assert.deepEqual(delays, [1000, 2000, 4000, 8000, 16000, 30000, 30000]);
  const failed = logs.lines.filter((l) => l.message === 'registration with service discovery failed, retrying');
  assert.equal(failed[0].error, 'ECONNREFUSED');
  assert.equal(failed[0].retryAttempt, 1);
  assert.equal(failed[5].status, 503);
  assert.equal(registration.isRegistered(), true);
  // Back to the heartbeat interval, and the backoff starts again from 1 s next time.
  assert.equal(clock.state.pending.ms, 10000);
});

test('a 401 or 422 is a configuration error: logged at ERROR, never retried', async () => {
  for (const status of [401, 422]) {
    const { registration, clock, logs } = setup([status]);

    await registration.start();

    assert.equal(clock.state.pending, null, `retried after ${status}`);
    assert.equal(logs.lines.at(-1).level, 'error');
    assert.equal(logs.lines.at(-1).status, status);
    assert.equal(registration.isRegistered(), false);
  }
});

test('a failed heartbeat is logged and the next one is still sent', async () => {
  const { registration, clock, http, logs } = setup([201, 503, new Error('socket hang up'), 200]);
  await registration.start();

  await clock.fire();
  await clock.fire();
  await clock.fire();

  assert.deepEqual(http.calls.map((c) => c.method), ['POST', 'PUT', 'PUT', 'PUT']);
  assert.deepEqual(logs.lines.filter((l) => l.message === 'heartbeat failed').map((l) => l.status), [503, null]);
  assert.equal(registration.isRegistered(), true);
});

test('stop deregisters with DELETE and cancels the next heartbeat', async () => {
  const { registration, clock, http, logs } = setup([201, 204]);
  await registration.start();

  await registration.stop();

  assert.deepEqual(http.calls.at(-1).method, 'DELETE');
  assert.equal(http.calls.at(-1).url, 'http://service-discovery:3010/services/applicant-service/instances/applicant-service-abc123');
  assert.equal(clock.state.pending, null);
  assert.ok(messages(logs).includes('info deregistered from service discovery'));
});

test('stop before a successful registration sends nothing and stops the retries', async () => {
  const { registration, clock, http } = setup([503]);
  await registration.start();

  await registration.stop();

  assert.deepEqual(http.calls.map((c) => c.method), ['POST']);
  assert.equal(clock.state.pending, null);
});

test('a failed deregistration is only a warning: eviction removes the instance later', async () => {
  const { registration, logs } = setup([201, new Error('timeout')]);
  await registration.start();

  await registration.stop();

  assert.equal(logs.lines.at(-1).level, 'warn');
  assert.equal(logs.lines.at(-1).message, 'deregistration from service discovery failed');
});

test('the service token is never written to the logs', async () => {
  const { registration, clock, logs } = setup([201, 404, 401]);
  await registration.start();
  await clock.fire();

  assert.equal(JSON.stringify(logs.lines).includes(TOKEN), false);
});

test('registrationFromEnv: off without SERVICE_DISCOVERY_URL, url from the hostname, ADVERTISE_URL overrides', async () => {
  const { log } = fakeLog();
  const args = { serviceName: 'applicant-service', instanceId: 'applicant-service-abc123', hostname: 'abc123', port: 3003, log };
  assert.equal(registrationFromEnv({ ...args, env: {} }), null);

  const bodies = [];
  const original = global.fetch;
  // fetch is read when the registration is created, so it is replaced before that.
  global.fetch = async (url, options) => { bodies.push(options.body && JSON.parse(options.body)); return { status: 201 }; };
  try {
    const fromHostname = registrationFromEnv({ ...args, env: { SERVICE_DISCOVERY_URL: 'http://sd:3010' } });
    const advertised = registrationFromEnv({
      ...args, env: { SERVICE_DISCOVERY_URL: 'http://sd:3010', ADVERTISE_URL: 'http://localhost:3003' },
    });
    await fromHostname.start();
    await advertised.start();
    await fromHostname.stop();
    await advertised.stop();
  } finally {
    global.fetch = original;
  }

  assert.equal(bodies[0].url, 'http://abc123:3003');
  assert.equal(bodies[1].url, 'http://localhost:3003');
});

// ---------- against a real HTTP server ----------

const servers = [];
after(() => Promise.all(servers.map((s) => new Promise((resolve) => s.close(resolve)))));

async function listen(app) {
  const server = http.createServer(app);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  servers.push(server);
  return `http://127.0.0.1:${server.address().port}`;
}

test('over real HTTP: registers, heartbeats, re-registers after a restart, deregisters', async () => {
  const registry = new Map();
  const seen = [];
  const sd = express();
  sd.use(express.json());
  sd.use((req, res, next) => {
    seen.push(`${req.method} ${req.path}`);
    if (req.get('authorization') !== `Bearer ${TOKEN}`) return res.status(401).end();
    return next();
  });
  sd.post('/services/register', (req, res) => {
    const existed = registry.has(req.body.instanceId);
    registry.set(req.body.instanceId, req.body);
    res.status(existed ? 200 : 201).json(req.body);
  });
  sd.put('/services/:name/instances/:id/heartbeat', (req, res) => res.status(registry.has(req.params.id) ? 200 : 404).json({}));
  sd.delete('/services/:name/instances/:id', (req, res) => res.status(registry.delete(req.params.id) ? 204 : 404).end());
  const sdUrl = await listen(sd);

  const { log } = fakeLog();
  const registration = createRegistration({
    sdUrl, serviceName: 'applicant-service', instanceId: 'applicant-service-abc123', url: 'http://abc123:3003',
    token: () => TOKEN, heartbeatMs: 20, log,
  });

  await registration.start();
  assert.ok(registry.has('applicant-service-abc123'));
  await new Promise((resolve) => setTimeout(resolve, 70));
  registry.clear(); // Service Discovery restarts and forgets everything
  await new Promise((resolve) => setTimeout(resolve, 70));
  assert.ok(registry.has('applicant-service-abc123'), 'registered again after a 404 heartbeat');
  await registration.stop();

  assert.equal(registry.size, 0);
  assert.ok(seen.filter((s) => s.startsWith('PUT')).length >= 2);
  assert.equal(seen.filter((s) => s === 'POST /services/register').length, 2);
  assert.equal(seen.at(-1), 'DELETE /services/applicant-service/instances/applicant-service-abc123');
});

test('over real HTTP: a Service Discovery that never answers is a timeout, not a hang', async () => {
  const sd = express();
  sd.post('/services/register', () => {}); // never answers
  const sdUrl = await listen(sd);
  const { lines, log } = fakeLog();
  const registration = createRegistration({
    sdUrl, serviceName: 'applicant-service', instanceId: 'a1', url: 'http://a1:3003',
    token: () => TOKEN, requestTimeoutMs: 50, retryBaseMs: 60000, log,
  });

  await registration.start();
  await registration.stop();

  assert.equal(lines.at(-1).error, 'timeout after 50ms');
});

// ---------- reporting a tripped instance (grade 10) ----------

const { breakerMode, reportInstance, instanceReporterFromEnv } = require('../src/lib/serviceRegistration');

test('BREAKER_MODE is log unless it says remove', () => {
  assert.equal(breakerMode({}), 'log');
  assert.equal(breakerMode({ BREAKER_MODE: 'remove' }), 'remove');
  assert.equal(breakerMode({ BREAKER_MODE: 'REMOVE' }), 'remove');
  assert.equal(breakerMode({ BREAKER_MODE: 'other' }), 'log');
});

test('reportInstance posts reporter and reason with the token, and logs the answer', async () => {
  const http = fakeFetch([202]);
  const logs = fakeLog();

  const status = await reportInstance({
    sdUrl: 'http://service-discovery:3010/', reporter: 'applicant-service',
    targetService: 'university-record-service', targetInstanceId: 'university-record-service-u1',
    reason: '3 failures within the breaker window of 8750 ms', token: () => TOKEN, log: logs.log, fetchFn: http.fn,
    requestId: 'req-trip',
  });

  assert.equal(status, 202);
  assert.equal(http.calls[0].method, 'POST');
  assert.equal(http.calls[0].url,
    'http://service-discovery:3010/services/university-record-service/instances/university-record-service-u1/report');
  assert.deepEqual(http.calls[0].body, { reporter: 'applicant-service', reason: '3 failures within the breaker window of 8750 ms' });
  assert.equal(http.calls[0].headers.Authorization, `Bearer ${TOKEN}`);
  assert.equal(http.calls[0].headers['X-Request-Id'], 'req-trip');
  assert.deepEqual(logs.lines, [{
    level: 'info', message: 'instance reported to service discovery',
    targetService: 'university-record-service', targetInstanceId: 'university-record-service-u1', status: 202,
  }]);
});

test('a report that fails or cannot be sent is a warning, never an exception', async () => {
  const cases = [
    { answers: [404], sdUrl: 'http://sd:3010', status: 404 },
    { answers: [new Error('socket hang up')], sdUrl: 'http://sd:3010', status: null },
    { answers: [], sdUrl: undefined, status: null },
  ];
  for (const { answers, sdUrl, status } of cases) {
    const logs = fakeLog();
    const result = await reportInstance({
      sdUrl, reporter: 'applicant-service', targetService: 'university-record-service', targetInstanceId: 'u1',
      reason: 'x', token: () => TOKEN, log: logs.log, fetchFn: fakeFetch(answers).fn,
    });
    assert.equal(result, status);
    assert.equal(logs.lines[0].level, 'warn');
    assert.equal(logs.lines[0].message, 'instance could not be reported to service discovery');
  }
});

test('instanceReporterFromEnv: nothing in log mode, a report per trip in remove mode', async () => {
  const logs = fakeLog();
  assert.equal(instanceReporterFromEnv({ reporter: 'applicant-service', log: logs.log, env: {} }), undefined);

  const http = fakeFetch([202]);
  const onTrip = instanceReporterFromEnv({
    reporter: 'applicant-service', log: logs.log, fetchFn: http.fn,
    env: { BREAKER_MODE: 'remove', SERVICE_DISCOVERY_URL: 'http://sd:3010' },
  });
  onTrip({ targetService: 'university-record-service', targetInstanceId: 'u1', failures: 3, windowMs: 8750 });
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(http.calls.length, 1);
  assert.equal(http.calls[0].body.reason, '3 failures within the breaker window of 8750 ms');
});
