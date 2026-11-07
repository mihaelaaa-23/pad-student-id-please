'use strict';

// Publishing events to a topic through the Message Broker (Lab 4, grade 6;
// Communication Contract, "Topics and events").
//
// The publisher does not know who listens: it sends the event to `broker.v1.Broker/Publish`,
// which stores one delivery per subscribing service before it answers. The event id is
// chosen here, so a Publish that timed out can be sent again with the same id and the
// Broker stores it once.
//
// Publish after your own write is committed, and never fail the request because of it:
// the event is a consequence of the request, not part of it. A failure is logged at ERROR.

const crypto = require('node:crypto');
const grpc = require('@grpc/grpc-js');
const { logger, currentContext } = require('../lib/logger');
const { loadProtos } = require('./protos');
const { statusName } = require('./errors');

const { status } = grpc;
const TOPIC_PATTERN = /^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$/;
// Worth sending again with the same id: the Broker may not have stored it.
const RETRYABLE = new Set([status.UNAVAILABLE, status.DEADLINE_EXCEEDED]);

function timestampOf(ms) {
  return { seconds: String(Math.floor(ms / 1000)), nanos: (ms % 1000) * 1e6 };
}

/**
 * @param {object} options
 * @param {string} options.brokerUrl host:port of the Broker's gRPC server (BROKER_GRPC_URL)
 * @param {string} options.source    this service's name, e.g. 'applicant-service'
 * @param {number} options.timeoutMs deadline of one Publish attempt
 * @param {number} options.attempts  Publish attempts, with the same event id (default 2)
 */
function createPublisher({
  brokerUrl,
  source,
  timeoutMs = 2000,
  attempts = 2,
  token = () => process.env.SERVICE_TOKEN,
  protoDir,
  log = logger,
  now = Date.now,
}) {
  const { broker } = loadProtos(['broker/v1/broker.proto'], protoDir);
  const client = new broker.v1.Broker(brokerUrl, grpc.credentials.createInsecure());

  function send(event, metadata) {
    return new Promise((resolve) => {
      client.Publish(event, metadata, { deadline: Date.now() + timeoutMs }, (err, ack) => resolve({ err, ack }));
    });
  }

  /**
   * Never throws. Resolves to {ok: true, eventId, subscribers, duplicate} or
   * {ok: false, eventId, grpcCode, error}.
   */
  async function publish(topic, payload) {
    const requestId = currentContext()?.requestId || crypto.randomUUID();
    const eventId = crypto.randomUUID();
    if (!TOPIC_PATTERN.test(topic)) {
      log.error({ topic, eventId }, 'event not published: invalid topic name');
      return { ok: false, eventId, grpcCode: 'INVALID_ARGUMENT', error: 'invalid topic name' };
    }
    const event = {
      id: eventId,
      topic,
      source,
      requestId,
      timestamp: timestampOf(now()),
      payload: Buffer.from(JSON.stringify(payload)),
      contentType: 'application/json',
    };
    const metadata = new grpc.Metadata();
    metadata.set('x-request-id', requestId);
    metadata.set('x-caller-type', 'service');
    const secret = token();
    if (secret) metadata.set('authorization', `Bearer ${secret}`);

    let last;
    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      const startedAt = process.hrtime.bigint();
      last = await send(event, metadata);
      const durationMs = Math.round(Number(process.hrtime.bigint() - startedAt) / 1e6);
      if (!last.err) {
        const subscribers = last.ack.subscribers || [];
        const message = subscribers.length ? 'event published' : 'event published with no subscribers';
        log.info({ topic, eventId, subscribers, duplicate: last.ack.duplicate, attempt, durationMs }, message);
        return { ok: true, eventId, subscribers, duplicate: Boolean(last.ack.duplicate) };
      }
      if (!RETRYABLE.has(last.err.code) || attempt === attempts) break;
      log.warn({ topic, eventId, attempt, grpcCode: statusName(last.err.code), durationMs }, 'event publish failed, sending again');
    }
    const grpcCode = statusName(last.err.code);
    log.error({ topic, eventId, grpcCode, error: last.err.details }, 'event publish failed');
    return { ok: false, eventId, grpcCode, error: last.err.details };
  }

  return { publish, close: () => client.close() };
}

/** BROKER_GRPC_URL set: a publisher; unset: null (the service publishes nothing). */
function publisherFromEnv({ source, env = process.env, log = logger }) {
  if (!env.BROKER_GRPC_URL) return null;
  const timeout = Number(env.HTTP_TIMEOUT_MS);
  return createPublisher({
    brokerUrl: env.BROKER_GRPC_URL,
    source,
    timeoutMs: Number.isInteger(timeout) && timeout > 0 ? timeout : 2000,
    log,
  });
}

module.exports = { createPublisher, publisherFromEnv, TOPIC_PATTERN };
