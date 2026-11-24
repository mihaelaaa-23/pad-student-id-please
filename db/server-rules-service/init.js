db = db.getSiblingDB("server_rules_service_db");

db.rules.deleteMany({});

db.rules.insertMany([
    {
        id: "ONLY_FAF_STUDENTS",
        description: "Only FAF students may join",
        enabled: true,
        condition: {
            field: "role",
            operator: "equals",
            value: "student_faf"
        }
    },
    {
        id: "ACTIVE_STATUS_REQUIRED",
        description: "Applicant must have active university status",
        enabled: true,
        condition: {
            field: "status",
            operator: "equals",
            value: "active"
        }
    },
    {
        id: "NO_PREVIOUS_BAN",
        description: "Applicant must not have a previous server ban",
        enabled: true,
        condition: {
            field: "previouslyBanned",
            operator: "equals",
            value: false
        }
    }
]);

// Lab 5: the warehouse reads this database through the replica set.
// Create the ETL identity in admin, with read access to this database only.
const etlReaderPassword = process.env.ETL_READER_PASSWORD;

if (etlReaderPassword) {
    const adminDb = db.getSiblingDB("admin");

    if (!adminDb.getUser("etl_reader")) {
        adminDb.createUser({
            user: "etl_reader",
            pwd: etlReaderPassword,
            roles: [{ role: "read", db: "server_rules_service_db" }]
        });
    }

    print("etl_reader ready (read on server_rules_service_db)");
}
