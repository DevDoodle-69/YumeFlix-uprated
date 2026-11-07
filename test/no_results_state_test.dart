import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yumeflix/l10n/generated/app_localizations.dart';
import 'package:yumeflix/shared/widgets/no_results_state.dart';

void main() {
  testWidgets('renders localized no-results artwork without phone overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 480);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: NoResultsState()),
      ),
    );
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(NoResultsState));
    expect(
      find.text(AppLocalizations.of(context)!.noResultsFound),
      findsOneWidget,
    );
    final artwork = tester.widget<Image>(find.byType(Image));
    expect(artwork.image, isA<ResizeImage>());
    final resized = artwork.image as ResizeImage;
    expect(resized.imageProvider, isA<AssetImage>());
    expect(
      (resized.imageProvider as AssetImage).assetName,
      'assets/images/no_results.png',
    );
    expect(tester.takeException(), isNull);
  });
}
