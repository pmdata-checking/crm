# PROSPECTManager CRM

Static single-page app (`index.html`) on **Cloudflare Pages** at
[crm.prospectmanager.co.uk](https://crm.prospectmanager.co.uk), backed by Supabase
(`zmnofnsvonarpevzrkuo`). Shares Supabase Auth with the Research site (cross-site
token handoff + Microsoft SSO + magic links). **Lapsed-customer reactivation pipeline.**

## Deployment
Push to `main` → Cloudflare Pages auto-deploys. No build step (single-file SPA).

## Schema (Supabase project `zmnofnsvonarpevzrkuo`)
- **crm_customers** — company_name, status (prospect/active/trial/contra/lapsed),
  website, address fields, notes, **pipeline_stage** (new/researching/contacted/
  in conversation/quoted/won/lost/on hold), **follow_up_on** (date), **next_action**,
  **company_number**, created_at/updated_at.
- **crm_contacts** — customer_id → crm_customers (cascade), name/title/email/phone/mobile, is_primary.
- **crm_subscriptions** — customer_id → crm_customers (cascade), plan, price, billing_cycle, dates, trial/contra/current flags.
- **crm_communications** — customer_id → crm_customers (cascade), logged_by (auth.users),
  **logged_by_name** (denormalised), comm_type, direction, subject, body, occurred_at.
- Shared: **user_roles** (read-only, with the Research site).
- RLS: all `crm_*` tables = authenticated full CRUD (no per-user scoping).

## Features
- **Working list:** sort by follow-up date (overdue/today flagged), filter by pipeline
  stage and status, search, status stat cards.
- **Single company:** Reactivation Pipeline card (stage / follow-up / next action +
  Save Pipeline); subscription panel greyed until stage = won; contacts; comms log
  showing who logged each entry + when, with per-entry delete (confirm + hard delete).
- Email via the shared `send-email` Edge Function (Resend); windowbase import bookmarklet.

## SQL — run in the Supabase SQL editor, IN ORDER (RLS blocks the anon key)
1. `sql/01_clear_failed_import.sql` — clear the botched 43-record import
2. `sql/02_add_pipeline_fields.sql` — pipeline_stage, follow_up_on, next_action + indexes
3. `sql/03_add_comms_logged_by_name.sql` — logged_by_name on crm_communications
4. `sql/04a_add_company_number.sql` — company_number on crm_customers
5. `sql/04b_import_149_lapsed.sql` — import 149 confirmed lapsed customers

## Files
`index.html` (app) · `crm.html` (legacy view) · `crm-importer.js` + `crm-import-bookmarklet.html` (importer) · `send-email.ts` (Edge Function) · `supabase-schema.sql` (full schema) · `sql/` (migrations + import, run-order above)
