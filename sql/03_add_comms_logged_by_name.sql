-- ============================================================
-- PROSPECTManager CRM — Reactivation pipeline build, step 3 of 4
-- 03_add_comms_logged_by_name.sql
-- ============================================================
-- PURPOSE
--   Denormalise the logging user's display name onto each
--   communication. `logged_by` (uuid -> auth.users) stays as the
--   integrity reference, but PostgREST cannot read auth.users and
--   the shared user_roles table is keyed by email with no name, so
--   ordinary researchers have no way to resolve a uuid to a person.
--   Storing the name at write time makes the comms log show "who"
--   correctly for every authenticated user on the shared list.
--
-- HOW TO RUN  (RLS blocks the anon key, so this runs in the
--             Supabase Dashboard > SQL Editor, run by Rob)
--   Idempotent — safe to re-run.
--
-- >>> RUN ORDER: this migration MUST be applied BEFORE the matching
--     front-end deploy goes live. The new front-end writes
--     logged_by_name on every comms insert; if the column does not
--     yet exist, those inserts fail. Run this first, then the page
--     is safe to use.
--
-- SCOPE: schema only. Does NOT load data (the 149 = step 4).
-- ============================================================


-- ------------------------------------------------------------
-- Add the denormalised logger name (nullable; tables are empty so
-- there are no legacy null-name rows to backfill).
-- ------------------------------------------------------------
alter table crm_communications
  add column if not exists logged_by_name text;


-- ============================================================
-- VERIFICATION (read-only) — confirm the column exists.
-- Expect one row: logged_by_name | text | YES.
-- ============================================================
select column_name, data_type, is_nullable
from   information_schema.columns
where  table_schema = 'public'
  and  table_name   = 'crm_communications'
  and  column_name  = 'logged_by_name';
