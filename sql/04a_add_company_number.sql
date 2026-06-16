-- ============================================================================
-- CRM reactivation build — step 4a: add company_number column (additive)
-- Project zmnofnsvonarpevzrkuo. Idempotent. Run in Supabase SQL editor.
-- RUN ORDER: run 04a BEFORE 04b (the import references company_number).
-- ============================================================================
alter table crm_customers
  add column if not exists company_number text;

create index if not exists idx_crm_customers_company_number
  on crm_customers(company_number);

-- verify
select column_name, data_type
from information_schema.columns
where table_schema='public' and table_name='crm_customers'
  and column_name='company_number';
