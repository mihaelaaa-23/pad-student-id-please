'use strict';

// Loads the contract's .proto files at runtime (Communication Contract, "Proto files in the
// service repos"): no code generation step, so the Dockerfile stays as it is. Every
// service copies `proto/` from the CPR at a pinned commit into its own repo root.

const path = require('node:path');
const grpc = require('@grpc/grpc-js');
const protoLoader = require('@grpc/proto-loader');

// The options the contract fixes, so every Node service sees the same shapes:
// camelCase field names (applicantId, like the REST JSON), 64-bit numbers as strings,
// enums as names, unset fields as their defaults. oneofs is false: the contract has no real
// oneof, and `true` would add a synthetic `_year: 'year'` key for every proto3 `optional`
// field, which would then leak into REST answers. An unset optional field (year for a
// non-student) arrives absent: read it as `year ?? null`.
const LOADER_OPTIONS = { keepCase: false, longs: String, enums: String, defaults: true, oneofs: false };

// <repo>/proto when this file sits in <repo>/src/grpc; PROTO_DIR overrides it.
function protoDir(env = process.env) {
  return env.PROTO_DIR || path.resolve(__dirname, '../../proto');
}

const cache = new Map();

/**
 * The gRPC package object for the given files, e.g.
 * `loadProtos(['applicant/v1/applicant.proto']).applicant.v1.ApplicantService`.
 * Imports between contract files (credential imports applicant) resolve from the proto dir.
 */
function loadProtos(files, dir = protoDir()) {
  const key = `${dir}|${files.join(',')}`;
  if (!cache.has(key)) {
    const definition = protoLoader.loadSync(files, { ...LOADER_OPTIONS, includeDirs: [dir] });
    cache.set(key, grpc.loadPackageDefinition(definition));
  }
  return cache.get(key);
}

module.exports = { loadProtos, protoDir, LOADER_OPTIONS };
