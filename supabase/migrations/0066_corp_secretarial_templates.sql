-- =====================================================================
-- iAkauntan :: 0066 the documents a secretarial firm raises weekly
--
-- Shipped with org_id null, so every firm gets them; a firm that wants
-- its own wording copies the row against its own org_id and that
-- version wins.
-- =====================================================================

insert into public.corp_templates (org_id, code, name, category, applies_to, body)
values
(null, 'board_res_appoint_director', 'Board resolution — appointment of director',
 'Directors', array['sdn_bhd','berhad','clbg']::app.corp_entity_type[],
$T$**{{company_name}}**
(Registration No. {{registration_no}})
(Incorporated in Malaysia)

**DIRECTORS' RESOLUTION IN WRITING**
passed pursuant to the Constitution of the Company and section 297 of the
Companies Act 2016

**APPOINTMENT OF DIRECTOR**

IT WAS RESOLVED THAT {{director_name}} (NRIC/Passport No. {{director_id}})
of {{director_address}} be and is hereby appointed as a Director of the
Company with effect from {{appointment_date}}, the Company having received
his/her consent to act under section 201 of the Companies Act 2016 and a
declaration that he/she is not disqualified under section 198.

IT WAS FURTHER RESOLVED THAT the Company Secretary be and is hereby
authorised to lodge the notification of change in the register of
directors with the Registrar of Companies within fourteen (14) days as
required by section 58 of the Companies Act 2016.

Dated this {{today}}

Signed by the Directors:

{{directors}}
$T$),

(null, 'board_res_change_address', 'Board resolution — change of registered office',
 'Registered office', array['sdn_bhd','berhad','clbg']::app.corp_entity_type[],
$T$**{{company_name}}**
(Registration No. {{registration_no}})

**DIRECTORS' RESOLUTION IN WRITING**

**CHANGE OF REGISTERED OFFICE**

IT WAS RESOLVED THAT the registered office of the Company be changed from
{{registered_office}} to {{new_address}} with effect from
{{effective_date}}.

IT WAS FURTHER RESOLVED THAT the Company Secretary be authorised to lodge
the notification with the Registrar within fourteen (14) days pursuant to
section 46(3) of the Companies Act 2016.

Dated this {{today}}

{{directors}}
$T$),

(null, 'board_res_allotment', 'Board resolution — allotment of shares',
 'Share capital', array['sdn_bhd','berhad','clbg']::app.corp_entity_type[],
$T$**{{company_name}}**
(Registration No. {{registration_no}})

**DIRECTORS' RESOLUTION IN WRITING**

**ALLOTMENT AND ISSUE OF SHARES**

IT WAS RESOLVED THAT, the Company having obtained the prior approval of
its members by resolution under section 75 of the Companies Act 2016,
{{allotment_quantity}} {{share_class}} shares be allotted and issued to
{{allottee_name}} (NRIC/Registration No. {{allottee_id}}) at
RM{{price_per_share}} per share for a total consideration of
RM{{total_consideration}}, credited as fully paid.

IT WAS FURTHER RESOLVED THAT the share certificate be issued under the
authority of the Company and that the Company Secretary lodge the return
of allotment with the Registrar within fourteen (14) days pursuant to
section 78 of the Companies Act 2016.

Issued share capital following this allotment:
{{issued_capital}}

Dated this {{today}}

{{directors}}
$T$),

(null, 'members_res_special_name', 'Special resolution — change of company name',
 'Company', array['sdn_bhd','berhad','clbg']::app.corp_entity_type[],
$T$**{{company_name}}**
(Registration No. {{registration_no}})

**SPECIAL RESOLUTION**
passed by the members pursuant to section 292 of the Companies Act 2016

**CHANGE OF NAME**

IT WAS RESOLVED AS A SPECIAL RESOLUTION THAT the name of the Company be
changed from {{company_name}} to {{new_name}} with effect from the date of
the notice of registration issued by the Registrar.

IT WAS FURTHER RESOLVED THAT the Company Secretary lodge this resolution
with the Registrar pursuant to section 28 of the Companies Act 2016.

Dated this {{today}}

Members voting in favour:
{{members}}
$T$),

(null, 'sec_particulars', 'Statutory particulars — company profile',
 'Company', null,
$T$**{{company_name}}**

| | |
| --- | --- |
| Registration number | {{registration_no}} |
| Former number | {{old_registration_no}} |
| Type | {{entity_type}} |
| Incorporated | {{incorporated_on}} |
| Registered office | {{registered_office}} |
| Business address | {{business_address}} |
| Nature of business | {{nature_of_business}} |
| Financial year end | {{financial_year_end}} |

**Directors**
{{directors}}

**Company Secretary**
{{secretaries}}

**Members**
{{members}}

**Issued share capital**
{{issued_capital}}

Extracted from the statutory registers on {{today}}.
$T$),

(null, 'first_board_minutes', 'Minutes — first meeting of the board',
 'Company', array['sdn_bhd','berhad','clbg']::app.corp_entity_type[],
$T$**{{company_name}}**
(Registration No. {{registration_no}})

**MINUTES OF THE FIRST MEETING OF THE BOARD OF DIRECTORS**
held at {{meeting_venue}} on {{meeting_date}} at {{meeting_time}}

PRESENT: {{directors}}

1. **INCORPORATION.** The notice of registration dated {{incorporated_on}}
   issued by the Registrar of Companies was tabled and noted.

2. **REGISTERED OFFICE.** RESOLVED that the registered office of the
   Company be at {{registered_office}}.

3. **COMPANY SECRETARY.** RESOLVED that {{secretary_name}} be appointed
   Company Secretary with effect from {{incorporated_on}}, the appointment
   being within thirty (30) days of incorporation as required by section
   236(1) of the Companies Act 2016.

4. **FINANCIAL YEAR END.** RESOLVED that the first financial year of the
   Company end on {{financial_year_end}}.

5. **BANK ACCOUNT.** RESOLVED that a bank account be opened with
   {{bank_name}} and that the signatories be as agreed.

6. **STATUTORY REGISTERS.** RESOLVED that the registers required by the
   Companies Act 2016 be kept at the registered office.

There being no further business the meeting closed.

Chairman: {{chairman_name}}
$T$)
on conflict (code) where org_id is null
do update set name = excluded.name, body = excluded.body,
              category = excluded.category, applies_to = excluded.applies_to;
