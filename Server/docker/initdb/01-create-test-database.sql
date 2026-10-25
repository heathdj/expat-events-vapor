-- Runs only when Postgres initializes a brand-new data volume. Creates the
-- separate database `swift test` uses (see ../../.env.testing), so the test
-- suite's migrate/revert cycle never touches the dev database.
CREATE DATABASE expatevents_test;
