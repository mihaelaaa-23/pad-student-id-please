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
            field: "previousBan",
            operator: "equals",
            value: false
        }
    }
]);