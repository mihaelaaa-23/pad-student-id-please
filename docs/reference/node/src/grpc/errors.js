'use strict';

// gRPC errors in the team's terms (Communication Contract, "Messaging (Lab 4)", Errors).
// A gRPC status alone is too coarse: UNAVAILABLE is both "the Broker reached no instance"
// and "the service is up but its own dependency is not". So every error also carries the
// team error code in the trailing metadata `x-error-code`, and callers decide on that code,
// exactly as they decide on `error.code` over HTTP.

const grpc = require('@grpc/grpc-js');

const { status } = grpc;

// Team error code -> gRPC status, for errors a service produces.
const STATUS_OF_CODE = {
  NOT_FOUND: status.NOT_FOUND,
  VALIDATION_FAILED: status.INVALID_ARGUMENT,
  CONFLICT: status.ALREADY_EXISTS,
  DEPENDENCY_REFUSED: status.FAILED_PRECONDITION,
  DEPENDENCY_UNAVAILABLE: status.UNAVAILABLE,
  CONCURRENCY_LIMIT_REACHED: status.RESOURCE_EXHAUSTED,
  TASK_TIMEOUT: status.DEADLINE_EXCEEDED,
  UNAUTHORIZED: status.UNAUTHENTICATED,
  INTERNAL_ERROR: status.INTERNAL,
  // EventSink: a topic this service does not handle (the event goes to the Dead Letter Channel).
  ROUTE_NOT_FOUND: status.UNIMPLEMENTED,
};

// The code a caller sees when an error carries no x-error-code (the call never reached a
// service or the Broker answered with a bare status).
const DEFAULT_CODE_OF_STATUS = {
  [status.NOT_FOUND]: 'NOT_FOUND',
  [status.INVALID_ARGUMENT]: 'VALIDATION_FAILED',
  [status.ALREADY_EXISTS]: 'CONFLICT',
  [status.FAILED_PRECONDITION]: 'DEPENDENCY_REFUSED',
  [status.UNAVAILABLE]: 'BAD_GATEWAY',
  [status.RESOURCE_EXHAUSTED]: 'CONCURRENCY_LIMIT_REACHED',
  [status.DEADLINE_EXCEEDED]: 'GATEWAY_TIMEOUT',
  [status.UNIMPLEMENTED]: 'ROUTE_NOT_FOUND',
  [status.UNAUTHENTICATED]: 'UNAUTHORIZED',
  [status.INTERNAL]: 'INTERNAL_ERROR',
};

/**
 * An error a gRPC handler throws (or rejects with) to answer with a team error code:
 * `throw grpcError('NOT_FOUND', 'applicant a1 does not exist')`.
 */
function grpcError(code, message) {
  const err = new Error(message);
  err.code = STATUS_OF_CODE[code] ?? status.INTERNAL;
  err.details = message;
  err.teamCode = STATUS_OF_CODE[code] === undefined ? 'INTERNAL_ERROR' : code;
  const metadata = new grpc.Metadata();
  metadata.set('x-error-code', err.teamCode);
  err.metadata = metadata;
  return err;
}

function statusName(code) {
  return Object.keys(status).find((name) => status[name] === code) || String(code);
}

/**
 * What a failed call means for the caller, in the outcome model the Lab 3 HTTP clients
 * already use, so controllers keep their 502/503 answers:
 *
 *   not_found     the callee answered that the resource does not exist (a real answer)
 *   conflict      the callee answered ALREADY_EXISTS
 *   misconfigured the request can never succeed as sent (VALIDATION_FAILED,
 *                 DEPENDENCY_REFUSED, unknown method, rejected token): answer 502 DEPENDENCY_REFUSED
 *   unavailable   anything else (no instance, breaker open, timeout, busy, internal error):
 *                 answer 503 DEPENDENCY_UNAVAILABLE
 */
function classify(code) {
  if (code === 'NOT_FOUND') return 'not_found';
  if (code === 'CONFLICT') return 'conflict';
  if (['VALIDATION_FAILED', 'DEPENDENCY_REFUSED', 'ROUTE_NOT_FOUND', 'UNAUTHORIZED'].includes(code)) return 'misconfigured';
  return 'unavailable';
}

module.exports = { grpcError, classify, statusName, STATUS_OF_CODE, DEFAULT_CODE_OF_STATUS };
