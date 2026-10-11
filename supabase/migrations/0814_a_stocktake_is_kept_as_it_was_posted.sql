-- =====================================================================
-- iAkauntan :: 0814 a stocktake is kept as it was posted
--
-- The app drafts a stock adjustment -- a stocktake, a write-off -- and
-- its lines, and `post_stock_adjustment` posts it: the stock movements,
-- the journal, the adjustment marked posted. `refuse_reposting` stops a
-- second posting. Nothing else kept the posted record: the insert,
-- update and delete policies on both tables ask only `can_write` and the
-- inventory module, whatever the adjustment's state.
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: a stocktake posted two units short, RM20 written
-- off. Its line rewritten to "counted 50, difference 0", and then the
-- adjustment deleted. The movement and the journal it made stayed, with
-- nothing left to say why. `0238` refuses deleting a posted invoice or
-- bill for this reason, and `0802` discarding one.
--
-- Answered "freeze once posted". A trigger refuses a client's own
-- statement -- role `authenticated` or `anon`, at the top trigger depth
-- -- that changes or deletes an adjustment past draft, or inserts,
-- changes or deletes a line under one; that creates an adjustment
-- other than as a draft; or that marks a draft posted without posting
-- it. A draft is as editable as before, and deleting one takes its lines
-- with it. The functions run as their owner and pass. NOT security
-- definer itself. A wrong stocktake is corrected by posting another.
--
-- Production held no stock adjustment on 11 October.
-- =====================================================================

create or replace function app.a_posted_adjustment_is_kept()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_adj public.stock_adjustments;
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return coalesce(new, old);
  end if;

  if tg_table_name = 'stock_adjustments' then
    if tg_op = 'INSERT' then
      if new.status <> 'draft' or new.gl_entry_id is not null
         or new.posted_at is not null then
        raise exception
          'A stock adjustment is created as a draft (this one said %). It '
          'is posted by posting it, which moves the stock and writes the '
          'journal.', new.status
          using errcode = '42501';
      end if;
      return new;
    end if;

    if old.status <> 'draft' then
      raise exception
        '% is %, and a stock adjustment is kept as it was posted: the '
        'stock it moved and the journal it wrote stand on it. Post another '
        'adjustment to correct it.', old.adjustment_no, old.status
        using errcode = '42501';
    end if;

    if tg_op = 'UPDATE'
       and (new.status is distinct from old.status
            or new.gl_entry_id is distinct from old.gl_entry_id
            or new.posted_at is distinct from old.posted_at) then
      raise exception
        '% becomes posted by posting it, which moves the stock and writes '
        'the journal -- not by being marked so.', old.adjustment_no
        using errcode = '42501';
    end if;
    return coalesce(new, old);
  end if;

  -- A line: asked of the adjustment it was under and the one it goes to.
  for v_adj in
    select a.* from public.stock_adjustments a
     where a.id in (old.adjustment_id, new.adjustment_id)
       and a.status <> 'draft'
  loop
    raise exception
      '% is %, and its lines are kept as they were posted. Post another '
      'adjustment to correct it.', v_adj.adjustment_no, v_adj.status
      using errcode = '42501';
  end loop;

  return coalesce(new, old);
end $$;

revoke all on function app.a_posted_adjustment_is_kept() from public, anon, authenticated;

comment on function app.a_posted_adjustment_is_kept() is
  'On stock adjustments and their lines: refuses a client''s own statement '
  'that changes or deletes an adjustment past draft or a line under one, '
  'creates an adjustment other than as a draft, or marks a draft posted '
  'without posting it. 0814.';

create trigger a_posted_adjustment_is_kept
  before insert or update or delete on public.stock_adjustments
  for each row execute function app.a_posted_adjustment_is_kept();

create trigger a_posted_adjustment_is_kept
  before insert or update or delete on public.stock_adjustment_lines
  for each row execute function app.a_posted_adjustment_is_kept();
