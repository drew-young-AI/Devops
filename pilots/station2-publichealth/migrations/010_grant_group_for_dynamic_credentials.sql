-- 010: make new tables reachable by credentials that already exist.
--
-- THE FAILURE THIS FIXES, OBSERVED 2026-08-19.
--
-- Migration 008 created demographic_fact and the geo_population view. The pilot
-- was holding a Vault credential issued minutes earlier and went straight to:
--
--     {"status": "db_unreachable", "detail": "InsufficientPrivilege"}
--
-- A FRESH credential could read every table; the running one could not. The
-- cause is one word in the Vault role's creation statement:
--
--     GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO "{{name}}"
--                                      ^^^
-- ON ALL TABLES is evaluated ONCE, at role creation. It is a loop over the
-- tables that exist at that instant, not a standing rule. So every credential
-- is frozen at the schema shape of the moment it was issued, and any migration
-- that adds a table breaks every live credential until it rotates -- up to the
-- full 3600s TTL.
--
-- WHY THIS IS WORSE THAN IT LOOKS.
--
-- It is silent in the direction that matters. Readiness reports
-- `db_unreachable`, which reads as "the database is down". The database was
-- fine, the credential was valid, the network was fine. Nothing in the error
-- says "this credential predates that table". An operator follows the runbook
-- for a database outage and finds a healthy database.
--
-- It is also timing-dependent, which is the worst property a bug can have: run
-- the migration one minute after a credential rotation and the service is broken
-- for an hour; run it one minute before and nobody ever sees it.
--
-- THE FIX: A STANDING RULE INSTEAD OF A ONE-TIME LOOP.
--
-- A static group role owns the privileges. ALTER DEFAULT PRIVILEGES makes the
-- grant automatic for tables created LATER by the migration owner. Vault's
-- dynamic users then only need to join the group -- one grant that never goes
-- stale, instead of a snapshot that silently does.
--
--   station2_app          group role, owns nothing, logs in nowhere (NOLOGIN)
--   DEFAULT PRIVILEGES    every future table/sequence created by twin
--   GRANT station2_app    added to Vault creation_statements (setup_database_secrets.sh)
--
-- NOLOGIN is deliberate: this role is a privilege container, not an identity.
-- A group that can log in is a shared account by another name, which is the
-- thing dynamic credentials exist to abolish.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'station2_app') THEN
        CREATE ROLE station2_app NOLOGIN;
    END IF;
END $$;

-- Existing objects: the one-time loop is still needed once, to cover everything
-- created before this migration.
GRANT USAGE ON SCHEMA public TO station2_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO station2_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO station2_app;

-- Future objects: the standing rule. Scoped to the role that actually creates
-- them (the migration runner connects as the owner), because DEFAULT PRIVILEGES
-- without FOR ROLE applies only to objects created by the CURRENT user and
-- would silently miss anything a different admin creates later.
ALTER DEFAULT PRIVILEGES FOR ROLE CURRENT_USER IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE ON TABLES TO station2_app;
ALTER DEFAULT PRIVILEGES FOR ROLE CURRENT_USER IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO station2_app;

COMMENT ON ROLE station2_app IS
    'Privilege container for station2-twin dynamic credentials. Vault-issued '
    'users are GRANTed this role; ALTER DEFAULT PRIVILEGES keeps it current as '
    'migrations add tables. NOLOGIN on purpose -- it is not an account.';
