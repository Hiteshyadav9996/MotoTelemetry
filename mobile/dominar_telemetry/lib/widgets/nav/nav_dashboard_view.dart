import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/telemetry.dart';
import '../../services/navigation_session_service.dart';
import '../../theme/dashboard_theme.dart';
import '../navigation/map_navigation_panel.dart';
import 'nav_drive_readout.dart';
import '../compact/rpm_vertical_bar.dart';

/// Page 2: RPM | Google Map | speed/gear.
///
/// Critical: the map is NEVER inside a [FittedBox]. Platform views
/// (Google Navigation) break under transforms — native header/footer/recenter
/// will not work correctly if the map is scaled.
class NavDashboardView extends StatefulWidget {
  const NavDashboardView({
    super.key,
    required this.telemetry,
    this.fullscreenNav = false,
    this.onToggleFullscreen,
  });

  final Telemetry telemetry;
  final bool fullscreenNav;
  final ValueChanged<bool>? onToggleFullscreen;

  @override
  State<NavDashboardView> createState() => _NavDashboardViewState();
}

class _NavDashboardViewState extends State<NavDashboardView> {
  /// Stable identity so the Google Maps platform view is not destroyed when
  /// side panels hide/show.
  final GlobalKey _mapPanelKey = GlobalKey();
  StreamSubscription<NavigationSessionState>? _navSub;
  NavigationSessionState _navState = NavigationSessionState.uninitialized;

  bool get _tripActive =>
      _navState == NavigationSessionState.routeReady ||
      _navState == NavigationSessionState.navigating;

  @override
  void initState() {
    super.initState();
    _navState = NavigationSessionService().state;
    _navSub = NavigationSessionService().stateChanges.listen((state) {
      if (!mounted) return;
      setState(() => _navState = state);
    });
  }

  @override
  void dispose() {
    _navSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final immersive = widget.fullscreenNav;

    return ColoredBox(
      color: DashboardTheme.bg,
      child: SafeArea(
        top: false,
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            // During an active trip, give the map more width so Google native
            // header/footer fit, while keeping RPM and speed visible.
            final rpmFraction = _tripActive ? 0.14 : 0.188;
            final driveFraction = _tripActive ? 0.22 : 0.28;
            final rpmW =
                immersive ? 0.0 : (w * rpmFraction).clamp(96.0, 180.0);
            final driveW =
                immersive ? 0.0 : (w * driveFraction).clamp(120.0, 220.0);

            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!immersive)
                  SizedBox(
                    width: rpmW,
                    child: RpmVerticalBar(
                      rpm: widget.telemetry.rpm,
                      engineTemp: widget.telemetry.engineTempC ?? 90,
                    ),
                  ),
                Expanded(
                  child: MapNavigationPanel(
                    key: _mapPanelKey,
                    layout: MapPanelLayout.navDashboard,
                    fullscreenNav: immersive,
                    onFullscreenNavChanged: widget.onToggleFullscreen,
                  ),
                ),
                if (!immersive)
                  SizedBox(
                    width: driveW,
                    child: NavDriveReadout(telemetry: widget.telemetry),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
