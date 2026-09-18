"""What each screen shows.

The eight the store listing leads with are written out by hand. The other
eighty-nine are built from their route and their place in the catalogue —
a document screen gets documents, a people screen gets people — because
ninety-seven hand-written screens is ninety-seven chances for one of them
to say something about the product that is not so.
"""
import content as C
from ui import SUCCESS, WARNING, DANGER, INFO, INK, INK2, ACCENT

DOC_PREFIX = {
    'quotation': 'QUO', 'proforma': 'PRO', 'sales_order': 'SO', 'delivery_order': 'DO',
    'invoice': 'INV', 'credit_note': 'CN', 'debit_note': 'DN', 'refund_note': 'RN',
    'purchase_request': 'PR', 'purchase_order': 'PO', 'goods_received': 'GRN',
    'bill': 'BILL', 'purchase_credit_note': 'PCN', 'purchase_debit_note': 'PDN',
}

SALES_STATUS = [('Paid', 'success'), ('Sent', 'info'), ('Overdue', 'danger'),
                ('Draft', 'grey'), ('Part paid', 'warning'), ('Validated', 'success')]
PURCH_STATUS = [('Approved', 'success'), ('Awaiting', 'warning'), ('Received', 'info'),
                ('Draft', 'grey'), ('Paid', 'success')]


def _variance(v):
    """A variance tile whose word, sign and colour all say the same thing."""
    return ('Variance', C.money(abs(v)),
            'favourable' if v >= 0 else 'unfavourable',
            'success' if v >= 0 else 'danger')


def _docs(route, prefix, parties, statuses, n=9, lo=800, hi=48000):
    r = C.rng(route)
    rows = []
    for i in range(n):
        st, tone = statuses[r.randrange(len(statuses))]
        amt = r.uniform(lo, hi)
        rows.append(dict(
            title=f'{prefix}-2026-{r.randint(100, 899):03d}',
            sub=f'{parties[r.randrange(len(parties))]} · {C.date(r)}',
            amount=C.money(amt), status=st, tone=tone,
            amount_colour=DANGER if tone == 'danger' else INK,
            icon={'success': 'checkcircle', 'danger': 'warning',
                  'warning': 'clock', 'info': 'doc', 'grey': 'doc'}[tone]))
    return rows


def _people(route, subs, n=9, amounts=None, statuses=None):
    r = C.rng(route)
    rows = []
    for i in range(n):
        row = dict(title=C.PEOPLE[(i * 3 + r.randrange(3)) % len(C.PEOPLE)],
                   sub=subs[i % len(subs)])
        if amounts:
            row['amount'] = C.money(r.uniform(*amounts))
        if statuses:
            st, tone = statuses[r.randrange(len(statuses))]
            row['status'], row['tone'] = st, tone
        rows.append(row)
    return rows


def _orgs(route, subs, n=9, amounts=(1200, 60000), statuses=None):
    r = C.rng(route)
    rows = []
    for i in range(n):
        row = dict(title=C.ORGS[(i * 2 + 1) % len(C.ORGS)], sub=subs[i % len(subs)])
        if amounts:
            row['amount'] = C.money(r.uniform(*amounts))
        if statuses:
            st, tone = statuses[r.randrange(len(statuses))]
            row['status'], row['tone'] = st, tone
        rows.append(row)
    return rows


def _items(route, n=9):
    r = C.rng(route)
    rows = []
    for i, (name, code) in enumerate(C.ITEMS[:n]):
        qty = r.randint(-4, 480)
        rows.append(dict(title=name, sub=f'{code} · on hand {max(qty,0)}',
                         amount=C.money(r.uniform(3, 480)),
                         status='Reorder' if qty < 40 else 'In stock',
                         tone='warning' if qty < 40 else 'success', icon='box'))
    return rows


# --- the eight the listing leads with ---------------------------------------

def hero(route, spec):
    r = C.rng(route)
    if route == '/dashboard':
        spec.update(kind='dashboard', tabs=['Accounting', 'Sales', 'e-Invoice'],
                    actions=('refresh', 'bell'), search=None, fab=None, nav=0, rail=0)
    elif route == '/sales/invoice':
        spec.update(kind='doclist', tabs=['All', 'Unpaid', 'Overdue', 'Draft'],
                    search='Search invoices', chips=['This month', 'Unpaid', 'Overdue'],
                    fab='New invoice', nav=1, rail=1,
                    totals=[('Outstanding', 'RM 172,905', 'danger'),
                            ('Paid this month', 'RM 486,320', 'success'),
                            ('Overdue', 'RM 44,120', 'warning')],
                    rows=[
            dict(title='INV-2026-0418', sub='Kilang Serbaguna Sdn Bhd · 16 Sep 2026',
                 amount='RM 28,460.00', status='Validated', tone='success',
                 icon='checkcircle'),
            dict(title='INV-2026-0417', sub='Pantai Timur Logistics · 15 Sep 2026',
                 amount='RM 12,380.50', status='Sent', tone='info', icon='doc'),
            dict(title='INV-2026-0412', sub='Lim Heng Hardware · 9 Sep 2026',
                 amount='RM 6,940.00', status='Rejected', tone='danger',
                 amount_colour=DANGER, icon='warning'),
            dict(title='INV-2026-0409', sub='Amanah Teknik Sdn Bhd · 61 days overdue',
                 amount='RM 18,200.00', status='Overdue', tone='danger',
                 amount_colour=DANGER, icon='clock'),
            dict(title='INV-2026-0404', sub='Bumi Hijau Agro Sdn Bhd · 2 Sep 2026',
                 amount='RM 54,115.75', status='Paid', tone='success', icon='checkcircle'),
            dict(title='INV-2026-0401', sub='Desa Murni Catering · 1 Sep 2026',
                 amount='RM 3,208.00', status='Part paid', tone='warning', icon='clock'),
            dict(title='INV-2026-0398', sub='Prisma Digital Sdn Bhd · draft',
                 amount='RM 9,750.00', status='Draft', tone='grey', icon='doc'),
        ])
    elif route == '/einvoice':
        spec.update(kind='stats', tabs=['Outgoing', 'Received', 'Consolidated'],
                    actions=('refresh', 'bell'), search=None, fab=None, nav=5, rail=7,
                    hero=dict(label='Submitted to LHDN this month',
                              value='1,284', sub='MyInvois · September 2026',
                              frac=0.94, note='94% validated on first submission'),
                    tiles=[('Validated', '1,207', 'Cleared by LHDN', 'success'),
                           ('Submitted', '54', 'Awaiting response', 'info'),
                           ('Rejected', '23', 'Needs correction', 'danger'),
                           ('Cancelled', '9', 'Within 72 hours', 'warning')],
                    rows_title='Needs correction',
                    rows=[
            dict(title='INV-2026-0412 · CF321', sub='Buyer TIN fails checksum',
                 status='Fix', tone='danger', icon='warning'),
            dict(title='INV-2026-0396 · DS302', sub='Classification code missing on line 3',
                 status='Fix', tone='danger', icon='warning'),
            dict(title='CN-2026-0044 · CF364', sub='Original invoice UUID not found',
                 status='Fix', tone='warning', icon='clock')])
    elif route == '/hr/payroll':
        spec.update(kind='stats', tabs=['September', 'August', 'History'],
                    actions=('download', 'bell'), search=None, fab='Run payroll',
                    nav=5, rail=8,
                    hero=dict(label='September 2026 net pay', value='RM 184,206.45',
                              sub='24 employees · paid 25 Sep', frac=1.0,
                              note='EPF, SOCSO, EIS and PCB computed and locked'),
                    tiles=[('EPF', 'RM 31,440.20', 'Employer 13% + employee 11%', 'accent'),
                           ('SOCSO', 'RM 3,118.50', 'Act 4 · employer 1.75%', 'info'),
                           ('EIS', 'RM 892.40', '0.2% each side', 'violet'),
                           ('PCB', 'RM 22,760.00', 'MTD remitted by 15 Oct', 'warning')],
                    rows_title='This run',
                    rows=[
            dict(title='Nurul Aisyah Rahman', sub='Senior Accountant · EPF 11%',
                 amount='RM 8,420.00', status='Paid', tone='success', icon='person'),
            dict(title='Tan Wei Ming', sub='Operations Manager · EPF 11%',
                 amount='RM 9,180.00', status='Paid', tone='success', icon='person'),
            dict(title='Ravi Kumar Suppiah', sub='Site Supervisor · overtime 12h',
                 amount='RM 5,640.50', status='Paid', tone='success', icon='person')])
    elif route == '/reports':
        spec.update(kind='report', tabs=['Profit and loss', 'Balance sheet', 'Trial balance'],
                    actions=('download', 'filter'), search=None, fab=None, nav=5, rail=6,
                    report_title='Profit and loss',
                    report_sub='Demo Sdn Bhd · 1 Jan – 30 Sep 2026 · MYR',
                    cols=['2025', '2026'],
                    report_rows=[
            dict(kind='head', label='Revenue'),
            dict(label='Sales — Trading', value='3,914,280.00', prev='3,402,110.00'),
            dict(label='Sales — Services', value='612,450.00', prev='548,900.00'),
            dict(kind='total', label='Total revenue', value='4,526,730.00',
                 prev='3,951,010.00'),
            dict(kind='head', label='Cost of sales'),
            dict(label='Opening stock', value='412,900.00', prev='388,400.00'),
            dict(label='Purchases', value='2,481,330.00', prev='2,210,760.00'),
            dict(label='Closing stock', value='(455,120.00)', prev='(412,900.00)'),
            dict(kind='total', label='Gross profit', value='2,087,620.00',
                 prev='1,764,750.00', colour=SUCCESS),
            dict(kind='head', label='Operating expenses'),
            dict(label='Salaries and wages', value='1,104,220.00', prev='998,300.00'),
            dict(label='EPF, SOCSO and EIS', value='168,940.00', prev='151,220.00'),
            dict(label='Rental of premises', value='144,000.00', prev='132,000.00'),
            dict(label='Utilities', value='61,380.00', prev='58,120.00'),
            dict(label='Depreciation', value='88,410.00', prev='79,900.00'),
            dict(kind='total', label='Profit before tax', value='520,670.00',
                 prev='345,210.00', colour=SUCCESS)])
    elif route == '/ask':
        spec.update(kind='ask', tabs=None, actions=('clock', 'more'), search=None,
                    fab=None, nav=4, rail=9,
                    messages=[
            dict(who='user', text='Which customers owe me more than RM 10,000 past 60 days?'),
            dict(who='ai', text='Four customers, RM 61,480.00 in total, all past 60 days. '
                                'Amanah Teknik is the oldest at 61 days.',
                 table=[('Amanah Teknik Sdn Bhd', 'RM 18,200.00'),
                        ('Kilang Serbaguna Sdn Bhd', 'RM 21,340.00'),
                        ('Sentosa Marine Services', 'RM 11,290.00')]),
            dict(who='user', text='What did EPF cost me last quarter?'),
            dict(who='ai', text='RM 94,320.60 of employer EPF across July, August and '
                                'September, on a payroll of 24. That is 13% of qualifying '
                                'wages, and it is up 6.4% on the quarter before because '
                                'two people joined in August.')],
                    chips=['Show my cash flow', 'Unpaid bills', 'Explain this variance'])
    elif route == '/crm':
        spec.update(kind='board', tabs=['Pipeline', 'Forecast', 'Activity'],
                    actions=('filter', 'bell'), search=None, fab='New deal', nav=3, rail=5,
                    columns=[
            dict(name='Qualified', value='RM 186k', tone='info', cards=[
                dict(title='Kilang Serbaguna', sub='Annual licence · 40 seats',
                     amount='RM 84,000', who='NA'),
                dict(title='Desa Murni Catering', sub='POS + payroll', amount='RM 32,400',
                     who='TW'),
                dict(title='Lim Heng Hardware', sub='Stock module', amount='RM 18,600',
                     who='RK')]),
            dict(name='Proposal', value='RM 244k', tone='warning', cards=[
                dict(title='Pantai Timur Logistics', sub='Fleet + e-Invoice',
                     amount='RM 128,000', who='SN'),
                dict(title='Amanah Teknik', sub='Migration from spreadsheets',
                     amount='RM 61,200', who='NA'),
                dict(title='Prisma Digital', sub='Practice portfolio', amount='RM 54,800',
                     who='LC')]),
            dict(name='Won', value='RM 312k', tone='success', cards=[
                dict(title='Bumi Hijau Agro', sub='Signed 12 Sep', amount='RM 176,000',
                     who='TW'),
                dict(title='Sentosa Marine', sub='Signed 4 Sep', amount='RM 88,400',
                     who='RK'),
                dict(title='Koperasi Warga', sub='Signed 1 Sep', amount='RM 47,900',
                     who='SN')])])
    elif route == '/till':
        spec.update(kind='grid', tabs=['All', 'Food', 'Drinks', 'Sets'],
                    actions=('search', 'more'), search=None, fab=None, nav=5, rail=1)
    return spec


HEROES = ['/dashboard', '/sales/invoice', '/einvoice', '/hr/payroll',
          '/reports', '/ask', '/crm', '/till']


# --- everything else --------------------------------------------------------

def generic(module, area, label, route, spec):
    r = C.rng(route)
    seg = route.strip('/').split('/')

    if route.startswith('/sales/'):
        key = seg[1]
        spec.update(kind='doclist', tabs=['All', 'Open', 'Closed'], nav=1, rail=1,
                    search=f'Search {label.lower()}', fab=f'New {label[:-1].lower()}',
                    chips=['This month', 'Open', 'Customer'],
                    rows=_docs(route, DOC_PREFIX.get(key, 'DOC'), C.ORGS, SALES_STATUS))
    elif route.startswith('/purchases/'):
        key = seg[1]
        spec.update(kind='doclist', tabs=['All', 'Open', 'Closed'], nav=5, rail=2,
                    search=f'Search {label.lower()}', fab=f'New {label[:-1].lower()}',
                    chips=['This month', 'Awaiting', 'Supplier'],
                    rows=_docs(route, DOC_PREFIX.get(key, 'DOC'), C.ORGS, PURCH_STATUS))
    elif route in ('/contacts', '/customers', '/suppliers', '/prospects', '/salespeople'):
        subs = {'/contacts': ['Customer · Selangor', 'Supplier · Penang',
                              'Customer · Johor', 'Prospect · KL'],
                '/customers': ['TIN C21… · terms 30 days', 'TIN C88… · terms 14 days',
                               'TIN C40… · cash'],
                '/suppliers': ['Terms 30 days · MYR', 'Terms 60 days · MYR',
                               'Terms 14 days · USD'],
                '/prospects': ['Source: referral', 'Source: website',
                               'Source: trade show'],
                '/salespeople': ['Quota RM 400k · 82%', 'Quota RM 250k · 96%',
                                 'Quota RM 180k · 61%']}[route]
        if route == '/salespeople':
            spec.update(kind='list', rows=_people(route, subs, amounts=(80000, 420000)))
        else:
            spec.update(kind='list', rows=_orgs(route, subs, amounts=(2000, 90000)))
        spec.update(tabs=None, nav=2, rail=3, search=f'Search {label.lower()}',
                    fab='Add contact', chips=['All', 'Customers', 'Suppliers', 'Active'])
    elif route == '/collections':
        spec.update(kind='doclist', tabs=['1–30', '31–60', '61–90', '90+'],
                    active_tab=2, nav=2, rail=3, search='Search overdue',
                    fab='Send reminders',
                    totals=[('Overdue', 'RM 44,120', 'danger'),
                            ('Promised', 'RM 12,400', 'warning'),
                            ('Collected', 'RM 88,900', 'success')],
                    rows=[dict(title=o, sub=f'{r.randint(31, 120)} days · last chased '
                                            f'{C.date(r, "Aug")}',
                               amount=C.money(r.uniform(3000, 30000)),
                               amount_colour=DANGER, status='Chase', tone='danger',
                               icon='clock') for o in C.ORGS[:8]])
    elif route == '/crm/leads':
        spec.update(kind='list', tabs=['New', 'Working', 'Nurture'], nav=3, rail=5,
                    search='Search leads', fab='New lead',
                    rows=_people(route, ['Website form · today', 'Referral · 2 days',
                                         'Trade show · 4 days', 'Cold call · 1 week'],
                                 statuses=[('Hot', 'danger'), ('Warm', 'warning'),
                                           ('New', 'info')]))
    elif route == '/accounts':
        spec.update(kind='doclist', tabs=['All', 'Assets', 'Liabilities', 'Income'],
                    nav=5, rail=6, search='Search accounts', fab='New account',
                    row_h=58,
                    rows=[dict(title=f'{code} · {name}', sub='Active · MYR',
                               amount=C.money(r.uniform(2000, 900000)),
                               tone='accent', icon='doc')
                          for code, name in C.ACCOUNTS])
    elif route in ('/journals', '/recurring'):
        spec.update(kind='doclist', tabs=['Posted', 'Draft'], nav=5, rail=6,
                    search='Search journals', fab='New journal',
                    rows=_docs(route, 'JV', ['Accruals', 'Depreciation', 'Payroll',
                                             'Bank charges', 'Reclassification'],
                               [('Posted', 'success'), ('Draft', 'grey')], lo=200, hi=90000))
    elif route == '/financial-statements':
        spec.update(kind='report', tabs=['Balance sheet', 'P&L', 'Equity', 'Cash flow'],
                    nav=5, rail=6, search=None, fab=None,
                    report_title='Statement of financial position',
                    report_sub='Demo Sdn Bhd · as at 30 September 2026 · MFRS for SMEs',
                    cols=['2025', '2026'],
                    report_rows=[
                        dict(kind='head', label='Non-current assets'),
                        dict(label='Property, plant and equipment', value='1,284,600.00',
                             prev='1,188,300.00'),
                        dict(label='Right-of-use assets', value='312,400.00',
                             prev='366,800.00'),
                        dict(kind='head', label='Current assets'),
                        dict(label='Inventories', value='455,120.00', prev='412,900.00'),
                        dict(label='Trade receivables', value='172,905.00',
                             prev='203,440.00'),
                        dict(label='Cash and bank', value='613,488.71', prev='481,220.10'),
                        dict(kind='total', label='Total assets', value='2,838,513.71',
                             prev='2,652,660.10'),
                        dict(kind='head', label='Equity and liabilities'),
                        dict(label='Share capital', value='500,000.00', prev='500,000.00'),
                        dict(label='Retained earnings', value='1,402,180.00',
                             prev='1,188,900.00'),
                        dict(label='Trade payables', value='688,410.00', prev='722,300.00'),
                        dict(kind='total', label='Total equity and liabilities',
                             value='2,838,513.71', prev='2,652,660.10')])
    elif route in ('/budgets', '/cash-flow', '/forecasting', '/manufacturing',
                   '/takings', '/pos-reports', '/loyalty', '/property'):
        titles = {'/budgets': ('Budget used, year to date', 'RM 2,914,600', '73% of RM 4.0m'),
                  '/cash-flow': ('Closing bank, 30 Sep', 'RM 613,488.71',
                                 '13 weeks projected'),
                  '/forecasting': ('Forecast demand, Q4', '18,420 units',
                                   'Across 42 stock items'),
                  '/manufacturing': ('Work orders open', '14', '3 behind schedule'),
                  '/takings': ('Takings today', 'RM 8,914.20', '211 tickets · 2 tills'),
                  '/pos-reports': ('Sales this week', 'RM 52,308.40', '1,284 tickets'),
                  '/loyalty': ('Points issued this month', '184,200', '1,942 members'),
                  '/property': ('Rent billed this month', 'RM 248,900',
                                '86 units · 4 buildings')}[route]
        spec.update(kind='stats', tabs=None, nav=5, rail=6, search=None, fab=None,
                    hero=dict(label=titles[0], value=titles[1], sub=titles[2],
                              frac=r.uniform(0.55, 0.95),
                              note='Updated 18 Sep 2026, 09:41'),
                    tiles=[('This month', C.money(r.uniform(40000, 500000)), 'vs budget',
                            'accent'),
                           ('Last month', C.money(r.uniform(40000, 500000)), 'actual',
                            'info'),
                           # A variance is favourable or it is not, and the
                           # colour has to agree with the word: theme.dart's
                           # `Tone` exists because a favourable variance shown
                           # in red reads as bad news about a good month.
                           _variance(r.uniform(-40000, 60000)),
                           ('Committed', C.money(r.uniform(10000, 120000)), 'not yet spent',
                            'warning')],
                    rows_title=label,
                    rows=_orgs(route, ['Selangor', 'Penang', 'Johor'], n=3,
                               amounts=(5000, 90000)))
    elif route in ('/reconcile', '/transfers', '/exchange-rates', '/intercompany',
                   '/cheques', '/contra', '/withholding', '/landed-cost', '/deposits',
                   '/receipts', '/receipts/group', '/deliveries', '/recurring-documents'):
        parties = C.BANKS if route in ('/reconcile', '/transfers') else C.ORGS
        spec.update(kind='doclist', tabs=['Open', 'Matched', 'All'], nav=5, rail=1,
                    search=f'Search {label.lower()}', fab=f'New {label.split()[0].lower()}',
                    rows=_docs(route, 'TXN', parties,
                               [('Matched', 'success'), ('Unmatched', 'warning'),
                                ('Cleared', 'info')], lo=150, hi=42000))
    elif route in ('/items', '/lots', '/stock-take', '/bundles', '/recipes', '/assets'):
        spec.update(kind='doclist', tabs=['All', 'Low stock', 'Inactive'], nav=5, rail=4,
                    search=f'Search {label.lower()}', fab=f'New item', row_icon='box',
                    rows=_items(route))
    elif route.startswith('/hr/') or route == '/timesheets':
        if route == '/hr/leave':
            spec.update(kind='calendar', tabs=['Calendar', 'Requests', 'Balances'],
                        nav=5, rail=8, search=None, fab='Apply for leave',
                        month='September 2026',
                        marks={3: ('accent',), 4: ('accent',), 11: ('warning',),
                               16: ('info',), 17: ('info',), 23: ('success',),
                               24: ('success',), 25: ('success',)},
                        rows_title='Awaiting approval',
                        rows=[dict(title='Tan Wei Ming', sub='Annual · 23–25 Sep · 3 days',
                                   status='Approve', tone='warning', icon='calendar'),
                              dict(title='Siti Nadia Hamzah',
                                   sub='Medical · 11 Sep · 1 day', status='Approved',
                                   tone='success', icon='checkcircle'),
                              dict(title='Ravi Kumar Suppiah',
                                   sub='Unpaid · 16–17 Sep · 2 days', status='Review',
                                   tone='info', icon='clock')])
        elif route == '/timesheets':
            spec.update(kind='calendar', tabs=['Week', 'Month', 'Approvals'],
                        nav=5, rail=8, search=None, fab='Log time',
                        month='September 2026',
                        marks={i: ('accent',) for i in (1, 2, 3, 4, 7, 8, 9, 10, 11,
                                                        14, 15, 16, 17)},
                        rows_title='This week',
                        rows=[dict(title='Kilang Serbaguna · site works',
                                   sub='Mon–Wed · 22.5 hours', amount='22.5 h',
                                   status='Billable', tone='success', icon='clock'),
                              dict(title='Internal · month-end close',
                                   sub='Thu · 6.0 hours', amount='6.0 h',
                                   status='Internal', tone='grey', icon='clock')])
        elif route in ('/hr/setup', '/hr/me'):
            spec.update(kind='form', tabs=None, nav=5, rail=8, search=None, fab=None,
                        groups=[dict(name='Statutory', fields=[
                            dict(label='EPF employee rate', value='11%'),
                            dict(label='EPF employer rate', value='13% below RM 5,000'),
                            dict(label='SOCSO category', value='Act 4 · employment injury'),
                            dict(label='EIS', value='0.2% employer, 0.2% employee')]),
                            dict(name='This employee', fields=[
                                dict(label='Name', value='Nurul Aisyah Rahman'),
                                dict(label='EPF number', value='1408 2291 4471'),
                                dict(label='Income tax (TIN)', value='IG 1129 4482 100'),
                                dict(label='Pay by bank transfer', value='Maybank ···5142',
                                     switch=True)])])
        elif route == '/hr/remittances':
            spec.update(kind='stats', tabs=['September', 'August'], nav=5, rail=8,
                        search=None, fab='Generate files',
                        hero=dict(label='Due to statutory bodies', value='RM 58,211.10',
                                  sub='September 2026 · remit by 15 Oct', frac=0.0,
                                  note='Nothing remitted yet for this month'),
                        tiles=[('EPF (KWSP)', 'RM 31,440.20', 'Form A · by 15 Oct',
                                'accent'),
                               ('SOCSO (PERKESO)', 'RM 3,118.50', 'Form 8A · by 15 Oct',
                                'info'),
                               ('EIS', 'RM 892.40', 'Lodged with SOCSO', 'violet'),
                               ('PCB (LHDN)', 'RM 22,760.00', 'CP39 · by 15 Oct',
                                'warning')],
                        rows_title='Files to lodge',
                        rows=[dict(title='KWSP Form A · September', sub='Text file · 24 lines',
                                   status='Download', tone='accent', icon='download'),
                              dict(title='PERKESO Form 8A · September',
                                   sub='Text file · 24 lines', status='Download',
                                   tone='accent', icon='download'),
                              dict(title='LHDN CP39 · September', sub='Text file · 19 lines',
                                   status='Download', tone='accent', icon='download')])
        elif route == '/hr/talent':
            spec.update(kind='board', tabs=['Applicants', 'Roles'], nav=5, rail=8,
                        search=None, fab='New role',
                        columns=[dict(name='Applied', value='18', tone='info', cards=[
                            dict(title='Chong Mei Ling', sub='Accounts Executive',
                                 amount='3 yrs', who='CM'),
                            dict(title='Arun Vijayan', sub='Warehouse Lead',
                                 amount='6 yrs', who='AV')]),
                            dict(name='Interview', value='6', tone='warning', cards=[
                                dict(title='Hafiz Zulkifli', sub='Payroll Officer',
                                     amount='4 yrs', who='HZ'),
                                dict(title='Yap Su Lin', sub='Accounts Executive',
                                     amount='2 yrs', who='YS')]),
                            dict(name='Offer', value='2', tone='success', cards=[
                                dict(title='Farah Iskandar', sub='Senior Accountant',
                                     amount='RM 7,800', who='FI')])])
        elif route == '/hr/ea-forms':
            spec.update(kind='doclist', tabs=['2026', '2025'], nav=5, rail=8,
                        search='Search employees', fab='Generate EA forms',
                        rows=[dict(title=p, sub='Form EA · year of assessment 2026',
                                   status='Ready', tone='success', icon='doc')
                              for p in C.PEOPLE[:8]])
        else:
            statuses = {'/hr/people': [('Active', 'success'), ('Probation', 'warning')],
                        '/hr/claims': [('Approved', 'success'), ('Pending', 'warning'),
                                       ('Rejected', 'danger')],
                        '/hr/onboarding': [('Day 1', 'info'), ('Week 1', 'accent'),
                                           ('Done', 'success')]}.get(route)
            subs = {'/hr/people': ['Senior Accountant · EPF 11%',
                                   'Operations Manager · EPF 11%',
                                   'Site Supervisor · EPF 11%', 'Driver · EPF 11%'],
                    '/hr/claims': ['Mileage · 12 Sep', 'Medical · 9 Sep',
                                   'Meal allowance · 8 Sep'],
                    '/hr/onboarding': ['Joined 1 Sep · 6 tasks left',
                                       'Joined 15 Sep · 9 tasks left']}.get(
                        route, ['Employee'])
            spec.update(kind='list', tabs=None, nav=5, rail=8,
                        search=f'Search {label.lower()}', fab='Add',
                        chips=['All', 'Active', 'Probation'],
                        rows=_people(route, subs, statuses=statuses,
                                     amounts=(1800, 12000) if route == '/hr/claims'
                                     else None))
    elif route in ('/kiosk', '/floor', '/menu-times', '/promotions', '/memberships',
                   '/counters', '/stalls'):
        if route in ('/kiosk', '/floor'):
            spec.update(kind='grid', tabs=['All', 'Food', 'Drinks'], nav=5, rail=1,
                        search=None, fab=None)
        else:
            spec.update(kind='list', tabs=None, nav=5, rail=1,
                        search=f'Search {label.lower()}', fab='New',
                        rows=_orgs(route, ['Active · all outlets', 'Weekdays only',
                                           'Expires 31 Dec'], amounts=(50, 5000),
                                   statuses=[('Active', 'success'), ('Ends soon', 'warning')]))
    elif route in ('/order-board', '/kitchen', '/queue', '/diary'):
        if route == '/diary':
            spec.update(kind='calendar', tabs=['Day', 'Week'], nav=5, rail=1, search=None,
                        fab='New booking', month='September 2026',
                        marks={i: ('accent',) for i in (5, 6, 12, 13, 19, 20, 26)},
                        rows_title='Today',
                        rows=[dict(title='Table 6 · 18:30', sub='Party of 4 · Tan',
                                   status='Confirmed', tone='success', icon='calendar'),
                              dict(title='Table 2 · 19:00', sub='Party of 2 · Lim',
                                   status='Seated', tone='info', icon='calendar')])
        else:
            spec.update(kind='board', tabs=['Open', 'Ready'], nav=5, rail=1, search=None,
                        fab=None,
                        columns=[dict(name='New', value='4', tone='info', cards=[
                            dict(title='#2041 · Table 6', sub='2 Nasi Lemak, 1 Teh Tarik',
                                 amount='RM 36.25', who='T6'),
                            dict(title='#2042 · Takeaway', sub='1 Char Kuey Teow',
                                 amount='RM 11.00', who='TA')]),
                            dict(name='Cooking', value='3', tone='warning', cards=[
                                dict(title='#2039 · Table 2', sub='Nasi Kandar Set',
                                     amount='RM 15.50', who='T2'),
                                dict(title='#2038 · Grab', sub='2 Mee Goreng',
                                     amount='RM 19.00', who='GR')]),
                            dict(name='Ready', value='2', tone='success', cards=[
                                dict(title='#2036 · Table 9', sub='Cendol, Kopi O',
                                     amount='RM 10.50', who='T9')])])
    elif route in ('/voids',):
        spec.update(kind='doclist', tabs=['Today', 'This week'], nav=5, rail=1,
                    search='Search voids', fab=None,
                    rows=_docs(route, 'VOID', ['Till 1 · Aisyah', 'Till 2 · Firdaus'],
                               [('Void', 'danger'), ('Write-off', 'warning')],
                               lo=5, hi=320))
    elif route == '/einvoice/received':
        spec.update(kind='doclist', tabs=['All', 'To accept', 'Rejected'], nav=5, rail=7,
                    search='Search received', fab=None,
                    totals=[('Received', '412', 'info'), ('Accepted', '389', 'success'),
                            ('To review', '23', 'warning')],
                    rows=_docs(route, 'RCV', C.ORGS,
                               [('Accepted', 'success'), ('To review', 'warning'),
                                ('Rejected', 'danger')], lo=300, hi=38000))
    elif route == '/secretarial':
        spec.update(kind='stats', tabs=['Deadlines', 'Officers', 'Registers'],
                    nav=5, rail=6, search=None, fab='New filing',
                    hero=dict(label='Next SSM deadline', value='28 Nov 2026',
                              sub='Annual return · Demo Sdn Bhd (202601012345)',
                              frac=0.62, note='71 days away · lodged 9 Dec last year'),
                    tiles=[('Annual return', '28 Nov 2026', 'Section 68', 'warning'),
                           ('Financial statements', '31 Dec 2026', 'Section 259', 'info'),
                           ('Directors', '3', 'One resignation pending', 'accent'),
                           ('Shareholders', '5', '500,000 ordinary shares', 'violet')],
                    rows_title='Registers',
                    rows=[dict(title='Register of Directors', sub='Updated 4 Sep 2026',
                               status='Current', tone='success', icon='clipboard'),
                          dict(title='Register of Members', sub='Updated 12 Aug 2026',
                               status='Current', tone='success', icon='clipboard'),
                          dict(title='Register of Charges', sub='One charge registered',
                               status='Review', tone='warning', icon='clipboard')])
    elif route == '/legal':
        spec.update(kind='list', tabs=['Open', 'Closed'], nav=5, rail=6,
                    search='Search matters', fab='New matter',
                    rows=_orgs(route, ['Debt recovery · Sessions Court',
                                       'Contract review', 'Tenancy dispute'],
                               amounts=(2000, 60000),
                               statuses=[('Open', 'info'), ('Hearing', 'warning'),
                                         ('Closed', 'success')]))
    elif route in ('/tickets', '/inbox', '/chat'):
        if route == '/chat':
            spec.update(kind='chat', tabs=None, nav=5, rail=6, search=None, fab=None,
                        messages=[
                            dict(who='ai', text='Morning — the September payroll is locked '
                                                'and the bank file is ready to upload.'),
                            dict(who='user', text='Did the EPF number for the new joiner '
                                                  'come through?'),
                            dict(who='ai', text='Yes, added this morning. 24 employees on '
                                                'the run, nothing outstanding.')],
                        chips=['Payroll', 'e-Invoice', 'Month end'])
        else:
            spec.update(kind='doclist', tabs=['Open', 'Mine', 'Closed'], nav=5, rail=6,
                        search='Search tickets', fab='New ticket', row_icon='mail',
                        rows=_docs(route, 'TKT', C.ORGS,
                                   [('Open', 'info'), ('Waiting', 'warning'),
                                    ('Closed', 'success')], lo=0, hi=0))
            for row in spec['rows']:
                row.pop('amount', None)
    elif route in ('/settings', '/companies/new', '/import', '/email', '/feedback'):
        groups = {
            '/settings': [dict(name='This company', fields=[
                dict(label='Company name', value='Demo Sdn Bhd'),
                dict(label='SSM registration', value='202601012345 (1234567-A)'),
                dict(label='Income tax (TIN)', value='C 2588 4471 0900'),
                dict(label='SST registration', value='W10-1809-31000123')]),
                dict(name='e-Invoice', fields=[
                    dict(label='MyInvois environment', value='Production',
                         chip=('Live', 'success')),
                    dict(label='Submit invoices automatically', value='On issue',
                         switch=True),
                    dict(label='Consolidate B2C', value='Monthly, on the 5th',
                         switch=True)])],
            '/companies/new': [dict(name='Company', fields=[
                dict(label='Registered name', value='Bumi Hijau Agro Sdn Bhd'),
                dict(label='SSM registration number', value='202301004567'),
                dict(label='Financial year end', value='31 December'),
                dict(label='Base currency', value='MYR — Malaysian Ringgit')]),
                dict(name='Modules', fields=[
                    dict(label='Accounting and e-Invoice', value='Included', switch=True),
                    dict(label='Payroll', value='24 employees', switch=True),
                    dict(label='Point of sale', value='Not subscribed', switch=False)])],
            '/import': [dict(name='Bring your books across', fields=[
                dict(label='Chart of accounts', value='CSV · 128 accounts',
                     chip=('Imported', 'success')),
                dict(label='Customers and suppliers', value='CSV · 412 contacts',
                     chip=('Imported', 'success')),
                dict(label='Opening balances', value='As at 1 Jan 2026',
                     chip=('Ready', 'info')),
                dict(label='Open invoices', value='CSV · 31 documents',
                     chip=('Checking', 'warning'))])],
            '/email': [dict(name='Outgoing email', fields=[
                dict(label='From address', value='accounts@demo.com.my'),
                dict(label='Reply-to', value='accounts@demo.com.my'),
                dict(label='Attach PDF to invoices', value='Always', switch=True),
                dict(label='Send dunning letters', value='Weekly, Mondays', switch=True)])],
            '/feedback': [dict(name='Report a problem', fields=[
                dict(label='Module', value='Compliance'),
                dict(label='Part of it', value='LHDN'),
                dict(label='Screen', value='e-Invoice'),
                dict(label='Attach a screenshot', value='One file', switch=True)])],
        }[route]
        spec.update(kind='form', tabs=None, nav=5, rail=10, search=None, fab='Save',
                    groups=groups)
    elif route in ('/team', '/approvals', '/security', '/practice'):
        if route == '/practice':
            spec.update(kind='list', tabs=None, nav=5, rail=10, search='Search companies',
                        fab='Add a company',
                        rows=_orgs(route, ['FYE 31 Dec · 3 filings due',
                                           'FYE 30 Jun · up to date',
                                           'FYE 31 Mar · 1 filing due'],
                                   amounts=(20000, 900000),
                                   statuses=[('Up to date', 'success'),
                                             ('Due soon', 'warning'),
                                             ('Overdue', 'danger')]))
        elif route == '/security':
            spec.update(kind='doclist', tabs=['All', 'Sign-ins', 'Changes'], nav=5, rail=10,
                        search='Search log', fab=None, row_icon='shield', row_h=58,
                        rows=[dict(title=t, sub=s, status=st, tone=tone, icon=ic)
                              for t, s, st, tone, ic in [
                                  ('Signed in', 'Nurul Aisyah · Chrome · 18 Sep 09:41',
                                   'You', 'accent', 'key'),
                                  ('Password changed', 'Tan Wei Ming · 17 Sep 16:02',
                                   'Done', 'success', 'lock'),
                                  ('Failed sign-in', 'Unknown device · 16 Sep 23:14',
                                   'Blocked', 'danger', 'shield'),
                                  ('Role changed', 'Ravi Kumar → Approver · 15 Sep',
                                   'Admin', 'info', 'person'),
                                  ('API key issued', 'MyInvois integration · 12 Sep',
                                   'Active', 'warning', 'key')]])
        else:
            spec.update(kind='list', tabs=None, nav=5, rail=10,
                        search=f'Search {label.lower()}', fab='Invite',
                        rows=_people(route, ['Administrator · all modules',
                                             'Approver · purchases',
                                             'Bookkeeper · sales and purchases',
                                             'Viewer · reports only'],
                                     statuses=[('Active', 'success'),
                                               ('Invited', 'warning')]))
    else:
        spec.update(kind='doclist', tabs=None, nav=5, rail=6,
                    search=f'Search {label.lower()}', fab='New',
                    rows=_docs(route, 'REC', C.ORGS,
                               [('Open', 'info'), ('Done', 'success'),
                                ('Draft', 'grey')], lo=200, hi=40000))
    return spec


def build(module, area, label, route, org='Demo Sdn Bhd'):
    spec = dict(module=module, area=area, title=label, route=route, org=org,
                tabs=None, active_tab=0, actions=('search', 'bell'), search=None,
                chips=None, fab=None, nav=5, rail=6, kind='doclist')
    if route in HEROES:
        return hero(route, spec)
    return generic(module, area, label, route, spec)
