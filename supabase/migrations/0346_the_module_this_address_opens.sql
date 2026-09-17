-- ---------------------------------------------------------------------
-- Whether the person signing in may open what this address opens
--
-- `0342` confines an address to a module. `0344` let the platform own
-- such an address outright. Neither asked the question the person at
-- the counter actually runs into: *this* address opens the till, and
-- the account being signed in has no till.
--
-- Until now the app answered that after the fact — it let them in, then
-- redirected to a whole screen saying no. That is the wrong shape twice
-- over. It is a screen where a sentence would do, and it leaves
-- somebody signed in to a product they cannot use, with the way back
-- being to find Sign out on a page that exists to tell them off.
--
-- So the question is asked at the door instead, and the answer is a
-- sentence on the sign-in form: `null` when there is nothing to refuse,
-- and the module's own name when there is, so the app can say which
-- one rather than "a module".
--
-- ## Which company
--
-- The address names a module, not a company, and somebody may belong to
-- several. So the question is whether *any* company they are in holds
-- it — the honest reading, because after signing in they will be in one
-- of them, and refusing somebody whose other company runs the till
-- would be refusing a fact about a company they were not signing in to.
--
-- ## Platform staff
--
-- Let through, like `may_use_workspace` lets them through any company's
-- door: an operator has to be able to open the address to see what the
-- shop sees. An operator with no company of their own would otherwise
-- be refused by every confined address there is, which is the same
-- mistake `0344` documented and worked around.
-- ---------------------------------------------------------------------

create or replace function public.workspace_module_refusal(p_host text)
returns text
language sql
stable
security definer
set search_path = public, app, pg_temp as $$
  select case
           -- Nothing to refuse: no such address, or one that opens the
           -- whole product.
           when s.module_code is null then null
           when app.is_platform_admin() then null
           when exists (
                  select 1
                    from public.org_members om
                   where om.user_id = auth.uid()
                     -- Active, like `app.is_org_member`. An invitation
                     -- nobody accepted is not a company you are in, and
                     -- letting one through here would open the till to
                     -- somebody who was asked and never answered.
                     and om.status = 'active'
                     and app.has_module(om.org_id, s.module_code))
             then null
           -- The module's own name, so the sentence can say "Point of
           -- Sale" rather than "pos". The code is the fallback for a
           -- module the catalogue has not named.
           else coalesce(m.name, s.module_code)
         end
    from (select 1) one
    left join public.org_subdomains s
           on s.status = 'approved'
          and s.subdomain = app.normalize_host_label(
                              split_part(coalesce(p_host, ''), '.', 1))
    left join public.platform_modules m on m.code = s.module_code;
$$;

-- Called by the sign-in screen with a session in hand, so authenticated
-- rather than anon: an answer to "may this account open this" has no
-- meaning before there is an account. `0165` strips grants from
-- anything created here, so this is not decoration.
revoke all on function public.workspace_module_refusal(text) from public;
grant execute on function public.workspace_module_refusal(text)
  to authenticated, service_role;

comment on function public.workspace_module_refusal is
  'Null when the signed-in account may open what this address is '
  'confined to, otherwise the name of the module it lacks.';
