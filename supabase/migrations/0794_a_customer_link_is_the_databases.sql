-- =====================================================================
-- iAkauntan :: 0794 a customer link is the database's
--
-- `0793` closed the invoice share links. Three more tables hold the same
-- kind of row -- a hashed token sent to a customer, its expiry, a record
-- of every opening, and a revocation -- under the same kind of policy,
-- an UPDATE of every column for any member who may write:
--
--   * `customer_portal_links` -- a customer's whole account: every
--     invoice, what is outstanding;
--   * `tax_detail_requests` -- the form a customer fills in with their
--     tax details, and the record of when they submitted it;
--   * `ticket_share_links` -- a support ticket shared with a customer,
--     and the replies they sent through it.
--
-- Each is issued, opened, used and revoked only by SECURITY DEFINER
-- functions; the app only reads them. Measured on 10 October 2026,
-- locally, as a member with the accountant's role, on the portal: a link
-- revoked was revived, given fifty years, and pointed at ANOTHER
-- customer -- and its holder opened that customer's account. The other
-- two have the same columns and the same policy.
--
-- Answered "guard all three". One guard, on all three tables: a client's
-- own statement -- role `authenticated` or `anon`, at the top trigger
-- depth -- may change only two things, the address a link was sent to,
-- and a live link's revocation. Everything else on the row is the
-- database's: whom or what it points at, the token, the expiry, the
-- record of openings, submissions and replies, the author, the issue
-- time; and a revoked link stays revoked. Asked of every column but
-- those two rather than of a list, so a column added later is guarded
-- until somebody decides otherwise. Clients hold no INSERT or DELETE on
-- these tables. NOT security definer itself.
--
-- Production held none of the three on 10 October.
-- =====================================================================

create or replace function app.customer_link_is_the_databases()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_col  text;
  v_old  jsonb;
  v_new  jsonb;
begin
  -- NOT security definer: a definer would always answer "the owner".
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return new;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  for v_col in select k from jsonb_object_keys(v_new) k order by k loop
    continue when v_col in ('sent_to_email', 'revoked_at');
    if (v_new -> v_col) is distinct from (v_old -> v_col) then
      raise exception
        'The % of a link sent to a customer is the database''s to write, '
        'not a client''s.', replace(v_col, '_', ' ')
        using errcode = '42501';
    end if;
  end loop;

  -- Revoking a live link by hand is the company's to do; bringing one
  -- back, or re-dating its revocation, is not.
  if old.revoked_at is not null
     and new.revoked_at is distinct from old.revoked_at then
    raise exception
      'A revoked link stays revoked. Send a new one.'
      using errcode = '42501';
  end if;

  return new;
end $$;

revoke all on function app.customer_link_is_the_databases() from public, anon, authenticated;

comment on function app.customer_link_is_the_databases() is
  'On the customer portal, tax detail and ticket share links: refuses a '
  'client''s own statement that changes anything but the address a link '
  'was sent to and a live link''s revocation, or that brings a revoked '
  'link back. The functions that issue, open, use and revoke them run as '
  'their owner and pass. 0794.';

create trigger customer_link_is_the_databases
  before update on public.customer_portal_links
  for each row execute function app.customer_link_is_the_databases();

create trigger customer_link_is_the_databases
  before update on public.tax_detail_requests
  for each row execute function app.customer_link_is_the_databases();

create trigger customer_link_is_the_databases
  before update on public.ticket_share_links
  for each row execute function app.customer_link_is_the_databases();
