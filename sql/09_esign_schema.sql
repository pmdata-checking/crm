-- 09: e-sign — schema, RLS, INSERT-only event grants (Phase 0)
-- ============================================================
-- In-CRM electronic signature for B2B customer agreements.
-- Build plan: docs/PROSPECTManager_eSign_Build_Plan.md  (this is Phase 0; the
-- staff RPCs are Phase 1 in sql/10_esign_rpcs.sql).
--
-- THE TRUST BOUNDARY (the whole point — see plan §2):
--   Staff  = authenticated CRM users (MS SSO) -> SECURITY DEFINER RPCs (sql/10).
--   Signer = anon external contact holding a single-use token -> Edge Functions
--            with the service-role key (built in a later phase).
--   The browser NEVER touches these four tables directly. They are RLS
--   default-deny with NO authenticated/anon policy; staff reach data only through
--   the sql/10 RPCs, the signer side only through service-role Edge Functions.
--
-- GRANTS NOTE (mirror of the cashflow lesson, INVERTED): this CRM project has
--   "Automatically expose new tables" ON, so a new table is auto-granted to
--   authenticated/anon/service_role. We therefore explicitly REVOKE from
--   authenticated + anon to lock these down, rather than GRANT to open up.
--   (The crm_* tables rely on the auto-grant; these evidence tables must not.)
--
-- DATA MODEL NOTE: aligned to the updated plan §3 + §11.
--   Multi-business-unit readiness (plan §11, folded in now to avoid a later
--   migration/backfill on a table that will hold signed legal evidence):
--     - agreements.business_unit     'PM'|'RESEARCH', default 'PM' (tenant discriminator)
--     - agreements.company_id        NULLABLE (Research has no CRM company)
--     - agreements.counterparty_name org-name fallback when company_id is null
--   Evidence/lock support (plan §3):
--     - agreements.locked            boolean  -- the §8 "locked on completion" state
--     - agreement_events.detail      jsonb    -- void reason / force-unlock / email-id
--     - agreement_events.event_type  includes 'force_unlocked' (audit the override)
--   FK names map to the REAL CRM tables: company_id -> crm_customers (plan said
--   "companies"); the signer party is snapshotted from crm_contacts at create.
--
-- Idempotent; ends with a read-only verification block. Run in the Supabase SQL
-- editor AFTER 01-08.
-- ============================================================


-- ------------------------------------------------------------
-- agreement_templates — base PDF + field placement map.
-- ------------------------------------------------------------
create table if not exists agreement_templates (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  source_path text,                       -- base PDF in PRIVATE storage (set later)
  field_map   jsonb,                      -- [{role,type:signature|date|initials,page,x,y,w,h}]
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);


-- ------------------------------------------------------------
-- agreements — one agreement, optionally attached to a CRM company. Mutable
-- state only; the evidence trail lives in agreement_events.
-- business_unit is the tenant discriminator (plan §11): 'PM' now, 'RESEARCH'
--   later. Defaulted to 'PM' so PM creates need not set it. No RLS/RPC scoping by
--   it yet — that lands when Research is onboarded.
-- company_id is NULLABLE (Research has no CRM company) but still ON DELETE
--   RESTRICT where set: a company with agreements must not be hard-deleted out
--   from under its legal evidence (this DOES change the CRM's existing superuser
--   delete path for such companies — see handoff).
-- counterparty_name is the org-name fallback used when company_id is null (typed
--   for Research; for PM the name is reachable via the company FK).
-- template_id is nullable to allow the MVP hard-coded/fixed-template path.
-- ------------------------------------------------------------
create table if not exists agreements (
  id                uuid primary key default gen_random_uuid(),
  business_unit     text not null default 'PM'
                      check (business_unit in ('PM','RESEARCH')),  -- tenant discriminator (plan §11)
  company_id        uuid references crm_customers(id) on delete restrict,  -- NULLABLE: Research has no CRM company
  counterparty_name text,                          -- org-name fallback when company_id is null
  template_id       uuid references agreement_templates(id),
  title             text not null,
  status            text not null default 'draft'
                      check (status in ('draft','sent','viewed','partially_signed','completed','voided')),
  locked            boolean not null default false, -- set true on completion; superuser force_unlock clears
  document_hash     text,                           -- sha256 of the sealed PDF, set on completion (Edge fn)
  signed_path       text,                           -- immutable sealed PDF path in Storage (write-once)
  created_by        uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  completed_at      timestamptz
);


-- ------------------------------------------------------------
-- agreement_parties — one row per signer/countersigner. token_hash is the
-- sha256 of the single-use token; the RAW token only ever exists in the email
-- link, never in the DB. name/email are a snapshot taken at create time so later
-- contact edits cannot rewrite the evidence.
-- ------------------------------------------------------------
create table if not exists agreement_parties (
  id             uuid primary key default gen_random_uuid(),
  agreement_id   uuid not null references agreements(id) on delete cascade,
  role           text not null check (role in ('signer','countersigner')),
  sign_order     int  not null default 1,          -- 1 = customer, 2 = you/Scott
  name           text,
  email          text,
  token_hash     text,                             -- sha256(token); raw token ONLY in the email link
  token_expires  timestamptz,
  acknowledged   boolean not null default false,
  signed_at      timestamptz,
  signature_path text,
  created_at     timestamptz not null default now(),
  unique (agreement_id, role)
);


-- ------------------------------------------------------------
-- agreement_events — APPEND-ONLY evidence spine. INSERT-only at the grant level
-- AND guarded by a trigger that blocks UPDATE/DELETE for every role (so even a
-- service-role mistake can't rewrite history). Consequence: an agreement that
-- has events cannot be hard-deleted (the cascade delete of its events hits the
-- append-only trigger and aborts) — that is deliberate evidence integrity.
-- ------------------------------------------------------------
create table if not exists agreement_events (
  id           bigint generated always as identity primary key,
  agreement_id uuid not null references agreements(id) on delete cascade,
  party_id     uuid references agreement_parties(id) on delete set null,
  event_type   text not null check (event_type in
                 ('created','sent','opened','viewed','acknowledged',
                  'signed','countersigned','completed','voided','force_unlocked')),
  actor_email  text,
  ip_address   inet,                               -- signer side: from CF-Connecting-IP (Edge fn)
  user_agent   text,
  detail       jsonb,                              -- structured note (void reason, force-unlock, email id)
  occurred_at  timestamptz not null default now()  -- UTC
);


-- ------------------------------------------------------------
-- Indexes.
-- ------------------------------------------------------------
create index if not exists idx_agreements_company         on agreements(company_id);
create index if not exists idx_agreements_status          on agreements(status);
create index if not exists idx_agreement_parties_agreement on agreement_parties(agreement_id);
create index if not exists idx_agreement_parties_token    on agreement_parties(token_hash);  -- signer lookup by hash
create index if not exists idx_agreement_events_agreement on agreement_events(agreement_id, occurred_at);


-- ------------------------------------------------------------
-- Append-only enforcement on agreement_events.
-- ------------------------------------------------------------
create or replace function esign_block_event_mutation()
returns trigger language plpgsql as $$
begin
  raise exception 'agreement_events is append-only (% blocked)', tg_op;
end;
$$;

drop trigger if exists trg_agreement_events_append_only on agreement_events;
create trigger trg_agreement_events_append_only
  before update or delete on agreement_events
  for each row execute function esign_block_event_mutation();


-- ------------------------------------------------------------
-- RLS — enable on all four (default-deny). NO policies: staff go through the
-- SECURITY DEFINER RPCs in sql/10; the signer side uses the service-role key
-- (which bypasses RLS) in the Edge Functions. The browser gets nothing direct.
-- ------------------------------------------------------------
alter table agreement_templates enable row level security;
alter table agreements          enable row level security;
alter table agreement_parties   enable row level security;
alter table agreement_events    enable row level security;


-- ------------------------------------------------------------
-- Grants. This project auto-grants new tables to authenticated/anon/service_role,
-- so REVOKE to lock down. Strip authenticated + anon entirely (no direct table
-- access from any browser session). Keep service_role for the Edge Functions, but
-- make agreement_events INSERT-only even for service_role (the evidence spine is
-- never updated/deleted/truncated by anyone).
-- ------------------------------------------------------------
revoke all on table agreement_templates from authenticated, anon;
revoke all on table agreements          from authenticated, anon;
revoke all on table agreement_parties   from authenticated, anon;
revoke all on table agreement_events    from authenticated, anon;

revoke update, delete, truncate on table agreement_events from service_role;


-- ============================================================
-- VERIFICATION (read-only) — SINGLE result set so the Supabase editor shows
-- every check at once (it renders only the last statement when several run
-- together). One row per check: check_name, result (PASS/FAIL), detail.
-- Expect all six rows PASS.
-- ============================================================
select check_name, result, detail from (

  -- 1. the four tables exist
  select 1 as ord,
         '1. four tables exist (expect 4)' as check_name,
         case when count(*) = 4 then 'PASS' else 'FAIL' end as result,
         coalesce(string_agg(table_name, ', ' order by table_name), '(none)') as detail
  from   information_schema.tables
  where  table_schema = 'public'
    and  table_name in ('agreement_templates','agreements','agreement_parties','agreement_events')

  union all
  -- 2. RLS enabled and ZERO policies on all four (default-deny)
  select 2,
         '2. RLS on + 0 policies (all 4)',
         case when bool_and(c.relrowsecurity) and coalesce(sum(pc.cnt), 0) = 0
              then 'PASS' else 'FAIL' end,
         string_agg(c.relname || ' rls=' || c.relrowsecurity::text
                    || ' policies=' || coalesce(pc.cnt, 0)::text, ', ' order by c.relname)
  from   pg_class c
  left join (select tablename, count(*) cnt from pg_policies where schemaname = 'public' group by tablename) pc
         on pc.tablename = c.relname
  where  c.relnamespace = 'public'::regnamespace
    and  c.relname in ('agreement_templates','agreements','agreement_parties','agreement_events')

  union all
  -- 3. authenticated/anon have NO table privileges on the four (expect 0)
  select 3,
         '3. no authenticated/anon table grants (expect 0)',
         case when count(*) = 0 then 'PASS' else 'FAIL' end,
         coalesce(string_agg(grantee || ':' || table_name || ':' || privilege_type, ', '), '(none)')
  from   information_schema.role_table_grants
  where  table_schema = 'public'
    and  table_name in ('agreement_templates','agreements','agreement_parties','agreement_events')
    and  grantee in ('authenticated','anon')

  union all
  -- 4. agreement_events service_role: has INSERT+SELECT, NOT update/delete/truncate
  --    (REFERENCES/TRIGGER may remain from the auto ALL grant; harmless, not row mutation)
  select 4,
         '4. agreement_events service_role INSERT+SELECT, no UPDATE/DELETE/TRUNCATE',
         case when bool_or(privilege_type = 'INSERT') and bool_or(privilege_type = 'SELECT')
                   and not bool_or(privilege_type in ('UPDATE','DELETE','TRUNCATE'))
              then 'PASS' else 'FAIL' end,
         coalesce(string_agg(privilege_type, ',' order by privilege_type), '(none)')
  from   information_schema.role_table_grants
  where  table_schema = 'public' and table_name = 'agreement_events' and grantee = 'service_role'

  union all
  -- 5. append-only trigger present on agreement_events
  select 5,
         '5. append-only trigger on agreement_events',
         case when exists (
                select 1 from pg_trigger
                where tgrelid = 'public.agreement_events'::regclass
                  and tgname = 'trg_agreement_events_append_only' and not tgisinternal)
              then 'PASS' else 'FAIL' end,
         coalesce((select string_agg(tgname, ', ') from pg_trigger
                   where tgrelid = 'public.agreement_events'::regclass and not tgisinternal), '(none)')

  union all
  -- 6. plan §11 columns on agreements: business_unit NOT NULL default 'PM' + check;
  --    company_id NULLABLE; counterparty_name present
  select 6,
         '6. agreements §11 cols (business_unit NN/def PM/check, company_id nullable, counterparty_name)',
         case when
              (select is_nullable = 'NO' and coalesce(column_default, '') like '%PM%'
                 from information_schema.columns
                 where table_schema = 'public' and table_name = 'agreements' and column_name = 'business_unit')
          and (select is_nullable = 'YES'
                 from information_schema.columns
                 where table_schema = 'public' and table_name = 'agreements' and column_name = 'company_id')
          and exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'agreements' and column_name = 'counterparty_name')
          and exists (select 1 from pg_constraint
                 where conrelid = 'public.agreements'::regclass and contype = 'c'
                   and pg_get_constraintdef(oid) ilike '%business_unit%')
              then 'PASS' else 'FAIL' end,
         (select string_agg(column_name || '(' || is_nullable
                   || case when column_default is not null then ' def ' || column_default else '' end || ')',
                   ', ' order by column_name)
            from information_schema.columns
            where table_schema = 'public' and table_name = 'agreements'
              and column_name in ('business_unit','company_id','counterparty_name'))

) v
order by ord;
