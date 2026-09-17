import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/settings/module_offer.dart';

/// "Contact us to add one of these."
///
/// That sentence was the whole of the path to a paid module: no
/// address, no form, nothing that reached anybody, while every add-on
/// in the catalogue carried a monthly price. 0488 lets an owner or
/// admin add one themselves, and these assert the words that go with
/// it — because the words are about money, and money said late is a
/// complaint rather than a sale.
void main() {
  ModuleSurface module(String name, double price) => ModuleSurface(
    code: 'x',
    name: name,
    isCore: false,
    monthlyPrice: price,
    entitled: false,
    hidden: false,
    visible: false,
  );

  group('the line under the list', () {
    test('somebody who may add one is told when the charge starts', () {
      final line = moduleOfferLine(canAdmin: true);
      expect(line, contains('on straight away'));
      expect(line, contains('from the day you add it'));
      // And that it is reversible, because a charge somebody believes
      // is permanent is a charge they will not risk.
      expect(line, contains('take it off'));
    });

    test('somebody who may not is told who can, not to press it', () {
      expect(moduleOfferLine(canAdmin: false), 'An owner or admin can add these.');
    });

    test('the dead end is gone', () {
      expect(moduleOfferLine(canAdmin: true), isNot(contains('Contact us')));
      expect(moduleOfferLine(canAdmin: false), isNot(contains('Contact us')));
    });
  });

  group('the chip', () {
    test('carries the price', () {
      expect(
        moduleChipLabel(module('Multi-Company', 39)),
        'Multi-Company · RM 39.00/mo',
      );
    });

    test('and a free one is not priced at nothing', () {
      // "RM 0.00/mo" reads like a mistake rather than like free.
      expect(moduleChipLabel(module('Attachments', 0)), 'Attachments');
    });
  });

  group('the confirmation', () {
    test('names the module', () {
      expect(addModuleTitle(module('Loyalty & Points', 29)),
          'Add Loyalty & Points?');
    });

    test('says the price before it is added, not after', () {
      final prompt = addModulePrompt(module('Loyalty & Points', 29));
      expect(prompt, contains('RM 29.00 a month'));
      expect(prompt, contains('from today'));
      expect(prompt, contains('take it off'));
    });

    test('and says nothing about money when there is none', () {
      final prompt = addModulePrompt(module('Attachments', 0));
      expect(prompt, isNot(contains('RM')));
      expect(prompt, contains('on straight away'));
    });
  });
}
