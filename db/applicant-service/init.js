// Runs once, on a first start against an empty volume, from
// /docker-entrypoint-initdb.d/. MongoDB is schema-on-read, so the shape is
// enforced twice: at the API boundary with Zod, and here with a JSON Schema
// validator, which also protects data written by any other client.

const targetDb = db.getSiblingDB(process.env.MONGO_INITDB_DATABASE || 'applicant_service_db');

targetDb.createCollection('applicants', {
  validator: {
    $jsonSchema: {
      bsonType: 'object',
      required: ['applicantId', 'name', 'studentId', 'major', 'role', 'status', 'createdAt'],
      properties: {
        applicantId: { bsonType: 'string' },
        name: { bsonType: 'string' },
        studentId: { bsonType: 'string' },
        major: { bsonType: 'string' },
        // Non-student roles have no year of study, so null is a valid value.
        // The Node driver writes JS numbers as double, hence both numeric types.
        year: { bsonType: ['int', 'double', 'long', 'null'] },
        role: {
          enum: ['student_faf', 'student_other', 'teaching_assistant', 'staff', 'alumnus', 'outsider'],
        },
        status: {
          enum: ['active', 'graduated', 'suspended', 'expelled', 'none'],
        },
        createdAt: { bsonType: 'string' },
      },
    },
  },
  // Reject writes that break the schema rather than logging and accepting them.
  validationLevel: 'strict',
  validationAction: 'error',
});

// applicantId is the shared key across Applicant, Credential and University
// Record Service, so it must be unique here.
targetDb.applicants.createIndex({ applicantId: 1 }, { unique: true });

// Deliberately NOT unique: impersonation means two applicants can legitimately
// present the same studentId, and a unique index would make that scenario
// impossible to generate.
targetDb.applicants.createIndex({ studentId: 1 });

// Listing by role is the only filtered query this service serves.
targetDb.applicants.createIndex({ role: 1 });

print('applicant_service_db initialised: validator and indexes created');

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
