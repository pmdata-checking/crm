-- 08: permanent customer reference numbers (CU0001 style)
-- ============================================================
-- Stores an INTEGER sequence value per customer. The "CU0001" string is
-- formatted at display/export time only — we store 1, not "CU0001".
-- The reference is a PERMANENT identity: assigned once, never renumbered.
-- Deletions leave gaps on purpose (a permanent ref must never shift).
--
-- Safe to re-run: the column add is IF NOT EXISTS, the backfill only touches
-- rows where customer_ref IS NULL, and the sequence is re-synced past the
-- current max each run. A second run assigns nothing and double-ups nothing.
-- ============================================================

-- a. Integer column (NOT the CH company_number — that's unrelated).
alter table crm_customers add column if not exists customer_ref integer;

-- b. Backfill existing rows in created_at order, oldest first = 1, ascending.
--    id is the tiebreaker so rows sharing a created_at (e.g. the lapsed
--    import batch) get a deterministic, stable order. Only NULL refs are
--    touched, so a re-run never reassigns an already-numbered customer.
with ranked as (
  select id,
         row_number() over (order by created_at asc, id asc) as rn
  from crm_customers
  where customer_ref is null
)
update crm_customers c
set customer_ref = ranked.rn
from ranked
where c.id = ranked.id;

-- c. DB-owned counter for NEW customers. The sequence is the single source
--    of the next value — the front end must never compute max+1 (concurrent
--    inserts would collide). Default = nextval, so every insert auto-assigns.
create sequence if not exists crm_customer_ref_seq;
alter table crm_customers
  alter column customer_ref set default nextval('crm_customer_ref_seq');
alter sequence crm_customer_ref_seq owned by crm_customers.customer_ref;

-- Advance the sequence past the current max so new inserts continue the run
-- (e.g. 149 existing rows -> next insert gets 150). setval with is_called=true
-- means the NEXT nextval returns max+1. coalesce handles an empty table.
select setval(
  'crm_customer_ref_seq',
  (select coalesce(max(customer_ref), 0) from crm_customers),
  true
);

-- d. Uniqueness — one ref per customer, never duplicated. Guarded so a
--    re-run is a no-op (ADD CONSTRAINT has no IF NOT EXISTS form).
do $$ begin
  if not exists (
    select 1 from pg_constraint where conname = 'crm_customers_customer_ref_key'
  ) then
    alter table crm_customers add constraint crm_customers_customer_ref_key unique (customer_ref);
  end if;
end $$;
