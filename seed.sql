-- advisor-crm-rls: synthetic seed data
-- All names, emails, phone numbers and notes below are fictional, made up
-- for this demo. No real client or staff data.

begin;

-- Two independent management chains, so tests can prove a manager sees
-- only their own team and not the other team's clients.

insert into advisors (id, full_name, email, manager_id) values
  (1, 'Asha Mehta',    'asha.mehta.demo@example.com',    null), -- manager, team A
  (2, 'Rohan Iyer',    'rohan.iyer.demo@example.com',     1),
  (3, 'Priya Nair',    'priya.nair.demo@example.com',     1),
  (4, 'Vikram Shah',   'vikram.shah.demo@example.com',    null), -- manager, team B
  (5, 'Neha Kulkarni', 'neha.kulkarni.demo@example.com',  4);

select setval('advisors_id_seq', (select max(id) from advisors));

insert into clients (id, owner_advisor_id, full_name, phone) values
  (1, 2, 'Test Client One',   '+91-90000-00001'),
  (2, 2, 'Test Client Two',   '+91-90000-00002'),
  (3, 3, 'Test Client Three', '+91-90000-00003'),
  (4, 5, 'Test Client Four',  '+91-90000-00004'),
  (5, 5, 'Test Client Five',  '+91-90000-00005');

select setval('clients_id_seq', (select max(id) from clients));

insert into interactions (client_id, advisor_id, note) values
  (1, 2, 'Demo note: discussed SIP top-up.'),
  (2, 2, 'Demo note: sent portfolio statement.'),
  (3, 3, 'Demo note: scheduled annual review call.'),
  (4, 5, 'Demo note: KYC document follow-up.'),
  (5, 5, 'Demo note: discussed risk profile change.');

commit;
