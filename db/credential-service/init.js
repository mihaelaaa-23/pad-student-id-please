// Runs once, on a first start against an empty volume, from
// /docker-entrypoint-initdb.d/. MongoDB is schema-on-read, so the shape is
// enforced twice: at the API boundary with Zod, and here with a JSON Schema
// validator, which also protects data written by any other client.

const targetDb = db.getSiblingDB(process.env.MONGO_INITDB_DATABASE || 'credential_service_db');

targetDb.createCollection('credentials', {
  validator: {
    $jsonSchema: {
      bsonType: 'object',
      required: [
        'applicantId',
        'studentId',
        'holderName',
        'issuedAt',
        'expiresAt',
        'signature',
        'documents',
        'createdAt',
      ],
      properties: {
        applicantId: { bsonType: 'string' },
        studentId: { bsonType: 'string' },
        holderName: { bsonType: 'string' },
        issuedAt: { bsonType: 'string' },
        expiresAt: { bsonType: 'string' },
        // HMAC over the canonical credential fields. Required, because a
        // credential without one cannot be checked for authenticity at all.
        signature: { bsonType: 'string' },
        // Which documents exist varies by role, so the keys are not fixed.
        documents: { bsonType: 'object' },
        // Snapshot of the applicant this credential belongs to, used for the
        // consistency checks.
        applicantCore: { bsonType: 'object' },
        createdAt: { bsonType: 'string' },
      },
    },
  },
  // Reject writes that break the schema rather than logging and accepting them.
  validationLevel: 'strict',
  validationAction: 'error',
});

// One credential set per applicant: applicantId is the key, and it is the shared
// key across Applicant, Credential and University Record Service.
targetDb.credentials.createIndex({ applicantId: 1 }, { unique: true });

// Deliberately NOT unique: an impersonator presents a card carrying someone
// else's student id, so duplicates are a scenario the game requires.
targetDb.credentials.createIndex({ studentId: 1 });

print('credential_service_db initialised: validator and indexes created');

// Lab 5, grade 4: the read-only user the ETL job reads this database with, through
// the replica set's secondaries. Created in admin (the ETL authenticates with
// authSource=admin) with role read on this database only, so the warehouse load
// can never write here. Skipped when ETL_READER_PASSWORD is unset (a standalone run
// of this script); the password is never printed.
const etlReaderPassword = process.env.ETL_READER_PASSWORD;
if (etlReaderPassword) {
  const adminDb = db.getSiblingDB('admin');
  if (!adminDb.getUser('etl_reader')) {
    adminDb.createUser({
      user: 'etl_reader',
      pwd: etlReaderPassword,
      roles: [{ role: 'read', db: targetDb.getName() }],
    });
  }
  print('etl_reader ready (read on ' + targetDb.getName() + ')');
}
