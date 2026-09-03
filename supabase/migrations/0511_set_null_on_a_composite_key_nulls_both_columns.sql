-- =====================================================================
-- 0511 :: `set null` on a composite key nulls both columns
--
-- A composite foreign key with `on delete set null` and no column list
-- sets EVERY referencing column to null. The first of ours is always
-- `org_id`, which is `not null`, so the delete does not empty the
-- reference -- it fails, with 23502:
--
--   create temp table p (o uuid not null, i uuid not null,
--                        primary key (o, i));
--   create temp table c (o uuid not null, m uuid,
--     constraint c_same foreign key (o, m) references p (o, i)
--       on delete set null);
--   insert into p values (v, v); insert into c values (v, v);
--   delete from p where i = v;
--   -- ERROR: null value in column "o" of relation "c"
--
-- Twenty constraints are shaped that way. Nine of them fail today, and
-- the proof is a delete, not a reading of the catalogue: deleting a
-- ticket team that a category names raises 23502 rather than clearing
-- `team_id`. Seven of the nine are the ticketing module (0098-0100),
-- which has been wrong since it shipped; the other two are
-- `pos_outlets.warehouse_id` (0510) and
-- `claim_approvals.approver_employee_id` (0508).
--
-- The remaining eleven work, and only by accident. Where 0508, 0509 and
-- 0166 put a composite key beside a plain single-column key that also
-- said `set null`, the plain key's trigger fires first, nulls the child
-- column on its own, and by the time the composite key's trigger runs
-- no row matches it any more. That is trigger firing order standing in
-- for a correct constraint. Drop and re-add the plain key some day and
-- the order flips and the deletes start failing. So all twenty are
-- fixed, not the nine that are currently visible.
--
-- Postgres 15 added the column list, which says WHICH referencing
-- columns to null. The local cluster is 16 and the hosted project is
-- 17, so both have it. Each constraint below is dropped and re-added
-- naming only its child column, leaving `org_id` alone.
--
-- Nothing caught this because no test deleted a row another row names.
-- `supabase/tests/tenant_foreign_keys.sql` now does, and also reads
-- `pg_constraint` for the shape, so the next composite key cannot
-- reintroduce it.
-- =====================================================================

alter table public.applicants
  drop constraint applicants_hired_employee_same_org,
  add  constraint applicants_hired_employee_same_org
       foreign key (org_id, hired_employee_id)
       references public.employees (org_id, id)
       on delete set null (hired_employee_id);
alter table public.applicants
  drop constraint applicants_referred_by_same_org,
  add  constraint applicants_referred_by_same_org
       foreign key (org_id, referred_by)
       references public.employees (org_id, id)
       on delete set null (referred_by);
alter table public.appraisals
  drop constraint appraisals_reviewer_same_org,
  add  constraint appraisals_reviewer_same_org
       foreign key (org_id, reviewer_id)
       references public.employees (org_id, id)
       on delete set null (reviewer_id);
alter table public.canned_responses
  drop constraint canned_responses_category_fk,
  add  constraint canned_responses_category_fk
       foreign key (org_id, category_id)
       references public.ticket_categories (org_id, id)
       on delete set null (category_id);
alter table public.claim_approvals
  drop constraint claim_approvals_approver_same_org,
  add  constraint claim_approvals_approver_same_org
       foreign key (org_id, approver_employee_id)
       references public.employees (org_id, id)
       on delete set null (approver_employee_id);
alter table public.collection_attempts
  drop constraint collection_attempts_document_same_org,
  add  constraint collection_attempts_document_same_org
       foreign key (org_id, document_id)
       references public.sales_documents (org_id, id)
       on delete set null (document_id);
alter table public.departments
  drop constraint departments_head_same_org,
  add  constraint departments_head_same_org
       foreign key (org_id, head_employee_id)
       references public.employees (org_id, id)
       on delete set null (head_employee_id);
alter table public.employees
  drop constraint employees_manager_same_org,
  add  constraint employees_manager_same_org
       foreign key (org_id, manager_id)
       references public.employees (org_id, id)
       on delete set null (manager_id);
alter table public.interviews
  drop constraint interviews_interviewer_same_org,
  add  constraint interviews_interviewer_same_org
       foreign key (org_id, interviewer_id)
       references public.employees (org_id, id)
       on delete set null (interviewer_id);
alter table public.job_requisitions
  drop constraint job_requisitions_hiring_manager_same_org,
  add  constraint job_requisitions_hiring_manager_same_org
       foreign key (org_id, hiring_manager_id)
       references public.employees (org_id, id)
       on delete set null (hiring_manager_id);
alter table public.onboarding_tasks
  drop constraint onboarding_tasks_owner_same_org,
  add  constraint onboarding_tasks_owner_same_org
       foreign key (org_id, owner_employee_id)
       references public.employees (org_id, id)
       on delete set null (owner_employee_id);
alter table public.pos_outlets
  drop constraint pos_outlets_warehouse_same_org,
  add  constraint pos_outlets_warehouse_same_org
       foreign key (org_id, warehouse_id)
       references public.warehouses (org_id, id)
       on delete set null (warehouse_id);
alter table public.pos_service_providers
  drop constraint pos_service_providers_employee_same_org,
  add  constraint pos_service_providers_employee_same_org
       foreign key (org_id, employee_id)
       references public.employees (org_id, id)
       on delete set null (employee_id);
alter table public.salespeople
  drop constraint salespeople_employee_same_org,
  add  constraint salespeople_employee_same_org
       foreign key (org_id, employee_id)
       references public.employees (org_id, id)
       on delete set null (employee_id);
alter table public.ticket_categories
  drop constraint ticket_categories_sla_fk,
  add  constraint ticket_categories_sla_fk
       foreign key (org_id, sla_policy_id)
       references public.sla_policies (org_id, id)
       on delete set null (sla_policy_id);
alter table public.ticket_categories
  drop constraint ticket_categories_team_fk,
  add  constraint ticket_categories_team_fk
       foreign key (org_id, team_id)
       references public.ticket_teams (org_id, id)
       on delete set null (team_id);
alter table public.tickets
  drop constraint tickets_asset_fk,
  add  constraint tickets_asset_fk
       foreign key (org_id, asset_id)
       references public.fixed_assets (org_id, id)
       on delete set null (asset_id);
alter table public.tickets
  drop constraint tickets_category_fk,
  add  constraint tickets_category_fk
       foreign key (org_id, category_id)
       references public.ticket_categories (org_id, id)
       on delete set null (category_id);
alter table public.tickets
  drop constraint tickets_sla_fk,
  add  constraint tickets_sla_fk
       foreign key (org_id, sla_policy_id)
       references public.sla_policies (org_id, id)
       on delete set null (sla_policy_id);
alter table public.tickets
  drop constraint tickets_team_fk,
  add  constraint tickets_team_fk
       foreign key (org_id, team_id)
       references public.ticket_teams (org_id, id)
       on delete set null (team_id);
