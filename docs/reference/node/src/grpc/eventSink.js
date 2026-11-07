'use strict';

// `events.v1.EventSink/Deliver`: how a subscribing service receives topic events
// (Lab 4, grades 6 and 9; Communication Contract, "Topics and events").
//
// The Broker pushes each event to one instance of each subscribing service and removes it
// from its queue only after OK. Delivery is at-least-once: after a Broker restart or a lost
// answer the same event arrives again, so the handler must be idempotent (Idempotent
// Receiver). The id of every processed event is kept in the service's own database, and a
// second delivery of it is answered `duplicate: true` without running the handler again.
//
// What the answer tells the Broker:
//   OK                         delivered, removed from the queue
//   INVALID_ARGUMENT,          can never succeed (bad payload, topic this service does not
//   UNIMPLEMENTED, NOT_FOUND,  handle): moved to the Dead Letter Channel at once
//   FAILED_PRECONDITION
//   any other error            retried with backoff, then the Dead Letter Channel

const { logger } = require('../lib/logger');
const { grpcError } = require('./errors');

/**
 * @param {object} options
 * @param {Object<string, Function>} options.topics  topic -> async (payload, event, ctx) => void
 * @param {{has: (id: string) => Promise<boolean>, add: (id: string, topic: string) => Promise<void>}} options.processed
 *   the processed event ids, in the service's own database: a collection with a unique
 *   index on the id in MongoDB, a table with a primary key in PostgreSQL. When the handler
 *   writes, record the id in the same transaction if the database allows it; otherwise
 *   `add` runs right after the handler succeeds.
 * @returns the `Deliver` handler for createGrpcServer
 */
function eventSinkHandler({ topics, processed, log = logger }) {
  return async function Deliver(event, ctx) {
    const fields = { topic: event.topic, eventId: event.id, source: event.source };
    const handle = topics[event.topic];
    if (!handle) {
      log.warn(fields, 'event for a topic this service does not handle');
      throw grpcError('ROUTE_NOT_FOUND', `This service does not handle ${event.topic}`);
    }
    if (!event.id) throw grpcError('VALIDATION_FAILED', 'The event has no id');

    if (await processed.has(event.id)) {
      log.info(fields, 'event already processed, ignored');
      return { duplicate: true };
    }

    let payload;
    try {
      payload = JSON.parse(Buffer.from(event.payload || []).toString('utf8'));
    } catch {
      log.warn(fields, 'event payload is not JSON');
      throw grpcError('VALIDATION_FAILED', 'The payload is not JSON');
    }

    // A grpcError thrown by the handler keeps its code (VALIDATION_FAILED for a payload
    // that can never be applied); anything else is INTERNAL, which the Broker retries.
    await handle(payload, event, ctx);
    await processed.add(event.id, event.topic);
    log.info(fields, 'event processed');
    return { duplicate: false };
  };
}

/** In-memory processed ids, for tests and for trying things out. Not for a service: it is lost on restart. */
function memoryProcessed() {
  const ids = new Set();
  return {
    has: async (id) => ids.has(id),
    add: async (id) => { ids.add(id); },
    size: () => ids.size,
  };
}

module.exports = { eventSinkHandler, memoryProcessed };
