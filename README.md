# advisor-crm-rls

A small, runnable demo of per-advisor row-level security (RLS) in PostgreSQL — the pattern you need any time one shared database holds multiple people's client books (advisors, sales reps, account managers, case workers) and each of them must only ever see their own.

This is a fresh, synthetic-data reimplementation of the pattern for a public demo — not a copy of any production code.

## The problem

A CRM with one `clients` table and one database role for "the app" has no way to stop advisor A from reading or editing advisor B's clients — the application code has to remember to add `WHERE owner_advisor_id = current_user` to every single query, forever, across every endpoint anyone ever writes. Miss one, and you have a data leak or a cross-advisor edit.

Row-level security moves that rule into the database itself: Postgres evaluates it on every statement, for every role it's attached to, regardless of what the application code does or forgets to do.

## Design

- **Roles.** `web_advisor` and `web_manager` are the two roles the API connects as. Advisors get full CRUD on their own `clients`/`interactions` rows; managers get read-only visibility into their direct reports' rows. Neither role owns the tables and neither has `BYPASSRLS`, so RLS always applies to them (see pitfalls below).
- **Identity.** The API puts the caller's identity into a per-request Postgres GUC, `request.jwt.claims` — a JSON blob, e.g. `{"advisor_id": "2", "role": "advisor"}`. This is exactly what [PostgREST](https://postgrest.org/) does in production: it decodes the caller's JWT, exposes every claim as that one JSON GUC for the duration of the request, and switches `SET ROLE` based on the `role` claim. Policies here read the claims back out through two small SQL functions, `auth.advisor_id()` and `auth.role_name()`.
  - The alternative — one plain GUC per field, e.g. `current_setting('app.advisor_id')` — also works and is marginally simpler to write policies against. I used the JWT-claim shape instead because it's what you'll actually be debugging if this sits behind PostgREST (or anything that follows the same convention), and because it keeps every claim in one place instead of one `SET` per field.
  - Either way, the non-negotiable part is **how** it's set: always `SET LOCAL`, never bare `SET`, inside the request's own transaction. `SET LOCAL` reverts automatically at `COMMIT`/`ROLLBACK`, so a value can never leak across requests on a pooled connection. (PostgREST does this for you. If you ever skip the request layer and hand out a long-lived connection, you own this guarantee yourself.)
- **`USING` vs `WITH CHECK`.** Every write policy below sets both. `USING` controls which *existing* rows a statement can see/touch; `WITH CHECK` controls what the *resulting* row is allowed to look like. Set only `USING` on an `UPDATE` policy and an advisor can update their own row and quietly reassign `owner_advisor_id` to someone else — the check that stopped them from reading row 2 doesn't stop them from turning their own row 1 *into* row 2's owner. Test 4 below exists specifically to prove this is blocked.
- **Out of scope by design**, to keep the demo focused: the `advisors` directory table itself isn't RLS-scoped (any advisor or manager role can read the whole roster — names/emails, not client data), and managers are read-only rather than able to edit their team's rows. Both are one more policy away if your real system needs them.

## Schema

```
advisors (id, full_name, email, manager_id -> advisors.id)
clients  (id, owner_advisor_id -> advisors.id, full_name, phone, created_at)
interactions (id, client_id -> clients.id, advisor_id -> advisors.id, note, occurred_at)
```

Two independent management chains are seeded (`seed.sql`) so the tests can prove a manager sees *their* team and nothing from the other one:

- Team A: Asha Mehta (manager) -> Rohan Iyer, Priya Nair
- Team B: Vikram Shah (manager) -> Neha Kulkarni

All names, emails and phone numbers in `seed.sql` are made up for this repo.

## Running it

Requires Docker and `make`.

```bash
make test
```

This brings up `postgres:16` in Docker, loads `schema.sql` then `seed.sql`, and runs `tests/isolation_test.sql`. The test script uses `psql -v ON_ERROR_STOP=1`, so any `RAISE EXCEPTION` (a failed assertion) aborts with a non-zero exit code — a clean pass/fail signal for CI. On success it prints `PASS (test N): ...` for each check and ends with `ALL TESTS PASSED`.

Tear down with `make down`.

### What the tests prove

1. An advisor cannot read another advisor's clients.
2. An advisor's `UPDATE` targeting another advisor's client by id affects 0 rows (the row is invisible, not just "not writable").
3. An advisor cannot `INSERT` a client with a forged `owner_advisor_id` — rejected by `WITH CHECK`.
4. An advisor cannot `UPDATE` their own client to reassign it to another advisor — rejected by `WITH CHECK`, not just `USING`.
5. A manager sees exactly their team's clients (not their own, since managers hold no clients directly in this demo; not the other team's).
6. A manager's write attempt is rejected (managers are read-only in this demo).
7. `interactions` are isolated the same way as `clients`.

## Common pitfalls this guards against

- **Service-role / superuser connections bypass RLS entirely.** Any role with `BYPASSRLS`, and any table owner on a table without `FORCE ROW LEVEL SECURITY`, skips every policy. This is the single most common way RLS "works in testing, leaks in production" — a migration script, an admin tool, or a backup job quietly uses the superuser connection string instead of the scoped API role. `clients` and `interactions` here are created with `FORCE ROW LEVEL SECURITY` and are owned by a different role than `web_advisor`/`web_manager`, so even if you later grant those roles something resembling ownership, RLS still applies to them.
- **`SECURITY DEFINER` functions run as their owner, not as the caller.** A helper function marked `SECURITY DEFINER` (often used to work around RLS for "just this one report") silently runs with the privileges of whoever created it — frequently a superuser — and can read or write rows the calling role could never touch directly. Treat every `SECURITY DEFINER` function as a potential RLS bypass and review it like one.
- **Missing `WITH CHECK` on an `UPDATE` policy.** Covered above and in test 4 — a policy with only `USING` lets a row be rewritten into a shape the policy wouldn't have let you select in the first place (e.g. reassigning `owner_advisor_id` to someone else).
- **Missing `WITH CHECK` on an `INSERT` policy is the opposite failure, and the more dangerous one: it defaults to "allow any row", not "deny all".** `INSERT` has no existing row for `USING` to filter, so if you forget `WITH CHECK` on an `INSERT` policy, the role can insert a row with *any* value in the column you meant to restrict — e.g. any `owner_advisor_id` at all. Always write `WITH CHECK` explicitly on every `INSERT` policy (test 3 here proves it's enforced); never assume it inherits a restriction from somewhere else.
- **`SET` instead of `SET LOCAL` on a pooled connection.** `SET` persists for the life of the connection; with a connection pooler handing that same backend to a different request next, the next request inherits the previous caller's identity. Always scope identity GUCs to the transaction with `SET LOCAL`.
- **RLS enabled but zero policies defined silently means "deny all"**, not "allow all" — easy to mistake for a bug in the app layer when it's actually a missing policy.

## How I used this in production

I built the production version of this pattern for a wealth-advisory CRM where each advisor's client book needed to be isolated from every other advisor's, with a manager role able to see their team's book for coaching and review, running on a self-hosted PostgreSQL + PostgREST + Next.js stack. The real version also has indexes to keep the RLS subqueries (like the manager's team lookup here) fast at scale, and audit logging on top — both easy follow-ons to this demo once the isolation guarantee itself is in place.

## License

MIT — see [LICENSE](LICENSE).
