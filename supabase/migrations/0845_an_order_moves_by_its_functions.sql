-- =====================================================================
-- iAkauntan :: 0845 an order moves by its functions
--
-- A manufacturing order is a draft until `confirm_manufacturing_order`
-- copies the recipe onto it and makes it confirmed, and confirmed until
-- `post_manufacturing_order` issues the parts, receives the goods,
-- writes the journal and makes it done. Both are definers. The screen's
-- one direct write is cancelling an order not yet started. `0837` kept
-- the posting columns to the posting function; the status beside them
-- stayed open to anybody who can post.
--
-- Measured on 12 October 2026, locally, as the owner with the role
-- `authenticated`: a posted order marked cancelled was accepted, its
-- journal and both stock movements standing behind an order that says
-- it never happened; a confirmed order marked done was accepted with
-- nothing issued and no journal -- and `post_manufacturing_order` then
-- refused it for good, "Only a confirmed order can be posted; this one
-- is done"; a posted order put back to draft was accepted.
--
-- Answered "guard the status": a trigger refuses a client's own
-- statement -- role `authenticated` or `anon`, at the top trigger
-- depth -- that moves an order's status anywhere but to cancelled, or
-- cancels one that is posted, and one that makes an order other than
-- as a draft. Confirming and posting are definers and pass. NOT
-- security definer: a definer would always answer "the owner".
--
-- Production held three orders on 12 October -- two done and posted,
-- one confirmed -- every one consistent, in demonstration companies.
-- =====================================================================

create or replace function app.an_order_moves_by_its_functions()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'draft' then
      raise exception
        'Manufacturing order % starts as a draft. It is confirmed by '
        'confirming it and done by posting it.',
        new.order_no
        using errcode = '42501';
    end if;
    return new;
  end if;

  if new.status is distinct from old.status then
    if new.status <> 'cancelled' then
      raise exception
        'Manufacturing order % is confirmed by confirming it and done by '
        'posting it. By hand it may only be cancelled.',
        old.order_no
        using errcode = '42501';
    end if;
    if old.gl_entry_id is not null then
      raise exception
        'Manufacturing order % is posted, and its journal and the stock it '
        'moved stand on it. It is not cancelled.',
        old.order_no
        using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

revoke all on function app.an_order_moves_by_its_functions()
  from public, anon, authenticated;

comment on function app.an_order_moves_by_its_functions() is
  'On manufacturing_orders: refuses a client''s own statement that moves '
  'an order''s status anywhere but to cancelled, cancels a posted order, '
  'or makes one other than as a draft. confirm_manufacturing_order and '
  'post_manufacturing_order pass. 0845.';

create trigger an_order_moves_by_its_functions
  before insert or update on public.manufacturing_orders
  for each row execute function app.an_order_moves_by_its_functions();
