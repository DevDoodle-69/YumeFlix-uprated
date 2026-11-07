import 'package:flutter_test/flutter_test.dart';
import 'package:yumeflix/core/extensions/default_extension_selector.dart';

void main() {
  group('preferred4kHdProviderId', () {
    test('selects an installed provider whose name is exactly 4K HD', () {
      expect(
        preferred4kHdProviderId([
          (packageName: 'vendor.4k', name: ' 4K HD ', isDebug: false),
          (packageName: 'vendor.other', name: 'Cinema', isDebug: false),
        ]),
        'vendor.4k',
      );
    });

    test('does not choose a debug-only or differently named provider', () {
      expect(
        preferred4kHdProviderId([
          (packageName: 'local.4k.debug', name: '4K HD', isDebug: true),
          (packageName: 'vendor.hub', name: '4K HD Hub', isDebug: false),
          (packageName: 'vendor.hd', name: 'HD 4K', isDebug: false),
        ]),
        isNull,
      );
    });

    test('chooses duplicate exact-name providers by stable package ID', () {
      expect(
        preferred4kHdProviderId([
          (packageName: 'z.vendor', name: '4K HD', isDebug: false),
          (packageName: 'a.vendor', name: '4K HD', isDebug: false),
        ]),
        'a.vendor',
      );
    });

    test(
      'never overrides a previously saved provider choice or explicit None',
      () {
        expect(
          preferred4kHdProviderId([
            (packageName: 'vendor.4k', name: '4K HD', isDebug: false),
          ], hasSavedSelection: true),
          isNull,
        );
      },
    );
  });
}
