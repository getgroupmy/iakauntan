-- =====================================================================
-- iAkauntan :: 0843 an order's components are its functions'
--
-- A manufacturing order's components say what it takes and what it
-- took. `confirm_manufacturing_order` writes them from the bill of
-- materials, the quantities scaled to the order; `post_manufacturing_
-- order` issues each one from stock and records on it the quantity
-- issued and what that cost, from the movement it made. Both are
-- definers. The order screen reads the components; nothing in the app
-- writes one. But `mo_components_write` let anybody who can post, with
-- write on manufacturing, insert, update or delete any of them.
--
-- Measured on 12 October 2026, locally, as the owner with the role
-- `authenticated`. On a posted order whose movement issued 20 kg of
-- flour at RM40.00: its component rewritten to 2 kg at RM4.00 was
-- accepted, the movement still saying 20 kg; the component deleted was
-- accepted; a component added to the posted order was accepted. On a
-- confirmed order, the flour cut from 20 kg to 1 kg before posting was
-- accepted, and posting issued 1 kg and costed each loaf at RM0.20
-- rather than RM4.00 -- the bill of materials still saying 20.
--
-- Answered "revoke client writes": insert, update and delete are
-- revoked from `authenticated` and `anon` and `mo_components_write`
-- dropped, with the module gates for writing, which would have nothing
-- left to narrow. Components are what confirming snapshots and posting
-- records, as the app already has them; reading is as before.
--
-- Production held three orders, two of them posted, and twelve
-- components on 12 October, all in demonstration companies; no posted
-- component disagreed with its movement.
-- =====================================================================

revoke insert, update, delete on public.mo_components from authenticated, anon;
drop policy if exists mo_components_write on public.mo_components;
drop policy if exists module_gate_insert on public.mo_components;
drop policy if exists module_gate_update on public.mo_components;
drop policy if exists module_gate_delete on public.mo_components;
