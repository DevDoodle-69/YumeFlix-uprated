import 'package:flutter/material.dart';

enum DeviceScreenType { mobile, tablet, desktop }

class ResponsiveBreakpoints {
  static const double tabletBreakpoint = 600;
  static const double desktopBreakpoint = 900;

  static DeviceScreenType getDeviceType(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;

    if (width >= desktopBreakpoint) {
      return DeviceScreenType.desktop;
    } else if (width >= tabletBreakpoint) {
      return DeviceScreenType.tablet;
    } else {
      return DeviceScreenType.mobile;
    }
  }

  static bool isMobile(BuildContext context) =>
      getDeviceType(context) == DeviceScreenType.mobile;

  static bool isTablet(BuildContext context) =>
      getDeviceType(context) == DeviceScreenType.tablet;

  static bool isDesktop(BuildContext context) =>
      getDeviceType(context) == DeviceScreenType.desktop;

  static bool isTabletOrLarger(BuildContext context) =>
      getDeviceType(context) != DeviceScreenType.mobile;

  /// How many columns a grid gets at [width], from the narrowest item it
  /// may show — the one rule every grid in the app follows, instead of
  /// each screen re-deriving its own count. [minItemWidth] is the
  /// narrowest usable card; [maxColumns] caps the count so an ultra-wide
  /// window does not stretch into unreadable columns. Identical to the
  /// `(width / minItemWidth).ceil()` each grid used to compute inline.
  static int gridColumnsForWidth(
    double width, {
    required double minItemWidth,
    int maxColumns = 12,
  }) {
    if (width <= 0 || minItemWidth <= 0) return 1;
    return (width / minItemWidth).ceil().clamp(1, maxColumns);
  }

  /// Horizontal page inset for [width]: phone 16, tablet 20, desktop 24 —
  /// the same step the settings screens' centred columns use.
  static double pagePaddingForWidth(double width) =>
      width >= desktopBreakpoint
      ? 24
      : width >= tabletBreakpoint
      ? 20
      : 16;

  /// The widest a centred reading column may get at [width], or null on a
  /// phone where content spans the screen. Tablet and desktop centre at
  /// 800, the width the settings screens already use inline.
  static double? maxContentWidthForWidth(double width) =>
      width >= tabletBreakpoint ? 800 : null;
}

extension ResponsiveContext on BuildContext {
  DeviceScreenType get deviceType => ResponsiveBreakpoints.getDeviceType(this);
  bool get isMobile => ResponsiveBreakpoints.isMobile(this);
  bool get isTablet => ResponsiveBreakpoints.isTablet(this);
  bool get isDesktop => ResponsiveBreakpoints.isDesktop(this);
  bool get isTabletOrLarger => ResponsiveBreakpoints.isTabletOrLarger(this);

  /// Whether this surface is being driven by directional focus movement - a
  /// remote, a D-pad, a gamepad stick - rather than by a pointer.
  ///
  /// This is an input model declared by the host through
  /// [MediaQueryData.navigationMode], not a device class: [DeviceProfile.isTv]
  /// is the single authority for "is this a television". Nothing in this app
  /// declares directional navigation and Flutter's default is
  /// [NavigationMode.traditional], so on a real Android TV this getter is
  /// false. Ask [DeviceProfile.isTv] for the device and a breakpoint above for
  /// the size.
  bool get isDirectionalNavigation =>
      MediaQuery.maybeNavigationModeOf(this) == NavigationMode.directional;
}
