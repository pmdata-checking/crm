# PROSPECTManager CRM

Static HTML CRM deployed to Netlify at [crm.prospectmanager.co.uk](https://crm.prospectmanager.co.uk), backed by Supabase. Shares authentication with the Research site.

## Files

- `index.html` — the CRM single-page app
- `crm-importer.js` — bookmarklet script for importing customers from windowbase.info
- `crm-import-bookmarklet.html` — installer page for the bookmarklet
- `supabase-schema.sql` — database schema (run in Supabase SQL Editor)
- `send-email.ts` — Supabase edge function for sending emails via Resend

## Deployment

Pushes to `main` auto-deploy to Netlify.

## Supabase

- Project: `zmnofnsvonarpevzrkuo.supabase.co`
- Tables: `crm_customers`, `crm_contacts`, `crm_subscriptions`, `crm_communications`
- Shared: `user_roles` (with Research site)
- Edge functions: `manager-users`, `send-email`
