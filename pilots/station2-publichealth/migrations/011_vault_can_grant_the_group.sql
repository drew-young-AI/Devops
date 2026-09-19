-- 011: let Vault actually hand out the group role 010 created.
--
-- WHY THIS IS A SEPARATE FILE RATHER THAN A FIX TO 010.
--
-- 010 was already applied when this gap was found. Editing it would have left
-- this database without the change while a database built from the same files
-- tomorrow would have it -- two schemas that look identical and are not.
-- platform/db/migrate.sh checksums every applied file and refuses exactly that,
-- and it caught this when the edit was attempted. The gate was right; 010 was
-- restored byte-for-byte and the change lives here.
--
-- THE GAP.
--
-- 010 created the station2_app group and gave it ALTER DEFAULT PRIVILEGES, so
-- future tables reach it automatically. It did not make Vault's admin user a
-- member WITH ADMIN OPTION. In postgres, GRANTing a role requires that. So the
-- moment `GRANT station2_app TO "{{name}}"` was added to Vault's
-- creation_statements, the statement failed and Vault stopped issuing database
-- credentials ENTIRELY:
--
--     Could not read database/creds/station2-twin
--
-- That is strictly worse than the bug 010 set out to fix. A missing grant on one
-- new table degrades one query; a failing creation_statement takes out every
-- credential the service will ever ask for.
--
-- HOW IT WAS CAUGHT: a negative control, not a passing test. The check issued a
-- credential, created a table AFTER it, then read that table with the older
-- credential. It failed at step one -- no credential could be issued at all --
-- which a "does the new grant work?" test phrased positively would have
-- reported as a generic failure without distinguishing the two causes.

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vault_admin') THEN
        EXECUTE 'GRANT station2_app TO vault_admin WITH ADMIN OPTION';
    ELSE
        -- A fresh database applies migrations before Vault is configured, so
        -- vault_admin legitimately may not exist yet. setup_database_secrets.sh
        -- performs the same grant when it creates the role, which makes the two
        -- orderings converge instead of one of them being a latent failure.
        RAISE NOTICE 'vault_admin does not exist yet -- '
                     'platform/vault/scripts/setup_database_secrets.sh performs '
                     'this grant when it creates the role';
    END IF;
END $$;
