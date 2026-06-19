-- 07: add honorific title to crm_contacts (Mr/Mrs/Ms/Miss/Dr — free text, blank = none)
-- Idempotent. New column inherits crm_contacts RLS; no policy change needed.
alter table crm_contacts add column if not exists title text;
