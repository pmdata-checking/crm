-- ============================================================
-- PROSPECTManager CRM — Reactivation pipeline build, step 2 of 4
-- 02_add_pipeline_fields.sql
-- ============================================================
-- PURPOSE
--   Extend crm_customers with the fields the reactivation pipeline
--   needs: a pipeline stage, Tracy's "chase on this date", and a
--   short next-action note. Plus supporting indexes.
--
--   ADDITIVE ONLY. This adds columns/indexes and one named CHECK
--   constraint. It does NOT drop or alter any existing column, and
--   it leaves the existing `status` field + its CHECK untouched —
--   `status` stays for customer-state (prospect/active/trial/
--   contra/lapsed); `pipeline_stage` is the separate sales-funnel
--   position.
--
-- HOW TO RUN  (RLS blocks the anon key, so this runs in the
--             Supabase Dashboard > SQL Editor, run by Rob)
--   Every statement is idempotent — safe to re-run.
--
-- SCOPE: schema only. Does NOT touch the front-end (step 3) or
--        load any data (step 4).
-- ============================================================


-- ------------------------------------------------------------
-- 1. pipeline_stage — sales-funnel position
--    (column added separately from its CHECK so both are idempotent)
-- ------------------------------------------------------------
alter table crm_customers
  add column if not exists pipeline_stage text not null default 'new';

-- drop + recreate the named CHECK so re-running is safe
alter table crm_customers
  drop constraint if exists crm_customers_pipeline_stage_check;
alter table crm_customers
  add constraint crm_customers_pipeline_stage_check
  check (pipeline_stage in (
    'new','researching','contacted','in conversation',
    'quoted','won','lost','on hold'
  ));

-- ------------------------------------------------------------
-- 2. follow_up_on — Tracy's "chase on this date"
-- ------------------------------------------------------------
alter table crm_customers
  add column if not exists follow_up_on date;

-- ------------------------------------------------------------
-- 3. next_action — short note of the next step
-- ------------------------------------------------------------
alter table crm_customers
  add column if not exists next_action text;

-- ------------------------------------------------------------
-- 4. Indexes — fast "what's due" sort and stage filtering
-- ------------------------------------------------------------
create index if not exists idx_crm_customers_follow_up
  on crm_customers(follow_up_on);
create index if not exists idx_crm_customers_pipeline_stage
  on crm_customers(pipeline_stage);


-- ============================================================
-- 5. VERIFICATION (read-only) — confirm the new columns exist.
--    Expect three rows: follow_up_on, next_action, pipeline_stage.
-- ============================================================
select column_name, data_type, is_nullable, column_default
from   information_schema.columns
where  table_schema = 'public'
  and  table_name   = 'crm_customers'
  and  column_name in ('pipeline_stage', 'follow_up_on', 'next_action')
order by column_name;
