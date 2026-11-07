'use strict';

// The gRPC reference against the real contract protos (proto/ in the CPR), with in-process
// servers on ephemeral ports. The Broker is a transparent proxy for request/response, so a
// client pointed straight at a service's server sees the same method names and metadata.

const { test, after } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const grpc = require('@grpc/grpc-js');

const PROTO_DIR = path.resolve(__dirname, '../../../../proto');
process.env.PROTO_DIR = PROTO_DIR;

const { captureLogs, runWithContext } = require('../src/lib/logger');
const { loadProtos } = require('../src/grpc/protos');
const { createGrpcServer, createLimiter } = require('../src/grpc/server');
const { createBrokerClient, brokerClientFromEnv } = require('../src/grpc/brokerClient');
const { createPublisher } = require('../src/grpc/publisher');
const { eventSinkHandler, memoryProcessed } = require('../src/grpc/eventSink');
const { grpcError, classify } = require('../src/grpc/errors');

const TOKEN = 'service-token-that-must-never-be-logged-0123456789';
const pkg = loadProtos(['applicant/v1/applicant.proto', 'events/v1/events.proto', 'broker/v1/broker.proto'], PROTO_DIR);
const { ApplicantService } = pkg.applicant.v1;

const cleanup = [];
after(async () => { for (const fn of cleanup.reverse()) await fn(); });

async function serve(services, options = {}) {
  const server = createGrpcServer({ port: 0, host: '127.0.0.1', services, ...options });
  const port = await server.start();
  cleanup.push(() => server.stop(100));
  return `127.0.0.1:${port}`;
}

function applicantClient(url, timeoutMs = 1000) {
  const client = createBrokerClient({ Service: ApplicantService, targetService: 'applicant-service', brokerUrl: url, timeoutMs, token: () => TOKEN });
  cleanup.push(async () => client.close());
  return client;
}

const sleep = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });

const APPLICANT = { applicantId: 'a1', name: 'Ana Rusu', studentId: 'FAF-232-01', major: 'Software Engineering', year: 3, role: 'student_faf', status: 'enrolled' };

// ---------- request/response ----------

test('a call reaches the server with the request id, caller type and camelCase fields', async () => {
  const seen = [];
  const url = await serve([{ service: ApplicantService.service, handlers: {
    GetApplicant: async (request, ctx) => {
      seen.push({ request, requestId: ctx.metadata.get('x-request-id')[0], caller: ctx.metadata.get('x-caller-type')[0] });
      return APPLICANT;
    },
  } }]);

  const outcome = await runWithContext({ requestId: 'req-42' }, () => applicantClient(url).call('GetApplicant', { applicantId: 'a1' }));

  assert.equal(outcome.ok, true);
  assert.deepEqual(outcome.response, APPLICANT);
  assert.match(outcome.instanceId, /^applicant-service-/);
  assert.deepEqual(seen, [{ request: { applicantId: 'a1' }, requestId: 'req-42', caller: 'service' }]);
});

test('every line the handler logs carries the caller\'s request id', async () => {
  const url = await serve([{ service: ApplicantService.service, handlers: { GetApplicant: async () => APPLICANT } }]);
  const logs = captureLogs();
  try {
    await runWithContext({ requestId: 'req-trace' }, () => applicantClient(url).call('GetApplicant', { applicantId: 'a1' }));
  } finally {
    logs.restore();
  }

  const messages = logs.lines.map((line) => line.message);
  for (const message of ['outgoing call started', 'grpc request received', 'grpc request completed', 'outgoing call finished']) {
    assert.ok(messages.includes(message), message);
  }
  for (const line of logs.lines.filter((l) => l.message !== 'grpc server listening')) {
    assert.equal(line.requestId, 'req-trace', line.message);
  }
  const completed = logs.lines.find((line) => line.message === 'grpc request completed');
  assert.equal(completed.method, '/applicant.v1.ApplicantService/GetApplicant');
  assert.equal(completed.grpcCode, 'OK');
  assert.equal(JSON.stringify(logs.lines).includes(TOKEN), false, 'the service token is never logged');
});

test('a team error code travels in x-error-code and maps to the outcome model', async () => {
  const url = await serve([{ service: ApplicantService.service, handlers: {
    GetApplicant: async ({ applicantId }) => { throw grpcError('NOT_FOUND', `applicant ${applicantId} does not exist`); },
    GenerateApplicant: async () => { throw grpcError('DEPENDENCY_UNAVAILABLE', 'university record is down'); },
  } }]);
  const client = applicantClient(url);

  const missing = await client.call('GetApplicant', { applicantId: 'nobody' });
  const down = await client.call('GenerateApplicant', {});

  assert.deepEqual(
    { ok: missing.ok, kind: missing.kind, code: missing.code, grpcCode: missing.grpcCode, message: missing.message },
    { ok: false, kind: 'not_found', code: 'NOT_FOUND', grpcCode: 'NOT_FOUND', message: 'applicant nobody does not exist' },
  );
  assert.equal(down.grpcCode, 'UNAVAILABLE');
  assert.equal(down.code, 'DEPENDENCY_UNAVAILABLE');
  assert.equal(down.kind, 'unavailable');
});

test('an unexpected error is INTERNAL with a generic message, and logged with its stack', async () => {
  const url = await serve([{ service: ApplicantService.service, handlers: {
    GetApplicant: async () => { throw new Error('mongo exploded: secret detail'); },
  } }]);
  const logs = captureLogs();
  let outcome;
  try {
    outcome = await applicantClient(url).call('GetApplicant', { applicantId: 'a1' });
  } finally {
    logs.restore();
  }

  assert.equal(outcome.code, 'INTERNAL_ERROR');
  assert.equal(outcome.message, 'Internal error');
  assert.ok(logs.lines.some((line) => line.message === 'grpc handler failed' && line.stack));
});

test('a method without a handler is UNIMPLEMENTED, which the caller treats as misconfigured', async () => {
  const url = await serve([{ service: ApplicantService.service, handlers: { GetApplicant: async () => APPLICANT } }]);

  const outcome = await applicantClient(url).call('GenerateApplicant', {});

  assert.equal(outcome.grpcCode, 'UNIMPLEMENTED');
  assert.equal(outcome.kind, 'misconfigured');
});

test('the caller\'s deadline: a slow handler is DEADLINE_EXCEEDED and the handler is told to stop', async () => {
  let aborted = false;
  const url = await serve([{ service: ApplicantService.service, handlers: {
    GetApplicant: async (_request, ctx) => {
      ctx.signal.addEventListener('abort', () => { aborted = true; });
      await sleep(500);
      return APPLICANT;
    },
  } }]);

  const outcome = await applicantClient(url, 150).call('GetApplicant', { applicantId: 'a1' });
  await sleep(50);

  assert.equal(outcome.grpcCode, 'DEADLINE_EXCEEDED');
  assert.equal(outcome.kind, 'unavailable');
  assert.equal(aborted, true);
});

test('the task timeout answers DEADLINE_EXCEEDED with TASK_TIMEOUT before the caller\'s deadline', async () => {
  const url = await serve(
    [{ service: ApplicantService.service, handlers: { GetApplicant: async () => { await sleep(500); return APPLICANT; } } }],
    { taskTimeoutMs: 100 },
  );

  const outcome = await applicantClient(url, 2000).call('GetApplicant', { applicantId: 'a1' });

  assert.equal(outcome.grpcCode, 'DEADLINE_EXCEEDED');
  assert.equal(outcome.code, 'TASK_TIMEOUT');
  assert.match(outcome.instanceId, /^applicant-service-/);
});

test('above the concurrency limit: RESOURCE_EXHAUSTED with CONCURRENCY_LIMIT_REACHED', async () => {
  const limiter = createLimiter(1);
  const url = await serve(
    [{ service: ApplicantService.service, handlers: { GetApplicant: async () => { await sleep(200); return APPLICANT; } } }],
    { limiter },
  );
  const client = applicantClient(url);

  const [first, second] = await Promise.all([
    client.call('GetApplicant', { applicantId: 'a1' }),
    sleep(50).then(() => client.call('GetApplicant', { applicantId: 'a2' })),
  ]);

  assert.equal(first.ok, true);
  assert.equal(second.grpcCode, 'RESOURCE_EXHAUSTED');
  assert.equal(second.code, 'CONCURRENCY_LIMIT_REACHED');
  assert.equal(limiter.inFlight(), 0, 'every slot is released');
});

test('no Broker listening: UNAVAILABLE, never a throw', async () => {
  const outcome = await applicantClient('127.0.0.1:1', 300).call('GetApplicant', { applicantId: 'a1' });

  assert.equal(outcome.ok, false);
  assert.equal(outcome.grpcCode, 'UNAVAILABLE');
  assert.equal(outcome.kind, 'unavailable');
});

test('the Broker\'s CIRCUIT_OPEN carries retry-after to the caller', async () => {
  // A stand-in for the Broker answering with an open breaker.
  const url = await serve([{ service: ApplicantService.service, handlers: {
    GetApplicant: async () => {
      const err = grpcError('DEPENDENCY_UNAVAILABLE', 'applicant-service is unavailable: its circuit breaker is open');
      err.metadata.set('x-error-code', 'CIRCUIT_OPEN');
      err.metadata.set('retry-after', '12');
      err.teamCode = 'CIRCUIT_OPEN';
      throw err;
    },
  } }]);

  const outcome = await applicantClient(url).call('GetApplicant', { applicantId: 'a1' });

  assert.equal(outcome.code, 'CIRCUIT_OPEN');
  assert.equal(outcome.kind, 'unavailable');
  assert.equal(outcome.retryAfterSeconds, 12);
});

test('classify keeps the Lab 3 answers: refused requests are misconfigured, the rest unavailable', () => {
  assert.equal(classify('NOT_FOUND'), 'not_found');
  assert.equal(classify('CONFLICT'), 'conflict');
  for (const code of ['VALIDATION_FAILED', 'DEPENDENCY_REFUSED', 'ROUTE_NOT_FOUND', 'UNAUTHORIZED']) {
    assert.equal(classify(code), 'misconfigured', code);
  }
  for (const code of ['BAD_GATEWAY', 'CIRCUIT_OPEN', 'GATEWAY_TIMEOUT', 'TASK_TIMEOUT', 'CONCURRENCY_LIMIT_REACHED', 'DEPENDENCY_UNAVAILABLE', 'INTERNAL_ERROR']) {
    assert.equal(classify(code), 'unavailable', code);
  }
});

test('brokerClientFromEnv is off without BROKER_GRPC_URL', () => {
  assert.equal(brokerClientFromEnv({ Service: ApplicantService, targetService: 'applicant-service', env: {} }), null);
});

// ---------- publishing ----------

function fakeBroker(answer) {
  const received = [];
  return {
    received,
    service: pkg.broker.v1.Broker.service,
    handlers: {
      Publish: async (event, ctx) => {
        received.push({ event, authorization: ctx.metadata.get('authorization')[0], requestId: ctx.metadata.get('x-request-id')[0] });
        return answer(event, received.length);
      },
    },
  };
}

test('publish sends the contract envelope with a fresh id, the request id and JSON bytes', async () => {
  const broker = fakeBroker(() => ({ eventId: 'ignored', subscribers: ['university-record-service'], duplicate: false }));
  const url = await serve([broker]);
  const publisher = createPublisher({ brokerUrl: url, source: 'applicant-service', token: () => TOKEN, protoDir: PROTO_DIR, now: () => 1762524312481 });
  cleanup.push(async () => publisher.close());

  const result = await runWithContext({ requestId: 'req-pub' }, () => publisher.publish('applicant.created', { applicantId: 'a1' }));

  assert.equal(result.ok, true);
  assert.deepEqual(result.subscribers, ['university-record-service']);
  const [{ event, authorization, requestId }] = broker.received;
  assert.match(event.id, /^[0-9a-f-]{36}$/);
  assert.equal(event.id, result.eventId);
  assert.equal(event.topic, 'applicant.created');
  assert.equal(event.source, 'applicant-service');
  assert.equal(event.requestId, 'req-pub');
  assert.equal(requestId, 'req-pub');
  assert.deepEqual(event.timestamp, { seconds: '1762524312', nanos: 481000000 });
  assert.deepEqual(JSON.parse(event.payload.toString('utf8')), { applicantId: 'a1' });
  assert.equal(event.contentType, 'application/json');
  assert.equal(authorization, `Bearer ${TOKEN}`);
});

test('a publish that fails with UNAVAILABLE is sent again with the same event id', async () => {
  const broker = fakeBroker((_event, n) => {
    if (n === 1) throw grpcError('DEPENDENCY_UNAVAILABLE', 'busy');
    return { subscribers: ['university-record-service'] };
  });
  const url = await serve([broker]);
  const publisher = createPublisher({ brokerUrl: url, source: 'applicant-service', token: () => TOKEN, protoDir: PROTO_DIR });
  cleanup.push(async () => publisher.close());

  const result = await publisher.publish('applicant.created', { applicantId: 'a1' });

  assert.equal(result.ok, true);
  assert.equal(broker.received.length, 2);
  assert.equal(broker.received[0].event.id, broker.received[1].event.id);
});

test('a rejected publish is logged at ERROR and resolves, never throws', async () => {
  const broker = fakeBroker(() => { throw grpcError('VALIDATION_FAILED', 'unknown topic session.endd'); });
  const url = await serve([broker]);
  const publisher = createPublisher({ brokerUrl: url, source: 'session-service', token: () => TOKEN, protoDir: PROTO_DIR });
  cleanup.push(async () => publisher.close());
  const logs = captureLogs();
  let result;
  try {
    result = await publisher.publish('session.endd', {});
  } finally {
    logs.restore();
  }

  assert.equal(result.ok, false);
  assert.equal(result.grpcCode, 'INVALID_ARGUMENT');
  assert.equal(broker.received.length, 1, 'a rejection is not sent again');
  assert.ok(logs.lines.some((line) => line.level === 'ERROR' && line.message === 'event publish failed'));
});

test('an invalid topic name is refused before anything is sent', async () => {
  const publisher = createPublisher({ brokerUrl: '127.0.0.1:1', source: 'applicant-service', protoDir: PROTO_DIR });
  cleanup.push(async () => publisher.close());

  const result = await publisher.publish('ApplicantCreated', {});

  assert.equal(result.ok, false);
  assert.equal(result.grpcCode, 'INVALID_ARGUMENT');
});

// ---------- receiving events ----------

async function sink(topics, processed = memoryProcessed()) {
  const url = await serve([{ service: pkg.events.v1.EventSink.service, handlers: { Deliver: eventSinkHandler({ topics, processed }) } }]);
  const client = new pkg.events.v1.EventSink(url, grpc.credentials.createInsecure());
  cleanup.push(async () => client.close());
  const deliver = (event) => new Promise((resolve) => {
    client.Deliver(event, new grpc.Metadata(), { deadline: Date.now() + 1000 }, (err, ack) => resolve({ err, ack }));
  });
  return { deliver, processed };
}

function eventOf(topic, payload, id = '0b0e8a2e-2c1f-4f7e-9d38-4b8f1a9c2d11') {
  return { id, topic, source: 'applicant-service', requestId: 'req-ev', payload: Buffer.from(JSON.stringify(payload)), contentType: 'application/json' };
}

test('an event is handled once: a redelivery of the same id is answered duplicate', async () => {
  const handled = [];
  const { deliver, processed } = await sink({ 'applicant.created': async (payload) => { handled.push(payload); } });
  const event = eventOf('applicant.created', { applicantId: 'a1' });

  const first = await deliver(event);
  const again = await deliver(event);

  assert.equal(first.err, null);
  assert.equal(first.ack.duplicate, false);
  assert.equal(again.ack.duplicate, true);
  assert.deepEqual(handled, [{ applicantId: 'a1' }]);
  assert.equal(processed.size(), 1);
});

test('a topic the service does not handle is UNIMPLEMENTED: the Broker dead-letters it', async () => {
  const { deliver } = await sink({ 'applicant.created': async () => {} });

  const { err } = await deliver(eventOf('session.ended', {}));

  assert.equal(err.code, grpc.status.UNIMPLEMENTED);
});

test('a payload that is not JSON is INVALID_ARGUMENT and the handler does not run', async () => {
  let ran = false;
  const { deliver } = await sink({ 'applicant.created': async () => { ran = true; } });

  const { err } = await deliver({ ...eventOf('applicant.created', {}), payload: Buffer.from('{not json') });

  assert.equal(err.code, grpc.status.INVALID_ARGUMENT);
  assert.equal(ran, false);
});

test('a handler that fails is INTERNAL, the id is not recorded, and the redelivery succeeds', async () => {
  let calls = 0;
  const { deliver, processed } = await sink({
    'applicant.created': async () => { calls += 1; if (calls === 1) throw new Error('database briefly down'); },
  });
  const event = eventOf('applicant.created', { applicantId: 'a1' });

  const failed = await deliver(event);
  assert.equal(failed.err.code, grpc.status.INTERNAL);
  assert.equal(processed.size(), 0);

  const retried = await deliver(event);
  assert.equal(retried.err, null);
  assert.equal(retried.ack.duplicate, false);
  assert.equal(calls, 2);
});

test('an unset optional field arrives absent, with no synthetic oneof key; 0 stays 0', async () => {
  const answers = { staff: { ...APPLICANT, applicantId: 's1', year: null, role: 'staff' }, zero: { ...APPLICANT, applicantId: 'z1', year: 0 } };
  const url = await serve([{ service: ApplicantService.service, handlers: { GetApplicant: async ({ applicantId }) => answers[applicantId] } }]);
  const client = applicantClient(url);

  const staff = (await client.call('GetApplicant', { applicantId: 'staff' })).response;
  const zero = (await client.call('GetApplicant', { applicantId: 'zero' })).response;

  assert.equal('year' in staff, false);
  assert.equal(staff.year ?? null, null);
  assert.equal(zero.year, 0);
  assert.equal(Object.keys(staff).some((key) => key.startsWith('_')), false);
});
