-- 10: e-sign — staff RPCs (Phase 1)
-- ============================================================
-- The staff side of the trust boundary (plan §4). All five are SECURITY DEFINER
-- so they run as the table owner and bypass the default-deny RLS from sql/09 —
-- the ONLY way staff (authenticated MS-SSO users) reach the agreement tables.
-- EXECUTE is granted to `authenticated` only; `anon` gets nothing, so the signer
-- (token) side can never call these — it uses the service-role Edge Functions.
--
-- token_hash is NEVER returned by any of these (get_agreement exposes only a
-- has_token boolean + token_expires). The raw token lives solely in the email.
--
-- Idempotent (create or replace). Run AFTER sql/09_esign_schema.sql.
-- ============================================================


-- ------------------------------------------------------------
-- crm_is_superuser() — caller is a superuser? Mirrors the client check
-- (user_roles.role = 'superuser' keyed on user_email), case-insensitive. Reads
-- the CALLER's JWT even when invoked from inside another SECURITY DEFINER fn.
-- ------------------------------------------------------------
create or replace function crm_is_superuser()
returns boolean
language sql security definer set search_path = public stable
as $$
  select exists (
    select 1 from user_roles
    where lower(user_email) = lower(auth.jwt() ->> 'email')
      and role = 'superuser'
  );
$$;


-- ------------------------------------------------------------
-- create_agreement(company, contact, template, title) -> agreement_id
-- Creates a draft, snapshots the signer party from the contact, logs 'created'.
-- Validates the contact belongs to the company and the template (if given) is active.
-- ------------------------------------------------------------
create or replace function create_agreement(
  p_company_id  uuid,
  p_contact_id  uuid,
  p_template_id uuid,
  p_title       text
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_uid          uuid := auth.uid();
  v_email        text := auth.jwt() ->> 'email';
  v_contact      crm_contacts%rowtype;
  v_agreement_id uuid;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (select 1 from crm_customers where id = p_company_id) then
    raise exception 'Company % not found', p_company_id;
  end if;

  select * into v_contact
  from crm_contacts
  where id = p_contact_id and customer_id = p_company_id;
  if not found then
    raise exception 'Contact % does not belong to company %', p_contact_id, p_company_id;
  end if;

  if p_template_id is not null
     and not exists (select 1 from agreement_templates where id = p_template_id and active) then
    raise exception 'Template % not found or inactive', p_template_id;
  end if;

  insert into agreements (company_id, template_id, title, status, created_by)
  values (
    p_company_id, p_template_id,
    coalesce(nullif(btrim(p_title), ''), 'Untitled agreement'),
    'draft', v_uid
  )
  returning id into v_agreement_id;

  -- Signer party snapshot (token added later by the send-agreement Edge fn).
  insert into agreement_parties (agreement_id, role, sign_order, name, email)
  values (
    v_agreement_id, 'signer', 1,
    nullif(btrim(
      concat_ws(' ', nullif(btrim(coalesce(v_contact.title,'')), ''),
                     v_contact.first_name, v_contact.last_name)
    ), ''),
    v_contact.email
  );

  insert into agreement_events (agreement_id, event_type, actor_email)
  values (v_agreement_id, 'created', v_email);

  return v_agreement_id;
end;
$$;


-- ------------------------------------------------------------
-- list_agreements(company) -> jsonb array (newest first), with party summary.
-- No token_hash.
-- ------------------------------------------------------------
create or replace function list_agreements(p_company_id uuid)
returns jsonb
language sql security definer set search_path = public stable
as $$
  select coalesce(jsonb_agg(obj order by created_at desc), '[]'::jsonb)
  from (
    select ag.created_at,
      jsonb_build_object(
        'id', ag.id, 'title', ag.title, 'status', ag.status,
        'locked', ag.locked, 'created_at', ag.created_at, 'completed_at', ag.completed_at,
        'parties', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'role', p.role, 'sign_order', p.sign_order, 'name', p.name,
            'email', p.email, 'acknowledged', p.acknowledged, 'signed_at', p.signed_at
          ) order by p.sign_order), '[]'::jsonb)
          from agreement_parties p where p.agreement_id = ag.id
        )
      ) as obj
    from agreements ag
    where ag.company_id = p_company_id
  ) t;
$$;


-- ------------------------------------------------------------
-- get_agreement(id) -> jsonb: full state + parties (no token_hash) + the event
-- timeline (ordered). 'has_token' exposes whether a link has been issued.
-- ------------------------------------------------------------
create or replace function get_agreement(p_agreement_id uuid)
returns jsonb
language sql security definer set search_path = public stable
as $$
  select jsonb_build_object(
    'id', ag.id, 'company_id', ag.company_id, 'template_id', ag.template_id,
    'title', ag.title, 'status', ag.status, 'locked', ag.locked,
    'document_hash', ag.document_hash, 'signed_path', ag.signed_path,
    'created_by', ag.created_by, 'created_at', ag.created_at, 'completed_at', ag.completed_at,
    'parties', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'role', p.role, 'sign_order', p.sign_order, 'name', p.name,
        'email', p.email, 'acknowledged', p.acknowledged, 'signed_at', p.signed_at,
        'token_expires', p.token_expires, 'has_token', (p.token_hash is not null)
      ) order by p.sign_order), '[]'::jsonb)
      from agreement_parties p where p.agreement_id = ag.id
    ),
    'events', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'event_type', e.event_type, 'actor_email', e.actor_email,
        'ip_address', e.ip_address, 'user_agent', e.user_agent,
        'detail', e.detail, 'occurred_at', e.occurred_at
      ) order by e.occurred_at, e.id), '[]'::jsonb)
      from agreement_events e where e.agreement_id = ag.id
    )
  )
  from agreements ag
  where ag.id = p_agreement_id;
$$;


-- ------------------------------------------------------------
-- void_agreement(id, reason) -> jsonb. Blocks while locked (a completed
-- agreement is locked; a superuser must force_unlock first). Idempotent on an
-- already-voided row. Logs 'voided' with the reason in detail.
-- ------------------------------------------------------------
create or replace function void_agreement(p_agreement_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_email  text := auth.jwt() ->> 'email';
  v_status text;
  v_locked boolean;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select status, locked into v_status, v_locked
  from agreements where id = p_agreement_id;
  if not found then
    raise exception 'Agreement % not found', p_agreement_id;
  end if;

  if v_locked then
    raise exception 'Agreement is completed/locked; a superuser must force_unlock before voiding';
  end if;

  if v_status = 'voided' then
    return get_agreement(p_agreement_id);   -- already voided, no-op
  end if;

  update agreements set status = 'voided' where id = p_agreement_id;

  insert into agreement_events (agreement_id, event_type, actor_email, detail)
  values (p_agreement_id, 'voided', v_email, jsonb_build_object('reason', p_reason));

  return get_agreement(p_agreement_id);
end;
$$;


-- ------------------------------------------------------------
-- force_unlock(id) -> jsonb. Superuser only. Clears `locked` so a completed
-- agreement can then be voided/re-issued (a sealed PDF is never mutated in place,
-- per §8 — the override is to reopen for voiding, not to un-seal). Logs
-- 'force_unlocked' to the evidence spine.
-- ------------------------------------------------------------
create or replace function force_unlock(p_agreement_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_email text := auth.jwt() ->> 'email';
begin
  if not crm_is_superuser() then
    raise exception 'force_unlock is superuser only';
  end if;

  if not exists (select 1 from agreements where id = p_agreement_id) then
    raise exception 'Agreement % not found', p_agreement_id;
  end if;

  update agreements set locked = false where id = p_agreement_id;

  insert into agreement_events (agreement_id, event_type, actor_email, detail)
  values (p_agreement_id, 'force_unlocked', v_email, jsonb_build_object('action', 'force_unlock'));

  return get_agreement(p_agreement_id);
end;
$$;


-- ------------------------------------------------------------
-- EXECUTE grants: authenticated only.
-- This project's default privileges grant EXECUTE on new functions to `anon` AND
-- `authenticated` EXPLICITLY (the same auto-expose mechanism as the tables), on
-- top of the built-in PUBLIC default. Revoking PUBLIC alone does NOT clear the
-- explicit anon grant, so revoke from BOTH public and anon, then grant
-- authenticated back. (Mirrors the `from authenticated, anon` table revokes in 09.)
-- ------------------------------------------------------------
revoke execute on function crm_is_superuser()                      from public, anon;
revoke execute on function create_agreement(uuid,uuid,uuid,text)   from public, anon;
revoke execute on function list_agreements(uuid)                   from public, anon;
revoke execute on function get_agreement(uuid)                     from public, anon;
revoke execute on function void_agreement(uuid,text)               from public, anon;
revoke execute on function force_unlock(uuid)                      from public, anon;

grant execute on function crm_is_superuser()                       to authenticated;
grant execute on function create_agreement(uuid,uuid,uuid,text)    to authenticated;
grant execute on function list_agreements(uuid)                    to authenticated;
grant execute on function get_agreement(uuid)                      to authenticated;
grant execute on function void_agreement(uuid,text)                to authenticated;
grant execute on function force_unlock(uuid)                       to authenticated;


-- ============================================================
-- VERIFICATION (read-only) — SINGLE result set so the Supabase editor shows
-- every check at once (it renders only the last statement when several run
-- together). One row per check: check_name, result (PASS/FAIL), detail.
-- Expect all three rows PASS.
-- ============================================================
select check_name, result, detail from (

  -- 1. all six RPCs present and SECURITY DEFINER
  select 1 as ord,
         '1. six RPCs present + SECURITY DEFINER' as check_name,
         case when count(*) = 6 and count(*) filter (where p.prosecdef) = 6
              then 'PASS' else 'FAIL' end as result,
         string_agg(p.proname || case when p.prosecdef then '(def)' else '(INVOKER!)' end,
                    ', ' order by p.proname) as detail
  from   pg_proc p
  join   pg_namespace n on n.oid = p.pronamespace
  where  n.nspname = 'public'
    and  p.proname in ('crm_is_superuser','create_agreement','list_agreements',
                       'get_agreement','void_agreement','force_unlock')

  union all
  -- 2. EXECUTE granted to authenticated for all six
  select 2,
         '2. EXECUTE to authenticated (expect all 6)',
         case when count(distinct routine_name) = 6 then 'PASS' else 'FAIL' end,
         coalesce(string_agg(distinct routine_name, ', ' order by routine_name), '(none)')
  from   information_schema.role_routine_grants
  where  routine_schema = 'public' and grantee = 'authenticated' and privilege_type = 'EXECUTE'
    and  routine_name in ('crm_is_superuser','create_agreement','list_agreements',
                          'get_agreement','void_agreement','force_unlock')

  union all
  -- 3. NO EXECUTE for anon or PUBLIC on any of the six (expect 0)
  select 3,
         '3. no anon/PUBLIC EXECUTE (expect 0)',
         case when count(*) = 0 then 'PASS' else 'FAIL' end,
         coalesce(string_agg(grantee || ':' || routine_name, ', '), '(none)')
  from   information_schema.role_routine_grants
  where  routine_schema = 'public' and privilege_type = 'EXECUTE'
    and  grantee in ('anon','PUBLIC')
    and  routine_name in ('crm_is_superuser','create_agreement','list_agreements',
                          'get_agreement','void_agreement','force_unlock')

) v
order by ord;
