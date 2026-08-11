import 'dart:convert';

import 'package:flutter/material.dart' show DateTimeRange;
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/pdf_kit.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/reports/report_pdf.dart';
import 'package:iakauntan/src/features/reports/report_spec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final org = Organization(
    id: 'o1',
    name: 'Sinar Teknologi Sdn Bhd',
    slug: 'sinar',
    registrationNo: '202301004567',
    sstRegistrationNo: 'W10-1808-32000123',
    isSstRegistered: true,
    addressLine1: 'Level 12, Menara Sinar',
    city: 'Kuala Lumpur',
  );

  final range = DateTimeRange(
    start: DateTime(2026, 1, 1),
    end: DateTime(2026, 8, 11),
  );
  final generatedAt = DateTime(2026, 8, 11, 14, 30);

  final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
      'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

  final pl = profitLossSpec([
    {
      'code': '4000',
      'name': 'Sales',
      'account_type': 'revenue',
      'amount': 100000.0,
    },
    {
      'code': '6000',
      'name': 'Salaries',
      'account_type': 'expense',
      'amount': 25000.0,
    },
  ], range);

  test('every report shape renders', () async {
    final specs = [
      pl,
      balanceSheetSpec([
        {'code': '1000', 'name': 'Bank', 'account_type': 'asset', 'balance': 5.0}
      ], range.end),
      trialBalanceSpec([
        {
          'code': '1000',
          'name': 'Bank',
          'debit': 500.0,
          'credit': 0.0,
          'closing_balance': 500.0,
        }
      ]),
      sstSummarySpec([
        {
          'direction': 'output',
          'tax_type_code': 'SV',
          'tax_type_name': 'Service tax',
          'taxable_amount': 1000.0,
          'tax_amount': 80.0,
        }
      ], range),
    ];

    for (final spec in specs) {
      final bytes = await buildReportPdf(
          org: org, spec: spec, generatedAt: generatedAt);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-',
          reason: '${spec.title} should build');
      expect(
          String.fromCharCodes(bytes.skip(bytes.length - 6)).trim(), '%%EOF');
    }
  });

  test('a report with no rows at all still renders', () async {
    // The empty SST summary has two grids with nothing in them, which is
    // the case a table helper throws on if it is handed no data.
    final bytes = await buildReportPdf(
        org: org,
        spec: sstSummarySpec(const [], range),
        generatedAt: generatedAt);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('the logo is carried', () async {
    final without =
        await buildReportPdf(org: org, spec: pl, generatedAt: generatedAt);
    final with_ = await buildReportPdf(
        org: org, spec: pl, generatedAt: generatedAt, logo: png);
    expect(with_.length, greaterThan(without.length));
  });

  test('pre-printed stationery drops the block, not the numbers', () async {
    final printed =
        await buildReportPdf(org: org, spec: pl, generatedAt: generatedAt);
    final onPaper = await buildReportPdf(
        org: org,
        spec: pl,
        generatedAt: generatedAt,
        mode: LetterheadMode.stationery);
    expect(onPaper.length, lessThan(printed.length));

    final anonymous = await buildReportPdf(
      org: Organization(id: 'o', name: 'Bare Sdn Bhd', slug: 'bare'),
      spec: pl,
      generatedAt: generatedAt,
      mode: LetterheadMode.stationery,
    );
    expect(onPaper.length, greaterThan(anonymous.length));
  });
}
