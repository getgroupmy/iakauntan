-- =====================================================================
-- iAkauntan :: 0011 Malaysian reference data
-- Code lists published by LHDN for MyInvois, plus the ISO lists the
-- e-Invoice schema references.
-- =====================================================================

-- The MyInvois UOM list is UN/ECE Recommendation 20; C62 ("one") is the
-- generic unit, so use it rather than an invented 'UNT'.
alter table public.items alter column uom_code set default 'C62';

-- ---------------------------------------------------------------------
-- Countries (ISO 3166-1 alpha-3, as used by MyInvois)
-- ---------------------------------------------------------------------
insert into public.ref_countries (code, name, alpha2, dial_code) values
  ('MYS','Malaysia','MY','+60'),
  ('SGP','Singapore','SG','+65'),
  ('IDN','Indonesia','ID','+62'),
  ('THA','Thailand','TH','+66'),
  ('BRN','Brunei Darussalam','BN','+673'),
  ('PHL','Philippines','PH','+63'),
  ('VNM','Viet Nam','VN','+84'),
  ('KHM','Cambodia','KH','+855'),
  ('LAO','Lao People''s Democratic Republic','LA','+856'),
  ('MMR','Myanmar','MM','+95'),
  ('CHN','China','CN','+86'),
  ('HKG','Hong Kong','HK','+852'),
  ('TWN','Taiwan','TW','+886'),
  ('JPN','Japan','JP','+81'),
  ('KOR','Korea, Republic of','KR','+82'),
  ('IND','India','IN','+91'),
  ('PAK','Pakistan','PK','+92'),
  ('BGD','Bangladesh','BD','+880'),
  ('LKA','Sri Lanka','LK','+94'),
  ('NPL','Nepal','NP','+977'),
  ('AUS','Australia','AU','+61'),
  ('NZL','New Zealand','NZ','+64'),
  ('USA','United States of America','US','+1'),
  ('CAN','Canada','CA','+1'),
  ('GBR','United Kingdom','GB','+44'),
  ('IRL','Ireland','IE','+353'),
  ('DEU','Germany','DE','+49'),
  ('FRA','France','FR','+33'),
  ('NLD','Netherlands','NL','+31'),
  ('BEL','Belgium','BE','+32'),
  ('CHE','Switzerland','CH','+41'),
  ('ITA','Italy','IT','+39'),
  ('ESP','Spain','ES','+34'),
  ('PRT','Portugal','PT','+351'),
  ('SWE','Sweden','SE','+46'),
  ('NOR','Norway','NO','+47'),
  ('DNK','Denmark','DK','+45'),
  ('FIN','Finland','FI','+358'),
  ('POL','Poland','PL','+48'),
  ('AUT','Austria','AT','+43'),
  ('TUR','Turkiye','TR','+90'),
  ('RUS','Russian Federation','RU','+7'),
  ('ARE','United Arab Emirates','AE','+971'),
  ('SAU','Saudi Arabia','SA','+966'),
  ('QAT','Qatar','QA','+974'),
  ('KWT','Kuwait','KW','+965'),
  ('OMN','Oman','OM','+968'),
  ('BHR','Bahrain','BH','+973'),
  ('EGY','Egypt','EG','+20'),
  ('ZAF','South Africa','ZA','+27'),
  ('NGA','Nigeria','NG','+234'),
  ('KEN','Kenya','KE','+254'),
  ('BRA','Brazil','BR','+55'),
  ('MEX','Mexico','MX','+52'),
  ('ARG','Argentina','AR','+54'),
  ('CHL','Chile','CL','+56')
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- Malaysian states (LHDN MyInvois state codes)
-- ---------------------------------------------------------------------
insert into public.ref_states (code, name) values
  ('01','Johor'),
  ('02','Kedah'),
  ('03','Kelantan'),
  ('04','Melaka'),
  ('05','Negeri Sembilan'),
  ('06','Pahang'),
  ('07','Pulau Pinang'),
  ('08','Perak'),
  ('09','Perlis'),
  ('10','Selangor'),
  ('11','Terengganu'),
  ('12','Sabah'),
  ('13','Sarawak'),
  ('14','Wilayah Persekutuan Kuala Lumpur'),
  ('15','Wilayah Persekutuan Labuan'),
  ('16','Wilayah Persekutuan Putrajaya'),
  ('17','Not Applicable')
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- Tax types (MyInvois)
-- ---------------------------------------------------------------------
insert into public.ref_tax_types (code, description) values
  ('01','Sales Tax'),
  ('02','Service Tax'),
  ('03','Tourism Tax'),
  ('04','High-Value Goods Tax'),
  ('05','Sales Tax on Low Value Goods'),
  ('06','Not Applicable'),
  ('E','Tax exemption (where applicable)')
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- e-Invoice document types (MyInvois)
-- direction: +1 increases receivables, -1 reduces them.
-- ---------------------------------------------------------------------
insert into public.ref_einvoice_types (code, description, is_self_billed, direction) values
  ('01','Invoice',                    false,  1),
  ('02','Credit Note',                false, -1),
  ('03','Debit Note',                 false,  1),
  ('04','Refund Note',                false, -1),
  ('11','Self-billed Invoice',        true,   1),
  ('12','Self-billed Credit Note',    true,  -1),
  ('13','Self-billed Debit Note',     true,   1),
  ('14','Self-billed Refund Note',    true,  -1)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- Payment modes (MyInvois)
-- ---------------------------------------------------------------------
insert into public.ref_payment_modes (code, description) values
  ('01','Cash'),
  ('02','Cheque'),
  ('03','Bank Transfer'),
  ('04','Credit Card'),
  ('05','Debit Card'),
  ('06','e-Wallet / Digital Wallet'),
  ('07','Digital Bank'),
  ('08','Others')
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- Item classification codes (MyInvois, mandatory on every e-Invoice line)
-- ---------------------------------------------------------------------
insert into public.ref_classification_codes (code, description) values
  ('001','Breastfeeding equipment'),
  ('002','Child care centres and kindergartens fees'),
  ('003','Computer, smartphone or tablet'),
  ('004','Consolidated e-Invoice'),
  ('005','Construction materials (as specified under Fourth Schedule of the Lembaga Pembangunan Industri Pembinaan Malaysia Act 1994)'),
  ('006','Disbursement'),
  ('007','Donation'),
  ('008','e-Commerce - e-Invoice to buyer / purchaser'),
  ('009','e-Commerce - Self-billed e-Invoice to seller, logistics provider, etc.'),
  ('010','Education fees'),
  ('011','Goods on consignment (Consignor)'),
  ('012','Goods on consignment (Consignee)'),
  ('013','Gym membership'),
  ('014','Insurance - Education and medical benefits'),
  ('015','Insurance - Takaful or life insurance'),
  ('016','Interest and financing expenses'),
  ('017','Internet subscription'),
  ('018','Land and building'),
  ('019','Medical examination for learning disabilities and early intervention or rehabilitation treatments of learning disabilities'),
  ('020','Medical examination or vaccination expenses'),
  ('021','Medical expenses for serious diseases'),
  ('022','Others'),
  ('023','Petroleum operations (as defined in Petroleum (Income Tax) Act 1967)'),
  ('024','Private retirement scheme or deferred annuity scheme'),
  ('025','Motor vehicle'),
  ('026','Subscription of books / journals / magazines / newspapers / other similar publications'),
  ('027','Reimbursement'),
  ('028','Rental of motor vehicle'),
  ('029','EV charging facilities (installation, rental, sale / purchase or subscription fees)'),
  ('030','Repair and maintenance'),
  ('031','Research and development'),
  ('032','Foreign income'),
  ('033','Self-billed - Betting and gaming'),
  ('034','Self-billed - Importation of goods'),
  ('035','Self-billed - Importation of services'),
  ('036','Self-billed - Others'),
  ('037','Self-billed - Monetary payment to agents, dealers or distributors'),
  ('038','Sports equipment, rental / entry fees for sports facilities, registration in sports competition or sports training fees'),
  ('039','Supporting equipment for disabled person'),
  ('040','Voluntary contribution to approved provident fund'),
  ('041','Dental examination or treatment'),
  ('042','Fertility treatment'),
  ('043','Treatment and home care nursing, daycare centres and residential care centres'),
  ('044','Vouchers, gift cards, loyalty points, etc'),
  ('045','Self-billed - Non-monetary payment to agents, dealers or distributors')
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- Units of measure (UN/ECE Recommendation 20 subset)
-- ---------------------------------------------------------------------
insert into public.ref_uom_codes (code, name, category) values
  ('C62','Unit','quantity'),
  ('H87','Piece','quantity'),
  ('EA','Each','quantity'),
  ('SET','Set','quantity'),
  ('PR','Pair','quantity'),
  ('DZN','Dozen','quantity'),
  ('BX','Box','packaging'),
  ('CT','Carton','packaging'),
  ('PK','Pack','packaging'),
  ('BG','Bag','packaging'),
  ('CS','Case','packaging'),
  ('ROL','Roll','packaging'),
  ('PF','Pallet','packaging'),
  ('KGM','Kilogram','weight'),
  ('GRM','Gram','weight'),
  ('TNE','Tonne (metric)','weight'),
  ('LBR','Pound','weight'),
  ('LTR','Litre','volume'),
  ('MLT','Millilitre','volume'),
  ('MTQ','Cubic metre','volume'),
  ('GLL','Gallon (US)','volume'),
  ('MTR','Metre','length'),
  ('CMT','Centimetre','length'),
  ('MMT','Millimetre','length'),
  ('KTM','Kilometre','length'),
  ('INH','Inch','length'),
  ('FOT','Foot','length'),
  ('MTK','Square metre','area'),
  ('FTK','Square foot','area'),
  ('HUR','Hour','time'),
  ('DAY','Day','time'),
  ('WEE','Week','time'),
  ('MON','Month','time'),
  ('ANN','Year','time'),
  ('KWH','Kilowatt hour','energy'),
  ('E48','Service unit','service'),
  ('P1','Percent','other'),
  ('LM','Linear metre','length')
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- Currencies (ISO 4217 subset)
-- ---------------------------------------------------------------------
insert into public.ref_currencies (code, name, symbol, decimal_places) values
  ('MYR','Malaysian Ringgit','RM',2),
  ('USD','US Dollar','$',2),
  ('SGD','Singapore Dollar','S$',2),
  ('EUR','Euro','EUR',2),
  ('GBP','Pound Sterling','GBP',2),
  ('JPY','Japanese Yen','JPY',0),
  ('CNY','Chinese Yuan Renminbi','CNY',2),
  ('HKD','Hong Kong Dollar','HK$',2),
  ('TWD','New Taiwan Dollar','NT$',2),
  ('KRW','South Korean Won','KRW',0),
  ('AUD','Australian Dollar','A$',2),
  ('NZD','New Zealand Dollar','NZ$',2),
  ('CAD','Canadian Dollar','C$',2),
  ('CHF','Swiss Franc','CHF',2),
  ('THB','Thai Baht','THB',2),
  ('IDR','Indonesian Rupiah','Rp',2),
  ('PHP','Philippine Peso','PHP',2),
  ('VND','Vietnamese Dong','VND',0),
  ('BND','Brunei Dollar','B$',2),
  ('INR','Indian Rupee','INR',2),
  ('AED','UAE Dirham','AED',2),
  ('SAR','Saudi Riyal','SAR',2)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- Common tax exemption reasons
-- ---------------------------------------------------------------------
insert into public.ref_exemption_reasons (code, description) values
  ('EX01','Exempted under Sales Tax (Persons Exempted From Payment Of Tax) Order'),
  ('EX02','Exempted under Service Tax (Persons Exempted From Payment Of Tax) Order'),
  ('EX03','Zero-rated / exported goods and services'),
  ('EX04','Supply to Designated Area / Special Area'),
  ('EX05','Approved Manufacturer / Trader Scheme'),
  ('EX06','Not subject to tax'),
  ('EX99','Other exemption (specify)')
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- MSIC 2008 (representative subset; the full list can be loaded later)
-- ---------------------------------------------------------------------
insert into public.ref_msic_codes (code, description, category) values
  ('01111','Growing of maize','Agriculture'),
  ('01261','Growing of oil palm (estate)','Agriculture'),
  ('02100','Silviculture and other forestry activities','Forestry'),
  ('03111','Marine fishing','Fishing'),
  ('05100','Mining of hard coal','Mining'),
  ('06100','Extraction of crude petroleum','Mining'),
  ('10710','Manufacture of bakery products','Manufacturing'),
  ('13110','Preparation and spinning of textile fibres','Manufacturing'),
  ('16101','Sawmilling and planing of wood','Manufacturing'),
  ('22201','Manufacture of plastic products','Manufacturing'),
  ('25111','Manufacture of structural metal products','Manufacturing'),
  ('26201','Manufacture of computers and peripheral equipment','Manufacturing'),
  ('31001','Manufacture of furniture','Manufacturing'),
  ('35101','Electric power generation','Utilities'),
  ('36001','Water collection, treatment and supply','Utilities'),
  ('41001','Construction of buildings','Construction'),
  ('42101','Construction of roads and railways','Construction'),
  ('43210','Electrical installation','Construction'),
  ('45101','Sale of motor vehicles','Wholesale & Retail'),
  ('46100','Wholesale on a fee or contract basis','Wholesale & Retail'),
  ('46900','Non-specialised wholesale trade','Wholesale & Retail'),
  ('47111','Retail sale in non-specialised stores (supermarket)','Wholesale & Retail'),
  ('47411','Retail sale of computers and software in specialised stores','Wholesale & Retail'),
  ('47911','Retail sale via internet','Wholesale & Retail'),
  ('49230','Freight transport by road','Transportation'),
  ('52100','Warehousing and storage','Transportation'),
  ('53100','Postal activities','Transportation'),
  ('55101','Hotels and resort hotels','Accommodation'),
  ('56103','Restaurants','Food & Beverage'),
  ('56210','Event catering','Food & Beverage'),
  ('58110','Book publishing','Information'),
  ('62010','Computer programming activities','Information & Communication'),
  ('62021','Information technology consultancy','Information & Communication'),
  ('62090','Other information technology and computer service activities','Information & Communication'),
  ('63111','Data processing, hosting and related activities','Information & Communication'),
  ('64191','Commercial banks','Finance'),
  ('65120','Non-life insurance','Finance'),
  ('68101','Buying and selling of own real estate','Real Estate'),
  ('68200','Renting and operating of self-owned or leased real estate','Real Estate'),
  ('69100','Legal activities','Professional Services'),
  ('69200','Accounting, bookkeeping and auditing activities; tax consultancy','Professional Services'),
  ('70200','Management consultancy activities','Professional Services'),
  ('71101','Architectural and engineering activities','Professional Services'),
  ('73100','Advertising','Professional Services'),
  ('74101','Specialised design activities','Professional Services'),
  ('77101','Renting and leasing of motor vehicles','Administrative Services'),
  ('78100','Activities of employment placement agencies','Administrative Services'),
  ('79110','Travel agency activities','Administrative Services'),
  ('81210','General cleaning of buildings','Administrative Services'),
  ('82110','Combined office administrative service activities','Administrative Services'),
  ('85101','Pre-primary education','Education'),
  ('85499','Other education n.e.c.','Education'),
  ('86201','Medical practice activities','Health'),
  ('86909','Other human health activities','Health'),
  ('90001','Performing arts','Arts & Recreation'),
  ('93110','Operation of sports facilities','Arts & Recreation'),
  ('95110','Repair of computers and peripheral equipment','Other Services'),
  ('96011','Laundry and dry-cleaning services','Other Services'),
  ('96021','Hairdressing and other beauty treatment','Other Services'),
  ('00000','Not applicable','Other')
on conflict (code) do nothing;
