"""Sample content for the mockups.

Invented, and deliberately so: nothing here comes from a real company's
books. The shapes are real — Malaysian entity names, MYR amounts, LHDN
validation states, EPF/SOCSO/EIS/PCB lines on a payslip, SSM deadlines —
because a store screenshot that shows a US-style listing for a product
that only does Malaysian statutory work is a lie of a different kind.

Everything is seeded off the route, so the same screen draws the same
figures on every build and a regenerated set diffs cleanly.
"""
import random

ORGS = ['Demo Sdn Bhd', 'Kilang Serbaguna Sdn Bhd', 'Pantai Timur Logistics',
        'Amanah Teknik Sdn Bhd', 'Bumi Hijau Agro Sdn Bhd', 'Prisma Digital Sdn Bhd',
        'Desa Murni Catering', 'Sentosa Marine Services', 'Lim Heng Hardware',
        'Syarikat Maju Trading', 'Tenaga Jaya Enterprise', 'Koperasi Warga Sejahtera']

PEOPLE = ['Nurul Aisyah Rahman', 'Tan Wei Ming', 'Ravi Kumar Suppiah',
          'Siti Nadia Hamzah', 'Lee Chun Kit', 'Muhammad Firdaus Ali',
          'Chong Mei Ling', 'Arun Vijayan', 'Hafiz Zulkifli', 'Yap Su Lin',
          'Farah Iskandar', 'Gopal Menon', 'Wong Kar Hoe', 'Zainab Othman']

ITEMS = [('Cement OPC 50kg', 'CEM-050'), ('Steel Bar Y10 6m', 'STL-Y10'),
         ('Plywood 18mm 8x4', 'PLY-018'), ('Emulsion Paint 18L', 'PNT-18L'),
         ('PVC Pipe 4" 6m', 'PVC-004'), ('Roof Sheet 0.42mm', 'RSH-042'),
         ('Sand River m³', 'SND-RIV'), ('Wire Mesh A7', 'WMS-A07'),
         ('Nails 3" 1kg', 'NAL-300'), ('Silicone Sealant', 'SIL-001')]

# Long enough to fill the till on the widest screen in the sets: an iPad
# Pro in landscape lays out eight columns, and a grid that runs out after
# twelve tiles advertises a menu with twelve things on it.
MENU = [('Nasi Lemak Ayam', '12.00'), ('Roti Canai', '2.50'), ('Teh Tarik', '3.20'),
        ('Mee Goreng Mamak', '9.50'), ('Kopi O Ais', '3.50'), ('Char Kuey Teow', '11.00'),
        ('Nasi Kandar Set', '15.50'), ('Milo Dinosaur', '6.80'), ('Curry Puff', '2.00'),
        ('Cendol Special', '7.00'), ('Ayam Percik', '14.00'), ('Limau Ais', '3.00'),
        ('Nasi Goreng Kampung', '10.50'), ('Mee Rebus', '8.50'), ('Sirap Bandung', '3.80'),
        ('Laksa Johor', '13.00'), ('Roti Telur', '3.50'), ('Nasi Ayam Hainan', '11.50'),
        ('Teh O Limau', '3.20'), ('Satay Ayam 10 cucuk', '12.00'),
        ('Rojak Buah', '7.50'), ('Air Kelapa', '5.50'), ('Pisang Goreng', '4.00'),
        ('Set Nasi Campur', '13.50')]

ACCOUNTS = [('4000', 'Sales — Trading'), ('4100', 'Sales — Services'),
            ('5000', 'Cost of goods sold'), ('6100', 'Salaries and wages'),
            ('6110', 'EPF employer'), ('6200', 'Rental of premises'),
            ('6300', 'Utilities'), ('1100', 'Trade receivables'),
            ('2100', 'Trade payables'), ('1010', 'Maybank current 5142')]

BANKS = ['Maybank ···5142', 'CIMB ···8830', 'Public Bank ···2276', 'RHB ···9014']

MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']


def rng(route):
    return random.Random(hash(route) & 0xFFFFFFFF)


def money(v, prefix='RM'):
    s = f'{v:,.2f}'
    return f'{prefix} {s}' if prefix else s


def date(r, month='Sep', year=2026):
    return f'{r.randint(1, 28)} {month} {year}'


def walk(r, n=14, start=100.0, drift=0.06, vol=0.09):
    v, out = start, []
    for _ in range(n):
        v *= 1 + drift / n + r.uniform(-vol, vol)
        out.append(max(v, 1.0))
    return out
