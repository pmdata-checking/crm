# PROSPECTManager CRM — Decisions

Design decisions for the CRM app (`pmdata-checking/crm`). Append-only in spirit; group by topic, newest first within a topic.

---

## E-sign (customer agreements)

### counterparty_name snapshot at create time (Phase 2, PROSPECTManager)

**Decision:** `create_agreement` will snapshot `agreements.counterparty_name` from the company (`crm_customers.company_name`) at create time, as an evidence freeze. It records who we contracted with as at the signing date and survives later company renames.

**Why:** the agreement is signed legal evidence. Reading the company name live through the `company_id` FK would show the company's *current* name, not its name when the agreement was signed; a later rename would silently rewrite what the record appears to say. This matches the same reasoning already applied to the signer party's `name`/`email` snapshot in `agreement_parties`.

**Status:** the `counterparty_name` column exists from Phase 0 (`sql/09_esign_schema.sql`). Population is **deferred to the Phase 2 staff-UI build** — Phase 1's `create_agreement` leaves it null for PM (the name is still reachable via `company_id`). For the future Research path it is typed in (no CRM company to read from).

---

## RLS

### Standardise CRM RLS on `TO authenticated`, not `auth.role()` (30 July 2026)

**Decision:** all `crm_*` table policies should be written `TO authenticated` with
`USING (true) WITH CHECK (true)`, rather than as `{public}` policies gated on
`auth.role() = 'authenticated'`. Accepted 30 July 2026.

**Why:** `TO authenticated` states the intent in the policy's role list, where a reader
looks first, instead of burying it in a `USING` expression that has to be read and
evaluated. It also removes the temptation to add speculative per-command policies when
something appears not to work, which is how the current asymmetry arose.

**Status: applied to `crm_communications` only.** On 30 July 2026 `auth_all_communications`
was dropped and replaced by `crm_communications_all` (`FOR ALL`, `TO authenticated`,
`USING (true) WITH CHECK (true)`). `crm_customers`, `crm_contacts` and `crm_subscriptions`
are **outstanding** and still run the legacy pattern. Tracked in `MRA-NOTES/TODO.md`
Priority 7. Nothing is broken in the meantime: the legacy pattern works and blocks the
anon key.

**Also outstanding:** an INSERT policy `Authenticated users can insert communications` was
added the same day and is redundant now that the `FOR ALL` policy exists. It was left in
place so the recorded state matches the database; drop it with the migration above.

**Context, and a warning for whoever picks this up:** the trigger was a researcher hitting
`new row violates row level security policy for table crm_communications` on save. The
cause was an **expired session** arriving as the **anon** role, not a policy defect.
`auth.role()` works correctly whenever the session is valid. The extra INSERT policies on
`crm_customers` and `crm_contacts` are **not** evidence to the contrary; they are most
likely residue from an earlier round of the same confusion, and reading them as a policy
defect sent the 30 July diagnosis down the wrong path for several steps. Full write-up:
`MRA-NOTES/session-notes/2026-07-30.md`.
