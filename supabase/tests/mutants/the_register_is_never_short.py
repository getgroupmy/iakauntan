# Mutants for 0833 -- app.corp_check_share_event refuses a class of
# shares from another company, and a movement that leaves the holder
# short on its own date or on any later date the holder's shares moved;
# a holder's movement to themselves moves nothing.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0833_the_register_is_never_short.sql \
#       supabase/tests/share_register_kept.sql \
#       supabase/tests/mutants/the_register_is_never_short.py
#
# RESULT, 12 October: 15 of 15 killed by share_register_kept.sql, the
# control surviving. Not swept, because nothing in the file can tell:
# the `e.id is distinct from NEW.id` filters (a movement is checked
# before it is inserted, and only the owner can now update one), and
# the entity filter beside the class filter (a class belongs to one
# company, which the first check now insists on).
#
# The revoked update and delete were restored by hand: the grants with
# `0067`'s policy, and the grants alone, fail the file at "a movement is
# not edited"; the policy alone fails "and no policy lets one"; a no-op
# control passes.

m("another company's class of shares is taken",
  'corp_check_share_event',
  '  if not exists (select 1 from public.corp_share_classes c\n                  where c.id = NEW.share_class_id\n                    and c.entity_id = NEW.entity_id) then',
  '  if false then  -- any class',
  '-- any class')

m('the class is asked of the tenant, not the company',
  'corp_check_share_event',
  '                    and c.entity_id = NEW.entity_id) then',
  '                    and c.org_id = NEW.org_id) then  -- same tenant',
  '-- same tenant')

m('the class is asked only of a movement out',
  'corp_check_share_event',
  "  -- 0833. A movement is in the company's own shares.\n  if not exists (select 1 from public.corp_share_classes c\n                  where c.id = NEW.share_class_id\n                    and c.entity_id = NEW.entity_id) then\n    raise exception\n      'That class of shares is another company''s. A movement is in '\n      'the shares of the company whose register it is on.'\n      using errcode = '23514';\n  end if;\n\n  if NEW.from_person_id is null then return NEW; end if;\n",
  "  if NEW.from_person_id is null then return NEW; end if;  -- out only\n\n  if not exists (select 1 from public.corp_share_classes c\n                  where c.id = NEW.share_class_id\n                    and c.entity_id = NEW.entity_id) then\n    raise exception\n      'That class of shares is another company''s. A movement is in '\n      'the shares of the company whose register it is on.'\n      using errcode = '23514';\n  end if;\n",
  '-- out only')

m('a movement to oneself counts as shares gained, on its own day',
  'corp_check_share_event',
  '  select coalesce(sum(\n           (case when e.to_person_id = NEW.from_person_id\n                 then e.quantity else 0 end)\n         - (case when e.from_person_id = NEW.from_person_id\n                 then e.quantity else 0 end)), 0)',
  '  select coalesce(sum(case when e.to_person_id = NEW.from_person_id\n                           then e.quantity else -e.quantity end), 0)  -- old sum',
  '-- old sum')

m('every class counts on its own day',
  'corp_check_share_event',
  '\n     and e.share_class_id = NEW.share_class_id\n',
  '\n     and true  -- every class today\n',
  '-- every class today')

m('the same day is not counted with it',
  'corp_check_share_event',
  '     and e.event_date <= NEW.event_date',
  '     and e.event_date < NEW.event_date  -- day before',
  '-- day before')

m('its own day is never asked',
  'corp_check_share_event',
  '  if v_held < NEW.quantity then',
  '  if false then  -- no own day',
  '-- no own day')

m('a later day is never asked',
  'corp_check_share_event',
  '  if v_short.d is not null then',
  '  if false then  -- no later day',
  '-- no later day')

m('a movement to oneself counts as shares gained, later',
  'corp_check_share_event',
  '                         (case when e.to_person_id = NEW.from_person_id\n                               then e.quantity else 0 end)\n                       - (case when e.from_person_id = NEW.from_person_id\n                               then e.quantity else 0 end) as delta',
  '                         (case when e.to_person_id = NEW.from_person_id\n                               then e.quantity else -e.quantity end) as delta  -- old delta',
  '-- old delta')

m('every class counts later',
  'corp_check_share_event',
  '\n                     and e.share_class_id = NEW.share_class_id\n',
  '\n                     and true  -- every class later\n',
  '-- every class later')

m('the movement asked about is not in the holding it is asked against',
  'corp_check_share_event',
  '                  union all\n                  select NEW.event_date, -NEW.quantity) x) m',
  '                  ) x) m  -- without this one',
  '-- without this one')

m('the holding is the total, not day by day',
  'corp_check_share_event',
  'sum(x.delta) over (order by x.d) as held',
  'sum(x.delta) over () as held  -- the total',
  '-- the total')

m('holding none is short',
  'corp_check_share_event',
  '     and m.held < 0',
  '     and m.held <= 0  -- none is short',
  '-- none is short')

m('the last short day is named, not the first',
  'corp_check_share_event',
  '   order by m.d\n   limit 1;',
  '   order by m.d desc  -- the last\n   limit 1;',
  '-- the last')

m('the shortfall is told as the holding',
  'corp_check_share_event',
  '      NEW.quantity, NEW.event_date, -v_short.held, v_short.d\n',
  '      NEW.quantity, NEW.event_date, v_short.held, v_short.d  -- signed\n',
  '-- signed')

m('CONTROL: a comment inside corp_check_share_event',
  'corp_check_share_event',
  '  return NEW;\nend;\n$$;',
  '  return NEW;  -- (control)\nend;\n$$;',
  '(control)')
