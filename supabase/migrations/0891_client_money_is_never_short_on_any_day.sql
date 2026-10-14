-- =====================================================================
-- iAkauntan :: 0891 client money is never short on any day
--
-- `app.assert_client_funds` -- the deferred constraint trigger every
-- client-money write passes -- added up a matter's whole client ledger
-- and refused a total below nought. It never asked WHEN. So a payment
-- out could be dated before the money it spent had arrived: the total
-- came right once the receipt landed, and for every day in between the
-- matter's client ledger stood in debit, which is another client's
-- money paying for it.
--
-- Measured on 14 October 2026, locally, as an accountant with the role
-- `authenticated`: 1,000 received on a matter today, then 600 paid out
-- of it dated ten days ago through `pay_from_client_account` -- the
-- function behind the payment screen, whose date picker offers any
-- day. It posted, and the matter's client ledger read -600 for those
-- ten days. Transfers between matters and to office write the same
-- table and passed the same way.
--
-- Production on 14 October: four client-money transactions on two
-- matters, neither ever short on any day.
--
-- Answered "never short on any day". The check now reads the matter's
-- balance day by day -- each day's movements summed, then carried
-- forward -- and refuses the first day it is below nought, naming the
-- day and the shortfall. One day's movements are summed before the
-- balance is read, so a payment and the receipt funding it on the same
-- day pass in either order, as they did. A void or delete that leaves
-- an earlier payment unfunded is refused the same way, which the total
-- let through whenever a later receipt made up the sum.
--
-- A row moved from one matter to another is now checked against both:
-- the one it left as well as the one it joined. Nothing in the app
-- moves one (clients hold SELECT only, and the one definer that updates
-- the table only posts), so this is the same check made whole rather
-- than a new rule.
-- =====================================================================

create or replace function app.assert_client_funds()
returns trigger
language plpgsql
set search_path to 'public', 'pg_temp'
as $$
declare
  v_matter    uuid;
  v_day       date;
  v_running   numeric(18, 2);
  v_matter_no text;
begin
  for v_matter in
    select distinct m
      from unnest(array[new.matter_id, old.matter_id]) as m
     where m is not null
  loop
    -- The first day the matter's client ledger closes in debit, if any.
    select d.transaction_date, d.running into v_day, v_running
      from (select t.transaction_date,
                   sum(sum(t.amount)) over (order by t.transaction_date)
                     as running
              from public.client_account_transactions t
             where t.matter_id = v_matter
               and t.status <> 'void'
             group by t.transaction_date) d
     where d.running < 0
     order by d.transaction_date
     limit 1;

    if found then
      select matter_no into v_matter_no from public.matters where id = v_matter;
      raise exception
        'Client account for matter % would be overdrawn by % on %. Client '
        'money held for one matter cannot fund another, and money that had '
        'not arrived yet cannot fund it either.',
        v_matter_no, to_char(-v_running, 'FM999999990.00'), v_day
        using errcode = '23514';
    end if;
  end loop;

  return coalesce(new, old);
end;
$$;

comment on function app.assert_client_funds() is
  'Deferred constraint trigger on client_account_transactions: no '
  'matter''s client ledger may close any day in debit, read day by day '
  'with each day''s movements summed first. Checks the matter a row '
  'joins and the one it leaves. 0891.';
