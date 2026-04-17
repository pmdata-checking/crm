-- ============================================================
-- PROSPECTManager CRM — Supabase Schema
-- ============================================================
-- Run this in Supabase SQL Editor (Dashboard > SQL Editor)
-- Requires: Supabase Auth users already exist (shared with Research site)
-- ============================================================

-- 1. CUSTOMERS
create table if not exists crm_customers (
  id            uuid primary key default gen_random_uuid(),
  company_name  text not null,
  status        text not null default 'prospect'
                  check (status in ('active','trial','contra','lapsed','prospect')),
  website       text,
  address_line1 text,
  address_line2 text,
  town          text,
  county        text,
  postcode      text,
  country       text default 'UK',
  notes         text,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

-- 2. CONTACTS
create table if not exists crm_contacts (
  id           uuid primary key default gen_random_uuid(),
  customer_id  uuid not null references crm_customers(id) on delete cascade,
  first_name   text not null,
  last_name    text not null,
  job_title    text,
  email        text,
  phone        text,
  mobile       text,
  is_primary   boolean default false,
  notes        text,
  created_at   timestamptz default now()
);

-- 3. SUBSCRIPTIONS
create table if not exists crm_subscriptions (
  id             uuid primary key default gen_random_uuid(),
  customer_id    uuid not null references crm_customers(id) on delete cascade,
  plan_name      text not null,
  price_gbp      numeric(10,2),
  billing_cycle  text default 'monthly'
                   check (billing_cycle in ('monthly','annual','one-off','contra','free')),
  starts_at      date,
  ends_at        date,
  is_free_trial  boolean default false,
  trial_ends_at  date,
  is_contra      boolean default false,
  is_current     boolean default true,
  notes          text,
  created_at     timestamptz default now()
);

-- 4. COMMUNICATIONS
create table if not exists crm_communications (
  id           uuid primary key default gen_random_uuid(),
  customer_id  uuid not null references crm_customers(id) on delete cascade,
  logged_by    uuid references auth.users(id),
  comm_type    text not null default 'note'
                 check (comm_type in ('call','email','meeting','note','task')),
  direction    text default 'outbound'
                 check (direction in ('outbound','inbound','internal')),
  subject      text,
  body         text,
  occurred_at  timestamptz not null default now(),
  created_at   timestamptz default now()
);

-- ============================================================
-- INDEXES
-- ============================================================
create index if not exists idx_crm_contacts_customer    on crm_contacts(customer_id);
create index if not exists idx_crm_subs_customer        on crm_subscriptions(customer_id);
create index if not exists idx_crm_comms_customer       on crm_communications(customer_id);
create index if not exists idx_crm_comms_occurred       on crm_communications(occurred_at desc);
create index if not exists idx_crm_customers_status     on crm_customers(status);

-- ============================================================
-- AUTO-UPDATE updated_at ON CUSTOMERS
-- ============================================================
create or replace function crm_set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_crm_customers_updated on crm_customers;
create trigger trg_crm_customers_updated
  before update on crm_customers
  for each row execute function crm_set_updated_at();

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
-- All authenticated users can read/write CRM data.
-- Adjust policies if you need per-user restrictions later.

alter table crm_customers enable row level security;
alter table crm_contacts enable row level security;
alter table crm_subscriptions enable row level security;
alter table crm_communications enable row level security;

-- Customers
create policy "crm_customers_select" on crm_customers
  for select to authenticated using (true);
create policy "crm_customers_insert" on crm_customers
  for insert to authenticated with check (true);
create policy "crm_customers_update" on crm_customers
  for update to authenticated using (true) with check (true);
create policy "crm_customers_delete" on crm_customers
  for delete to authenticated using (true);

-- Contacts
create policy "crm_contacts_select" on crm_contacts
  for select to authenticated using (true);
create policy "crm_contacts_insert" on crm_contacts
  for insert to authenticated with check (true);
create policy "crm_contacts_update" on crm_contacts
  for update to authenticated using (true) with check (true);
create policy "crm_contacts_delete" on crm_contacts
  for delete to authenticated using (true);

-- Subscriptions
create policy "crm_subs_select" on crm_subscriptions
  for select to authenticated using (true);
create policy "crm_subs_insert" on crm_subscriptions
  for insert to authenticated with check (true);
create policy "crm_subs_update" on crm_subscriptions
  for update to authenticated using (true) with check (true);
create policy "crm_subs_delete" on crm_subscriptions
  for delete to authenticated using (true);

-- User Roles (shared table — may already have RLS enabled)
-- This policy allows all authenticated users to read user_roles.
-- Run this even if the table already exists — it just adds the missing SELECT policy.
do $$ begin
  alter table user_roles enable row level security;
exception when others then null;
end $$;
create policy "Authenticated users can read user_roles" on user_roles
  for select to authenticated using (true);

-- Communications
create policy "crm_comms_select" on crm_communications
  for select to authenticated using (true);
create policy "crm_comms_insert" on crm_communications
  for insert to authenticated with check (true);
create policy "crm_comms_update" on crm_communications
  for update to authenticated using (true) with check (true);
create policy "crm_comms_delete" on crm_communications
  for delete to authenticated using (true);
