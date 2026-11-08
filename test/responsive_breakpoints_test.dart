import 'package:flutter_test/flutter_test.dart';
import 'package:yumeflix/core/utils/responsive_breakpoints.dart';

/// 2.9.0 responsiveness pass: the one rule every grid follows for its
/// column count, and the page inset / centred-column widths, live in
/// [ResponsiveBreakpoints] instead of being re-derived per screen.
void main() {
  group('gridColumnsForWidth', () {
    test('phone width -> poster columns', () {
      expect(
        ResponsiveBreakpoints.gridColumnsForWidth(390, minItemWidth: 150),
        3,
      );
      expect(
        ResponsiveBreakpoints.gridColumnsForWidth(360, minItemWidth: 150),
        3,
      );
    });

    test('tablet and desktop widths gain columns', () {
      expect(
        ResponsiveBreakpoints.gridColumnsForWidth(800, minItemWidth: 150),
        6,
      );
      expect(
        ResponsiveBreakpoints.gridColumnsForWidth(1280, minItemWidth: 200),
        7,
      );
    });

    test('episode grids: 480 dp cards, capped at 5', () {
      expect(
        ResponsiveBreakpoints.gridColumnsForWidth(
          390,
          minItemWidth: 480,
          maxColumns: 5,
        ),
        1,
      );
      expect(
        ResponsiveBreakpoints.gridColumnsForWidth(
          2560,
          minItemWidth: 480,
          maxColumns: 5,
        ),
        5,
      );
    });

    test('degenerate widths never return zero columns', () {
      expect(
        ResponsiveBreakpoints.gridColumnsForWidth(0, minItemWidth: 150),
        1,
      );
      expect(
        ResponsiveBreakpoints.gridColumnsForWidth(390, minItemWidth: 0),
        1,
      );
    });
  });

  group('pagePaddingForWidth / maxContentWidthForWidth', () {
    test('inset steps with width', () {
      expect(ResponsiveBreakpoints.pagePaddingForWidth(390), 16);
      expect(ResponsiveBreakpoints.pagePaddingForWidth(700), 20);
      expect(ResponsiveBreakpoints.pagePaddingForWidth(1000), 24);
    });

    test('phones span the screen; wider screens centre at 800', () {
      expect(ResponsiveBreakpoints.maxContentWidthForWidth(390), isNull);
      expect(ResponsiveBreakpoints.maxContentWidthForWidth(800), 800);
      expect(ResponsiveBreakpoints.maxContentWidthForWidth(1280), 800);
    });
  });
}
