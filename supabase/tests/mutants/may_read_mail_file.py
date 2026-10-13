# Mutants for 0853 -- app.may_read_mail_file lets a file in the mail
# bucket be read only by somebody who may read the mailbox its email
# came to, in the company the path names.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0853_an_attachment_as_private_as_its_letter.sql \
#       supabase/tests/mail_files_private.sql \
#       supabase/tests/mutants/may_read_mail_file.py
#
# RESULT: 4 of 4 killed, the control surviving.
#
# The policy that calls it is not a function and has no mutant here. It
# was swept by hand: `0405`'s policy restored -- membership and the
# module only -- "the owner does not read the file on the clerk's
# personal mail" fails; with 0853's, the file passes.

m('any email of the company will do',
  'may_read_mail_file',
  '                  where e.id = p_email\n',
  '                  where true  -- any email\n',
  '-- any email')

m('an email of any company will do',
  'may_read_mail_file',
  '                    and e.org_id = p_org\n',
  '                    and true  -- any company\n',
  '-- any company')

m('every mailbox is readable',
  'may_read_mail_file',
  '                    and app.may_read_mailbox(e.mailbox_id));',
  '                    and true);  -- every mailbox',
  '-- every mailbox')

m('no file is readable',
  'may_read_mail_file',
  '  select exists (select 1 from public.inbound_emails e',
  '  select false and exists (select 1 from public.inbound_emails e  -- none',
  '-- none')

m('CONTROL: a comment inside may_read_mail_file',
  'may_read_mail_file',
  '                    and e.org_id = p_org\n',
  '                    and e.org_id = p_org  -- (control)\n',
  '(control)')
