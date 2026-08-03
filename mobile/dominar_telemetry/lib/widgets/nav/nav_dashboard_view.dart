import 'package:flutter/material.dart';

import '../../models/telemetry.dart';
import '../../theme/dashboard_theme.dart';
import '../navigation/map_navigation_panel.dart';
import 'nav_drive_readout.dart';
import '../compact/rpm_vertical_bar.dart';

/// Three-column navigation dashboard: RPM bar | map | drive readout.
class NavDashboardView extends StatelessWidget {
  const NavDashboardView({super.key, required this.telemetry});

  final Telemetry telemetry;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => FittedBox(
        fit: BoxFit.fill,
        child: Container(
          width: 896,
          height: 414,
          decoration: DashboardTheme.screenBackground,
          child: Row(
            children: [
              SizedBox(
                width: 168,
                child: RpmVerticalBar(
                  rpm: telemetry.rpm,
                  engineTemp: telemetry.engineTempC ?? 90,
                ),
              ),
              const Expanded(
                flex: 2,
                child: MapNavigationPanel(
                  layout: MapPanelLayout.navDashboard,
                ),
              ),
              Expanded(
                flex: 1,
                child: NavDriveReadout(telemetry: telemetry),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
