-- =====================================================================
-- A menu link is reached by a token, and every link has one
--
-- `app.pos_menu_link(p_token)` is the front door of the only POS
-- surface granted to `anon`: a token typed into a phone is the whole
-- credential, and the lookup is
--
--     where token = coalesce(p_token, '')
--
-- The `coalesce` is what stops a caller who sends NO token from being
-- treated as a caller whose token happens to be null. It works, and a
-- sweep proved it cannot be told apart from `token is not distinct from
-- p_token` — because no row has a null token: the column defaults to
-- eighteen random bytes and `upsert_pos_menu_link` never names it.
--
-- But `pos_menu_links.token` was nullable, and its unique index is no
-- help there — a unique index permits as many nulls as you like. A row
-- reaching that state by any route at all, a restore or a hand-typed
-- insert among them, would be a link that `place_public_pos_order(null,
-- ...)` opens: a shop's till, reachable by an anonymous caller who
-- sends nothing.
--
-- Nothing writes such a row today. This holds the column to what every
-- row already is, so that stays true.
-- =====================================================================

alter table public.pos_menu_links
  alter column token set not null;

comment on column public.pos_menu_links.token is
  'The whole credential for the public menu endpoints. Not null: a link '
  'with no token would be reachable by a caller who sends no token.';
