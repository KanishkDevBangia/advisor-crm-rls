-- advisor-crm-rls: schema
--
-- Demonstrates per-advisor row-level security (RLS) for a wealth-advisory
-- CRM, using the same request-context pattern PostgREST uses in production:
-- the API layer puts the caller's identity into a per-request GUC
-- (`request.jwt.claims`, a JSON blob decoded from the caller's JWT) and
-- Postgres RLS policies read it back out. This means isolation is enforced
-- by the database itself, not by application code remembering to add a
-- WHERE clause.
--
-- Why request.jwt.claims (JWT-claim style) instead of a single
-- current_setting('app.advisor_id'):
--   - It matches what PostgREST actually does: it decodes the caller's JWT
--     and exposes every claim as one JSON GUC per request, then switches
--     Postgres role via the `role` claim. Policies here read real claims,
--     so this demo is directly portable to a PostgREST-fronted API.
--   - A single custom GUC per field (app.advisor_id, app.role, ...) also
--     works and is slightly simpler to write policies against, but it
--     requires the API layer to set multiple GUCs per request instead of
--     one, and doesn't mirror what you'll actually debug in production.
--   - Either approach is "trusted input from the connection pooler", so
--     the hard requirement is the same either way: only the API's
--     connection role may set these values, and it must always run every
--     request inside its own transaction with SET LOCAL (never SET), so
--     the value can never leak across pooled connections or requests.

begin;

create schema if not exists auth;

-- Pull the caller's JWT claims (set per-request by the API layer via
-- `SET LOCAL request.jwt.claims = '{"advisor_id": "...", "role": "..."}'`).
-- `true` on current_setting means "return NULL instead of erroring" when
-- the GUC hasn't been set — e.g. a superuser running ad-hoc queries.
create or replace function auth.jwt_claims() returns json
language sql stable
as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::json
$$;

create or replace function auth.advisor_id() returns int
language sql stable
as $$
  select nullif(auth.jwt_claims() ->> 'advisor_id', '')::int
$$;

create or replace function auth.role_name() returns text
language sql stable
as $$
  select coalesce(auth.jwt_claims() ->> 'role', '')
$$;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------

create table advisors (
  id         serial primary key,
  full_name  text not null,
  email      text not null unique,
  manager_id int references advisors(id) -- NULL = this advisor is a manager / has no manager in this demo
);

create table clients (
  id                serial primary key,
  owner_advisor_id  int not null references advisors(id),
  full_name         text not null,
  phone             text,
  created_at        timestamptz not null default now()
);

create table interactions (
  id           serial primary key,
  client_id    int not null references clients(id) on delete cascade,
  advisor_id   int not null references advisors(id), -- advisor who logged the interaction
  note         text not null,
  occurred_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Roles
--
-- `web_advisor` / `web_manager` are the roles the API connects as (in a
-- real PostgREST setup, selected per-request via the JWT's `role` claim
-- and an `authenticator` login role with SET ROLE privileges). This demo
-- grants them to whichever role runs the scripts (current_user, i.e. the
-- docker image's default `postgres` superuser) purely so `SET ROLE` works
-- without provisioning a second login role/password for a local demo.
-- Neither role is ever granted BYPASSRLS, and neither owns the tables
-- (see pitfalls in README), so RLS always applies to them.
-- ---------------------------------------------------------------------

create role web_advisor nologin noinherit;
create role web_manager nologin noinherit;

grant web_advisor to current_user;
grant web_manager to current_user;

grant usage on schema public to web_advisor, web_manager;
grant usage on schema auth to web_advisor, web_manager;

grant select on advisors to web_advisor, web_manager;

grant select, insert, update, delete on clients to web_advisor;
grant select on clients to web_manager;

grant select, insert, update, delete on interactions to web_advisor;
grant select on interactions to web_manager;

grant usage, select on all sequences in schema public to web_advisor;

-- ---------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------

alter table clients enable row level security;
alter table clients force row level security; -- applies even if a future owner-role query runs
alter table interactions enable row level security;
alter table interactions force row level security;

-- An advisor may only see/insert/update/delete their own clients.
-- USING governs which existing rows are visible to SELECT/UPDATE/DELETE.
-- WITH CHECK governs which NEW/MODIFIED row values are allowed — without
-- it, an advisor could UPDATE their own row and reassign owner_advisor_id
-- to someone else's id, "escaping" the policy on write.
create policy advisor_select_own_clients on clients
  for select
  to web_advisor
  using (owner_advisor_id = auth.advisor_id());

create policy advisor_insert_own_clients on clients
  for insert
  to web_advisor
  with check (owner_advisor_id = auth.advisor_id());

create policy advisor_update_own_clients on clients
  for update
  to web_advisor
  using (owner_advisor_id = auth.advisor_id())
  with check (owner_advisor_id = auth.advisor_id());

create policy advisor_delete_own_clients on clients
  for delete
  to web_advisor
  using (owner_advisor_id = auth.advisor_id());

-- A manager sees (read-only, in this demo) clients owned by advisors who
-- report to them.
create policy manager_select_team_clients on clients
  for select
  to web_manager
  using (
    owner_advisor_id in (
      select id from advisors where manager_id = auth.advisor_id()
    )
  );

-- Interactions follow the same ownership rule, keyed on the advisor who
-- logged the note.
create policy advisor_select_own_interactions on interactions
  for select
  to web_advisor
  using (advisor_id = auth.advisor_id());

create policy advisor_insert_own_interactions on interactions
  for insert
  to web_advisor
  with check (advisor_id = auth.advisor_id());

create policy advisor_update_own_interactions on interactions
  for update
  to web_advisor
  using (advisor_id = auth.advisor_id())
  with check (advisor_id = auth.advisor_id());

create policy advisor_delete_own_interactions on interactions
  for delete
  to web_advisor
  using (advisor_id = auth.advisor_id());

create policy manager_select_team_interactions on interactions
  for select
  to web_manager
  using (
    advisor_id in (
      select id from advisors where manager_id = auth.advisor_id()
    )
  );

commit;
