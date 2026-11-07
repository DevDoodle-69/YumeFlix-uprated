import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yumeflix/features/home/presentation/home_onboarding_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('HomeOnboardingState', () {
    test('claims the extension guide only on the first visit', () async {
      expect(
        await HomeOnboardingState.claimExtensionGuideForFirstLaunch(),
        isTrue,
      );
      expect(
        await HomeOnboardingState.claimExtensionGuideForFirstLaunch(),
        isFalse,
      );
    });

    test('manual guide access marks it seen for future launches', () async {
      await HomeOnboardingState.markExtensionGuideSeen();

      expect(
        await HomeOnboardingState.claimExtensionGuideForFirstLaunch(),
        isFalse,
      );
    });
  });
}
