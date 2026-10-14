-- =====================================================================
-- iAkauntan :: 0892 a cheque comes back after it came in
--
-- `bounce_pdc` took any date. A post-dated cheque could be marked
-- bounced before the day it was received, and a deposited one before
-- the day it was paid in -- and where the cheque settles an invoice,
-- its "returned" journal then comes before the receipt journal it
-- undoes, which `0888` refuses for a journal reversed by hand.
--
-- Measured on 14 October 2026, locally, as an accountant with the role
-- `authenticated`: a cheque received five days ago marked bounced
-- twenty days ago, and one paid in today marked bounced ten days ago.
-- Both stored. The cheque list's "Bounced" sends no date, so it is
-- today and this is reachable only by naming one through the API.
--
-- Production held no post-dated cheque on 14 October.
--
-- Answered "not before received or paid in":
--
--   * a bounce dated before the cheque was received (or, for one the
--     company wrote, issued) is refused;
--   * and for a cheque already paid in, one dated before that day.
--
-- Before the cheque's own date stays open, as `0886` left it: a cheque
-- presented early comes back for exactly that reason, and one still
-- held can be stopped any day after it was received.
--
-- The body is `pg_get_functiondef` of what was applied, with the block
-- marked 0892 added.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.bounce_pdc(p_id uuid, p_reason text, p_on date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_c     public.post_dated_cheques;
  v_held  uuid;
  v_ctrl  uuid;
  v_lines jsonb;
  v_entry uuid;
  v_on    date;
begin
  select * into v_c from public.post_dated_cheques where id = p_id;
  if v_c.id is null then
    raise exception 'No such cheque.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_c.org_id,
        case when v_c.direction = 'incoming' then 'sales' else 'purchases' end) then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if not app.can_post(v_c.org_id) then
    raise exception
      'A bounced cheque posts to the ledger, which only somebody who may post '
      'does: an accountant, an admin or the owner.'
      using errcode = '42501';
  end if;
  if v_c.status not in ('held', 'deposited') then
    raise exception 'That cheque is %.', v_c.status using errcode = '23514';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception
      'Say why. "Bounced" is not something anybody can act on, and the '
      'reason decides whether it is re-presented or chased.'
      using errcode = '23514';
  end if;

  v_on   := coalesce(p_on, app.today());
  -- 0892: a cheque comes back no earlier than it was received or
  -- issued, and once paid in, no earlier than the day it was. Before
  -- its own date is still allowed: presented early is a reason to
  -- come back.
  if v_on < v_c.received_on then
    raise exception
      'Cheque % was % on %, and cannot have come back before it was.',
      v_c.cheque_no,
      case when v_c.direction = 'incoming' then 'received' else 'issued' end,
      to_char(v_c.received_on, 'DD Mon YYYY') using errcode = '23514';
  end if;
  if v_on < v_c.deposited_on then
    raise exception
      'Cheque % was paid in on %, and cannot have come back before it was.',
      v_c.cheque_no, to_char(v_c.deposited_on, 'DD Mon YYYY')
      using errcode = '23514';
  end if;
  v_held := app.cheque_account(v_c.org_id, v_c.direction::text);

  if v_c.gl_entry_id is not null then
    if v_c.direction = 'incoming' then
      select coalesce(c.receivable_account_id,
                      (select a.id from public.accounts a
                        where a.org_id = v_c.org_id and a.code = '1210'))
        into v_ctrl from public.contacts c where c.id = v_c.contact_id;
      -- He owes it again.
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', v_ctrl, 'contact_id', v_c.contact_id,
          'description', 'Cheque ' || v_c.cheque_no || ' returned',
          'debit', v_c.amount, 'credit', 0),
        jsonb_build_object('account_id', v_held, 'contact_id', v_c.contact_id,
          'description', 'Cheque ' || v_c.cheque_no || ' returned',
          'debit', 0, 'credit', v_c.amount));
    else
      select coalesce(c.payable_account_id,
                      (select a.id from public.accounts a
                        where a.org_id = v_c.org_id and a.code = '2110'))
        into v_ctrl from public.contacts c where c.id = v_c.contact_id;
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', v_held, 'contact_id', v_c.contact_id,
          'description', 'Cheque ' || v_c.cheque_no || ' stopped',
          'debit', v_c.amount, 'credit', 0),
        jsonb_build_object('account_id', v_ctrl, 'contact_id', v_c.contact_id,
          'description', 'Cheque ' || v_c.cheque_no || ' stopped',
          'debit', 0, 'credit', v_c.amount));
    end if;

    v_entry := app.create_gl_entry_internal(
      v_c.org_id, v_on, 'cheque', v_lines,
      'Cheque ' || v_c.pdc_no || ' returned', 'post_dated_cheques', p_id);
  end if;

  delete from public.payment_allocations where pdc_id = p_id;

  update public.post_dated_cheques
     set status = 'bounced', bounced_on = v_on,
         bounce_reason = trim(p_reason), bounce_entry_id = v_entry
   where id = p_id;
  return v_entry;
end;
$function$;
