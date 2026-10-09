# Mutants for app.request_header (0047, restated in 0785) -- one header
# of the current request, null outside one or when the setting is not
# JSON; asked for x-forwarded-for, the CALLER'S ADDRESS: the edge's
# cf-connecting-ip if it is an address, else the first X-Forwarded-For
# hop that is one, else null, bare and trimmed; never an error.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0785_the_address_on_the_record_is_the_callers.sql \
#       supabase/tests/client_address.sql \
#       supabase/tests/mutants/request_header.py
#
# RESULT: 10 mutants and a control, all killed by `client_address.sql`,
# new with `0785`. No test before it had ever set a request header, so
# the function had never been asked anything; `secretarial.sql` even
# asserted that a link signature recorded NO address, which was only
# true because nothing sent one. It now asserts the address the edge
# saw, and fails on `0047`'s version of the function, as
# `client_address.sql` does.

F = "request_header"

m("the header is answered as sent (as before 0785)", F,
  "  if p_name is distinct from 'x-forwarded-for' then",
  "  if true then  -- every header as sent",
  "-- every header as sent")

m("the edge's address is not asked", F,
  "      array[v_headers ->> 'cf-connecting-ip']",
  "      array[null::text]  -- no edge",
  "-- no edge")

m("the client's hops come before the edge's", F,
  "      array[v_headers ->> 'cf-connecting-ip']\n      || string_to_array(coalesce(v_headers ->> 'x-forwarded-for', ''), ',')",
  "      string_to_array(coalesce(v_headers ->> 'x-forwarded-for', ''), ',')  -- client first\n      || array[v_headers ->> 'cf-connecting-ip']",
  "-- client first")

m("only the edge is asked", F,
  "      || string_to_array(coalesce(v_headers ->> 'x-forwarded-for', ''), ',')",
  "      || array[]::text[]  -- edge only",
  "-- edge only")

m("hops are not trimmed", F,
  "    v_hop := btrim(coalesce(v_hop, ''));",
  "    v_hop := coalesce(v_hop, '');  -- untrimmed",
  "-- untrimmed")

m("the address keeps its mask", F,
  "      return host(v_hop::inet);",
  "      return v_hop::inet::text;  -- with mask",
  "-- with mask")

m("an unreadable hop ends the search", F,
  "    exception when invalid_text_representation then\n      -- Not an address ('unknown', a host name, a port glued on): the\n      -- next one is asked.\n      null;",
  "    exception when invalid_text_representation then\n      return null;  -- gives up",
  "-- gives up")

m("an unreadable hop is answered as it is", F,
  "      return host(v_hop::inet);",
  "      return v_hop;  -- unchecked",
  "-- unchecked")

m("a setting that is not JSON is an error", F,
  "  exception when others then\n    return null;\n  end;",
  "  exception when division_by_zero then  -- not json raises\n    return null;\n  end;",
  "-- not json raises")

m("an empty header is answered as empty", F,
  "    return nullif(v_headers ->> p_name, '');",
  "    return v_headers ->> p_name;  -- empty kept",
  "-- empty kept")

m("CONTROL: a comment inside the block", F,
  "    continue when v_hop = '';",
  "    continue when v_hop = '';  -- (control)",
  "(control)")
