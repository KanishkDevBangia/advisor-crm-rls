-- advisor-crm-rls: isolation tests
--
-- Run with: psql -v ON_ERROR_STOP=1 -f tests/isolation_test.sql
-- Any RAISE EXCEPTION aborts the script with a non-zero exit code, so
-- this file doubles as a pass/fail gate for `make test`.
--
-- Every test wraps SET LOCAL ROLE + SET LOCAL request.jwt.claims inside
-- its own explicit BEGIN/COMMIT. This is deliberate: SET LOCAL only has
-- well-defined, transaction-scoped behaviour inside an explicit
-- transaction block, and it mirrors exactly what PostgREST does for each
-- real HTTP request (BEGIN; SET LOCAL ROLE ...; SET LOCAL request.jwt.claims
-- ...; <query>; COMMIT;) — so identity never leaks from one "request" to
-- the next on the same connection.
--
-- Team A: Asha (1, manager) -> Rohan (2), Priya (3)
-- Team B: Vikram (4, manager) -> Neha (5)
-- Clients 1,2 -> Rohan(2); client 3 -> Priya(3); clients 4,5 -> Neha(5)

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
-- Test 1: an advisor cannot read another advisor's clients
-- ---------------------------------------------------------------------
begin;
set local role web_advisor;
set local request.jwt.claims = '{"advisor_id":"2","role":"advisor"}';

do $$
declare
  own_count   int;
  other_count int;
begin
  select count(*) into own_count from clients where owner_advisor_id = 2;
  select count(*) into other_count from clients where owner_advisor_id = 3;

  if own_count <> 2 then
    raise exception 'FAIL (test 1a): advisor 2 should see 2 own clients, saw %', own_count;
  end if;

  if other_count <> 0 then
    raise exception 'FAIL (test 1b): advisor 2 could see advisor 3''s clients (% rows)', other_count;
  end if;

  raise notice 'PASS (test 1): advisor sees only their own clients (own=%, other=%)', own_count, other_count;
end $$;
commit;

-- ---------------------------------------------------------------------
-- Test 2: an advisor cannot UPDATE another advisor's client by targeting
-- its id directly (the row simply isn't visible to UPDATE either)
-- ---------------------------------------------------------------------
begin;
set local role web_advisor;
set local request.jwt.claims = '{"advisor_id":"2","role":"advisor"}';

do $$
declare
  affected int;
begin
  update clients set phone = '+91-00000-00000' where id = 3; -- belongs to advisor 3
  get diagnostics affected = row_count;

  if affected <> 0 then
    raise exception 'FAIL (test 2): advisor 2 updated advisor 3''s client (% rows affected)', affected;
  end if;

  raise notice 'PASS (test 2): cross-advisor UPDATE by id affects 0 rows';
end $$;
commit;

-- ---------------------------------------------------------------------
-- Test 3: an advisor cannot INSERT a client with a forged owner_advisor_id
-- ---------------------------------------------------------------------
begin;
set local role web_advisor;
set local request.jwt.claims = '{"advisor_id":"2","role":"advisor"}';

do $$
begin
  begin
    insert into clients (owner_advisor_id, full_name) values (3, 'Forged Client');
    raise exception 'FAIL (test 3): forged insert (owner_advisor_id=3 while acting as advisor 2) succeeded';
  exception
    when insufficient_privilege then
      raise notice 'PASS (test 3): forged insert rejected by WITH CHECK (%)', sqlerrm;
  end;
end $$;
commit;

-- ---------------------------------------------------------------------
-- Test 4: an advisor cannot UPDATE their own client to reassign it to
-- another advisor (WITH CHECK blocks "escaping" the policy on write)
-- ---------------------------------------------------------------------
begin;
set local role web_advisor;
set local request.jwt.claims = '{"advisor_id":"2","role":"advisor"}';

do $$
begin
  begin
    update clients set owner_advisor_id = 3 where id = 1; -- advisor 2's own client
    raise exception 'FAIL (test 4): advisor 2 reassigned their own client to advisor 3';
  exception
    when insufficient_privilege then
      raise notice 'PASS (test 4): reassignment blocked by WITH CHECK (%)', sqlerrm;
  end;
end $$;
commit;

-- sanity: client 1 must still belong to advisor 2 after the blocked attempt
-- (run as superuser, outside RLS, just to confirm the DB state is intact)
do $$
declare
  owner int;
begin
  select owner_advisor_id into owner from clients where id = 1;
  if owner <> 2 then
    raise exception 'FAIL (test 4 sanity): client 1 owner changed to % unexpectedly', owner;
  end if;
  raise notice 'PASS (test 4 sanity): client 1 still owned by advisor 2';
end $$;

-- ---------------------------------------------------------------------
-- Test 5: a manager sees their whole team's clients, and nothing else
-- ---------------------------------------------------------------------
begin;
set local role web_manager;
set local request.jwt.claims = '{"advisor_id":"1","role":"manager"}'; -- Asha, manages Rohan+Priya

do $$
declare
  team_count  int;
  other_count int;
begin
  select count(*) into team_count from clients; -- RLS already scopes this to the team
  select count(*) into other_count from clients where owner_advisor_id = 5; -- Neha, team B

  if team_count <> 3 then -- Rohan (2) + Priya (1) = 3
    raise exception 'FAIL (test 5a): manager 1 should see 3 team clients, saw %', team_count;
  end if;

  if other_count <> 0 then
    raise exception 'FAIL (test 5b): manager 1 could see team B''s clients (% rows)', other_count;
  end if;

  raise notice 'PASS (test 5): manager sees exactly their team''s clients (team=%, other=%)', team_count, other_count;
end $$;
commit;

-- ---------------------------------------------------------------------
-- Test 6: a manager cannot write (this demo grants managers SELECT only)
-- ---------------------------------------------------------------------
begin;
set local role web_manager;
set local request.jwt.claims = '{"advisor_id":"1","role":"manager"}';

do $$
begin
  begin
    update clients set phone = '+91-11111-11111' where owner_advisor_id = 2;
    raise exception 'FAIL (test 6): manager was able to write to a client row';
  exception
    when insufficient_privilege then
      raise notice 'PASS (test 6): manager write rejected (%)', sqlerrm;
  end;
end $$;
commit;

-- ---------------------------------------------------------------------
-- Test 7: interactions are isolated the same way as clients
-- ---------------------------------------------------------------------
begin;
set local role web_advisor;
set local request.jwt.claims = '{"advisor_id":"5","role":"advisor"}'; -- Neha

do $$
declare
  own_count int;
begin
  select count(*) into own_count from interactions where advisor_id = 5;
  if own_count <> 2 then
    raise exception 'FAIL (test 7): advisor 5 should see 2 own interactions, saw %', own_count;
  end if;

  perform 1 from interactions where advisor_id = 2; -- Rohan's interactions must be invisible
  if found then
    raise exception 'FAIL (test 7): advisor 5 could see advisor 2''s interactions';
  end if;

  raise notice 'PASS (test 7): interactions isolated per advisor';
end $$;
commit;

\echo 'ALL TESTS PASSED'
