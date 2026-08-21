-- =====================================================================
-- A written-off bill has to show somewhere
--
-- 0246 gave a till a way to write off a whole bill and 0247 put it
-- behind a grant. Between them they left a hole, and it is the hole the
-- grant was tightened for.
--
-- `pos_void_summary` reads `pos_sale_line_voids`, and a bill void only
-- writes rows there for lines the kitchen cooked. So the one case 0247
-- was written to control -- an order rung up, paid in cash, and made to
-- go away before the kitchen ever saw it -- produces no void lines, no
-- value, and appears in no report at all. A cashier could do it every
-- night and the only trace would be a `voided` row nothing reads.
--
-- The sale already records everything needed to answer for it: what it
-- came to, why, who, and when. Nothing was reading it.
--
-- ---------------------------------------------------------------------
-- One row per bill, not per reason
--
-- The line report groups, deliberately: one void is an accident and
-- thirty "never came out" is a conversation, and listing every incident
-- would bury the pattern in the evidence.
--
-- A written-off bill is the other shape. There are far fewer of them,
-- each is a whole order rather than a plate, and the question a manager
-- asks is "which ones, and who" rather than "how many of what kind".
-- Grouping these would hide the only fact that matters.
--
-- The total on the bill is reported whether or not the kitchen cooked
-- any of it, because what was rung up is what the customer was told to
-- pay -- and in the case worth catching, is what they did pay.
-- =====================================================================

create or replace function public.pos_voided_bills(
  p_org  uuid,
  p_from date default (now() at time zone 'Asia/Kuala_Lumpur')::date,
  p_to   date default (now() at time zone 'Asia/Kuala_Lumpur')::date)
returns table (
  sale_id      uuid,
  sale_no      text,
  outlet_name  text,
  register_name text,
  table_code   text,
  total_amount numeric,
  line_count   integer,
  -- How many of those the kitchen had already cooked. The difference
  -- between this and line_count is the difference between food lost
  -- and an order that never existed, and a manager reads them
  -- differently.
  cooked_count integer,
  reason       text,
  note         text,
  voided_by    uuid,
  voided_name  text,
  voided_at    timestamptz)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select s.id,
         s.sale_no,
         o.name,
         r.name,
         t.code,
         s.total_amount,
         (select count(*)::integer from public.pos_sale_lines l
           where l.sale_id = s.id),
         (select count(*)::integer from public.pos_sale_lines l
           where l.sale_id = s.id and l.sent_to_kitchen_at is not null),
         s.void_reason,
         s.void_note,
         s.voided_by,
         -- The name rather than the id, because "who" is the question
         -- and a uuid is not an answer anybody can act on.
         p.full_name,
         s.voided_at
    from public.pos_sales s
    join public.pos_outlets o on o.id = s.outlet_id
    join public.pos_registers r on r.id = s.register_id
    left join public.pos_tables t on t.id = s.table_id
    left join public.profiles p on p.id = s.voided_by
   where s.org_id = p_org
     and s.status = 'voided'
     -- The shop's day, not UTC's: a bill written off at eleven at night
     -- belongs to the night it happened on.
     and (s.voided_at at time zone 'Asia/Kuala_Lumpur')::date
         between p_from and p_to
     and app.can_read_module(p_org, 'pos')
   order by s.voided_at desc;
$$;

grant execute on function public.pos_voided_bills(uuid, date, date) to authenticated;

comment on function public.pos_voided_bills(uuid, date, date) is
  'The bills written off in a period: what each came to, why, and who. Listed rather than grouped -- there are few of them and each is a whole order, so which one and whose it was is the answer being looked for.';
