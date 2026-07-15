CREATE SCHEMA IF NOT EXISTS neuraltrust;

CREATE TABLE IF NOT EXISTS neuraltrust.tests (
    "id" TEXT NOT NULL,
    "scenarioId" TEXT NOT NULL,
    "targetId" TEXT NOT NULL,
    "testCase" TEXT NOT NULL,
    "context" TEXT NOT NULL,
    "type" TEXT NOT NULL,
    "contextKeys" TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    "createdAt" TIMESTAMP WITHOUT TIME ZONE NOT NULL
        DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'UTC'),
    "updatedAt" TIMESTAMP WITHOUT TIME ZONE NOT NULL
        DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'UTC'),
    "sign" SMALLINT NOT NULL DEFAULT 1 CHECK ("sign" = 1),
    PRIMARY KEY ("scenarioId", "targetId", "id")
);

CREATE TABLE IF NOT EXISTS neuraltrust.test_runs (
    "id" TEXT NOT NULL,
    "scenarioId" TEXT NOT NULL,
    "targetId" TEXT NOT NULL,
    "testId" TEXT NOT NULL,
    "runId" TEXT NOT NULL,
    "executionId" TEXT NOT NULL DEFAULT '',
    "type" TEXT NOT NULL,
    "contextKeys" TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    "failure" SMALLINT NOT NULL CHECK ("failure" IN (0, 1)),
    "failCriteria" TEXT NOT NULL,
    "testCase" TEXT NOT NULL,
    "score" TEXT NOT NULL,
    "executionTimeSeconds" INTEGER,
    "runAt" TIMESTAMP WITHOUT TIME ZONE NOT NULL
        DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'UTC'),
    "sign" SMALLINT NOT NULL DEFAULT 1 CHECK ("sign" = 1),
    PRIMARY KEY ("scenarioId", "targetId", "testId", "id")
);

CREATE INDEX IF NOT EXISTS tests_target_scenario_created_at_idx
    ON neuraltrust.tests ("targetId", "scenarioId", "createdAt" DESC);

CREATE INDEX IF NOT EXISTS tests_scenario_target_created_at_idx
    ON neuraltrust.tests ("scenarioId", "targetId", "createdAt" DESC);

CREATE INDEX IF NOT EXISTS test_runs_target_scenario_run_at_idx
    ON neuraltrust.test_runs ("targetId", "scenarioId", "runAt" DESC);

CREATE INDEX IF NOT EXISTS test_runs_latest_test_idx
    ON neuraltrust.test_runs (
        "targetId",
        "scenarioId",
        "testId",
        "runAt" DESC
    );

CREATE INDEX IF NOT EXISTS test_runs_run_group_idx
    ON neuraltrust.test_runs (
        "targetId",
        "scenarioId",
        "runId",
        "runAt" DESC
    );

CREATE INDEX IF NOT EXISTS test_runs_target_run_at_idx
    ON neuraltrust.test_runs ("targetId", "runAt" DESC);
