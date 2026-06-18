-- 06_crm_customer_context_fields.sql
-- Adds company-level context fields used on the customer profile.
-- Idempotent — safe to re-run. New columns inherit the table's RLS
-- (anon blocked, all-authenticated CRUD) so no policy changes are needed.
alter table crm_customers add column if not exists phone text;
alter table crm_customers add column if not exists last_customer_on date;
alter table crm_customers add column if not exists last_selection_sql text;
