'use strict';

// Calls to another service over gRPC, through the Message Broker (Lab 4, grade 8).
//
// The caller uses the generated client of the callee's own proto (for example
// applicant.v1.ApplicantService) but connects it to the Broker (BROKER_GRPC_URL). The Broker
// reads the full method name, picks an instance, applies the circuit breaker and forwards
// the bytes unchanged, so the payload stays typed end to end and the Broker needs no stubs.
//
// Like the Lab 3 HTTP client, a call never throws: it resolves to an outcome the controller
// turns into its usual answer (see errors.classify).

const crypto = require('node:crypto');
const grpc = require('@grpc/grpc-js');
const { logger, currentContext } = require('../lib/logger');
const { classify, statusName, DEFAULT_CODE_OF_STATUS } = require('./errors');

const { status } = grpc;

function first(metadata, key) {
  const values = metadata ? metadata.get(key) : [];
  return values.length ? String(values[0]) : undefined;
}

/**
 * @param {object} options
 * @param {Function} options.Service      the callee's client constructor, e.g. pkg.applicant.v1.ApplicantService
 * @param {string}   options.targetService the callee's service name, for the logs
 * @param {string}   options.brokerUrl     host:port of the Broker's gRPC server (BROKER_GRPC_URL)
 * @param {number}   options.timeoutMs     HTTP_TIMEOUT_MS: sent as the call's deadline
 * @param {() => string|undefined} options.token the service token, read per call, never logged
 */
function createBrokerClient({
  Service,
  targetService,
  brokerUrl,
  timeoutMs = 2000,
  token = () => process.env.SERVICE_TOKEN,
  log = logger,
}) {
  // One client per callee for the process; grpc-js keeps one HTTP/2 connection to the
  // Broker and multiplexes every call over it.
  const client = new Service(brokerUrl, grpc.credentials.createInsecure());

  /**
   * @returns {Promise<{ok: true, response: object, instanceId?: string}
   *   | {ok: false, kind: string, code: string, grpcCode: string, message: string,
   *      instanceId?: string, retryAfterSeconds?: number}>}
   */
  function call(method, request) {
    const definition = Service.service[method];
    if (!definition) throw new Error(`${targetService} has no RPC ${method}`);
    const fullMethod = definition.path;

    const metadata = new grpc.Metadata();
    metadata.set('x-request-id', currentContext()?.requestId || crypto.randomUUID());
    metadata.set('x-caller-type', 'service');
    const secret = token();
    if (secret) metadata.set('authorization', `Bearer ${secret}`);

    const fields = { targetService, method: fullMethod };
    log.info({ ...fields, timeoutMs }, 'outgoing call started');
    const startedAt = process.hrtime.bigint();

    return new Promise((resolve) => {
      let response;
      // grpc-js emits 'status' after the callback, with the trailing metadata of both a
      // success and an error, so the outcome is settled there.
      const pending = client[method](request, metadata, { deadline: Date.now() + timeoutMs }, (err, value) => {
        response = value;
      });
      pending.on('status', ({ code, details, metadata: trailer }) => {
        const durationMs = Math.round(Number(process.hrtime.bigint() - startedAt) / 1e6);
        const instanceId = first(trailer, 'x-instance-id');
        if (code === status.OK) {
          log.info({ ...fields, grpcCode: 'OK', targetInstanceId: instanceId, durationMs }, 'outgoing call finished');
          resolve({ ok: true, response, instanceId });
          return;
        }
        const teamCode = first(trailer, 'x-error-code') || DEFAULT_CODE_OF_STATUS[code] || 'INTERNAL_ERROR';
        const retryAfter = Number(first(trailer, 'retry-after'));
        const kind = classify(teamCode);
        log[kind === 'not_found' || kind === 'conflict' ? 'info' : 'warn']({
          ...fields,
          grpcCode: statusName(code),
          error: teamCode,
          targetInstanceId: instanceId,
          durationMs,
        }, 'outgoing call finished');
        resolve({
          ok: false,
          kind,
          code: teamCode,
          grpcCode: statusName(code),
          message: details,
          instanceId,
          ...(Number.isFinite(retryAfter) && retryAfter > 0 ? { retryAfterSeconds: retryAfter } : {}),
        });
      });
    });
  }

  return { call, close: () => client.close() };
}

/** BROKER_GRPC_URL, e.g. message-broker:50011; HTTP_TIMEOUT_MS as the deadline. */
function brokerClientFromEnv({ Service, targetService, env = process.env, log = logger }) {
  if (!env.BROKER_GRPC_URL) return null;
  const timeout = Number(env.HTTP_TIMEOUT_MS);
  return createBrokerClient({
    Service,
    targetService,
    brokerUrl: env.BROKER_GRPC_URL,
    timeoutMs: Number.isInteger(timeout) && timeout > 0 ? timeout : 2000,
    log,
  });
}

module.exports = { createBrokerClient, brokerClientFromEnv };
