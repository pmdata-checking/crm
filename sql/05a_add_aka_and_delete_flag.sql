-- ============================================================
-- PROSPECTManager CRM — Step 5a: AKA + flag-for-deletion (schema only)
-- 05a_add_aka_and_delete_flag.sql
-- ============================================================
-- PURPOSE
--   Two additive features on crm_customers:
--
--   1. AKA (also-known-as): the name WE know a company by, which can
--      differ wildly from the Companies House registered name
--      (e.g. we call them "Comar"; CH name is "Bailey CW Limited").
--
--   2. Flag-for-deletion with superuser approval (soft-delete + approval):
--      a regular researcher can FLAG a record for deletion (e.g. a spotted
--      duplicate); only a superuser confirms the actual delete. These
--      columns hold the flag, who set it, when, and why.
--
--   ADDITIVE ONLY — adds columns + indexes, alters/drops nothing existing.
--
-- HOW TO RUN  (RLS blocks the anon key, so this runs in the
--             Supabase Dashboard > SQL Editor, run by Rob)
--   Every statement is idempotent — safe to re-run.
--
-- SCOPE: schema only. Does NOT include the AKA backfill (05b, provided
--        separately by Rob) or the front-end (step 5c).
-- ============================================================


-- ------------------------------------------------------------
-- FEATURE 1 — AKA (also-known-as)
-- ------------------------------------------------------------
alter table crm_customers
  add column if not exists aka text;

create index if not exists idx_crm_customers_aka
  on crm_customers(aka);


-- ------------------------------------------------------------
-- FEATURE 2 — flag-for-deletion with superuser approval
-- ------------------------------------------------------------
alter table crm_customers
  add column if not exists delete_flagged boolean not null default false;
alter table crm_customers
  add column if not exists delete_flagged_by text;       -- flagger's display name
alter table crm_customers
  add column if not exists delete_flagged_at timestamptz;
alter table crm_customers
  add column if not exists delete_flag_reason text;       -- why, e.g. "duplicate of #x"

-- Index the flag so the superuser review filter is fast.
create index if not exists idx_crm_customers_delete_flagged
  on crm_customers(delete_flagged);


-- ============================================================
-- VERIFICATION (read-only) — confirm the new columns exist.
-- Expect five rows: aka, delete_flagged, delete_flagged_at,
-- delete_flagged_by, delete_flag_reason.
-- ============================================================
select column_name, data_type, is_nullable, column_default
from   information_schema.columns
where  table_schema = 'public'
  and  table_name   = 'crm_customers'
  and  column_name in ('aka', 'delete_flagged', 'delete_flagged_by',
                       'delete_flagged_at', 'delete_flag_reason')
order by column_name;
