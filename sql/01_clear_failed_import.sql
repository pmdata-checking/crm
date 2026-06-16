-- ============================================================
-- PROSPECTManager CRM — Reactivation pipeline build, step 1 of 4
-- 01_clear_failed_import.sql
-- ============================================================
-- PURPOSE
--   Clear a botched import of 43 customer records (copied off the
--   developers' database) so the CRM can be rebuilt clean and then
--   loaded with 149 confirmed-still-exist lapsed customers as a
--   reactivation pipeline (steps 2-4).
--
--   The live point of truth for these customers is the developers'
--   site, which is UNAFFECTED by this script. This only clears the
--   bad copy held in Supabase project zmnofnsvonarpevzrkuo.
--
-- HOW TO RUN  (RLS blocks the anon key, so this runs in the
--             Supabase Dashboard > SQL Editor, run by Rob)
--   Part A (read-only):  run SECTIONS 1 + 2, eyeball the output.
--   Part B (destructive): once happy, run SECTIONS 3 + 4.
--
-- SCOPE: this script ONLY clears data. It does NOT touch the schema,
--        RLS, the front-end, or load any data. Those are steps 2-4.
-- ============================================================


-- ============================================================
-- SECTION 1 — BEFORE counts (read-only)
-- Expect: 43 customers, plus their children. Note the numbers.
-- ============================================================
select 'crm_customers'      as table_name, count(*) as row_count from crm_customers
union all
select 'crm_contacts'       as table_name, count(*) as row_count from crm_contacts
union all
select 'crm_subscriptions'  as table_name, count(*) as row_count from crm_subscriptions
union all
select 'crm_communications' as table_name, count(*) as row_count from crm_communications
order by table_name;


-- ============================================================
-- SECTION 2 — Snapshot of the single existing subscription,
-- joined to its customer (read-only). Eyeball this before deleting.
-- ============================================================
select c.company_name,
       c.status,
       s.plan_name,
       s.price_gbp,
       s.billing_cycle,
       s.starts_at,
       s.ends_at,
       s.is_current
from   crm_subscriptions s
join   crm_customers     c on c.id = s.customer_id
order by c.company_name;


-- ============================================================
-- >>> STOP HERE. Review SECTION 1 + 2 output before continuing. <<<
-- ============================================================


-- ============================================================
-- SECTION 3 — THE CLEAR (destructive)
-- Deleting from crm_customers cascades to crm_contacts,
-- crm_subscriptions and crm_communications via their existing
-- ON DELETE CASCADE foreign keys (customer_id -> crm_customers(id)).
-- So this single delete empties all four tables.
-- ============================================================
delete from crm_customers;


-- ============================================================
-- SECTION 4 — AFTER counts (read-only). Expect all four = 0.
-- ============================================================
select 'crm_customers'      as table_name, count(*) as row_count from crm_customers
union all
select 'crm_contacts'       as table_name, count(*) as row_count from crm_contacts
union all
select 'crm_subscriptions'  as table_name, count(*) as row_count from crm_subscriptions
union all
select 'crm_communications' as table_name, count(*) as row_count from crm_communications
order by table_name;
