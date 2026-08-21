import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/telemetry.dart';
import '../services/navigation_session_service.dart';
import '../services/telemetry_service.dart';
import '../theme/dashboard_theme.dart';
import '../widgets/full/full_dashboard.dart';
import '../widgets/nav/nav_dashboard_view.dart';

/// Swipe horizontally between full dashboard and compact+maps split view.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final PageController _pageController;
  int _pageIndex = 0;
  StreamSubscription<NavigationSessionState>? _navSub;
  NavigationSessionState _navState = NavigationSessionState.uninitialized;

  @override
  void initState() {
    super.initState();
    final initialPage = Uri.base.queryParameters['page'] == 'nav' ? 1 : 0;
    _pageIndex = initialPage;
    _pageController = PageController(initialPage: initialPage);
    _navState = NavigationSessionService().state;
    _navSub = NavigationSessionService().stateChanges.listen((state) {
      if (!mounted) return;
      setState(() => _navState = state);
    });
  }

  @override
  void dispose() {
    _navSub?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Do not watch telemetry here — that rebuilt Google Maps + both pages
    // at 20 Hz and caused UI jank while packets still arrived on time.
    final hideLinkDot = _pageIndex == 1 &&
        (_navState == NavigationSessionState.routeReady ||
            _navState == NavigationSessionState.navigating);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: DashboardTheme.bg,
      body: Stack(
        children: [
          PageView(
            controller: _pageController,
            allowImplicitScrolling: false,
            onPageChanged: (index) => setState(() => _pageIndex = index),
            children: const [
              _FullDashboardPage(),
              SplitNavigationView(),
            ],
          ),
          if (!hideLinkDot)
            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                left: false,
                bottom: false,
                minimum: const EdgeInsets.only(top: 2, right: 2),
                child: _LinkDotButton(
                  onOpenDetails: _showLinkDetails,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showLinkDetails(
      BuildContext context, TelemetryService service) async {
    final age = service.packetAgeMs;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DashboardTheme.screen2,
        title: const Text(
          'Link diagnostics',
          style: TextStyle(color: DashboardTheme.text, fontSize: 16),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _KpiRow('Status', service.status),
              _KpiRow('Packet age', age == null ? '—' : '${age}ms'),
              _KpiRow('Link gap', '${service.maxArrivalGapMs}ms'),
              _KpiRow('ESP gap', '${service.maxDeviceGapMs}ms'),
              _KpiRow('Burst', '${service.burstPackets}'),
              _KpiRow(
                'SSE skip',
                service.sseSkipped == null ? '—' : '${service.sseSkipped}',
              ),
              _KpiRow(
                'SSE drop',
                service.sseDropped == null ? '—' : '${service.sseDropped}',
              ),
              _KpiRow(
                'SoftAP STAs',
                service.softapStations == null
                    ? '—'
                    : '${service.softapStations}',
              ),
              _KpiRow('Bridge', service.bridgeUrl),
              const SizedBox(height: 8),
              Text(
                'USB tip: plug the ESP32 into the Lightning camera adapter. '
                'Settings → Ethernet should show 192.168.5.x. Keep phone Wi‑Fi '
                'on another hotspot (or cellular) for maps. Leave Router blank '
                'on Ethernet if Maps traffic dies.',
                style: TextStyle(
                  color: DashboardTheme.muted.withValues(alpha: 0.95),
                  fontSize: 11,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () async {
              await service.startRideLog();
              if (ctx.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Ride link log started')),
                );
              }
            },
            child: const Text('Start ride log'),
          ),
          TextButton(
            onPressed: () async {
              final result = await service.shareRideLinkLog();
              if (ctx.mounted && result == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('No link log to export yet')),
                );
              }
            },
            child: const Text('Share / Export'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _showSettings(context, service);
            },
            child: const Text('Settings'),
          ),
        ],
      ),
    );
  }

  Future<void> _showSettings(
      BuildContext context, TelemetryService service) async {
    final controller = TextEditingController(text: service.bridgeUrl);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DashboardTheme.screen2,
        title: const Text('Bridge settings',
            style: TextStyle(color: DashboardTheme.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              style: const TextStyle(color: DashboardTheme.text),
              decoration: const InputDecoration(
                labelText: 'ESP32 URL',
                hintText: 'http://192.168.5.1',
                labelStyle: TextStyle(color: DashboardTheme.muted),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Wired: USB Ethernet at http://192.168.5.1 (camera adapter). '
              'Join another phone hotspot or use cellular for Maps. If Ethernet '
              'steals internet, set Ethernet IP to Manual and leave Router blank. '
              'Wi-Fi fallback firmware still uses D400Telemetry at http://192.168.4.1.',
              style: TextStyle(
                color: DashboardTheme.muted.withValues(alpha: 0.95),
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              await service.setBridgeUrl(controller.text);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _FullDashboardPage extends StatelessWidget {
  const _FullDashboardPage();

  @override
  Widget build(BuildContext context) {
    final resetTrip = context.read<TelemetryService>().resetTrip;
    return Selector<TelemetryService, Telemetry>(
      selector: (_, service) => service.telemetry,
      builder: (_, telemetry, __) => FullDashboard(
        telemetry: telemetry,
        onTripReset: resetTrip,
      ),
    );
  }
}

class _LinkDotButton extends StatelessWidget {
  const _LinkDotButton({
    required this.onOpenDetails,
  });

  final void Function(BuildContext context, TelemetryService service)
      onOpenDetails;

  @override
  Widget build(BuildContext context) {
    return Selector<TelemetryService, (bool connected, bool degraded)>(
      selector: (_, service) => (service.connected, service.degraded),
      builder: (context, state, __) {
        final service = context.read<TelemetryService>();
        return _LinkDot(
          connected: state.$1,
          degraded: state.$2,
          onTap: () => onOpenDetails(context, service),
        );
      },
    );
  }
}

class _KpiRow extends StatelessWidget {
  const _KpiRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: TextStyle(
                color: DashboardTheme.muted.withValues(alpha: 0.95),
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: DashboardTheme.text,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkDot extends StatelessWidget {
  const _LinkDot({
    required this.connected,
    required this.degraded,
    required this.onTap,
  });

  final bool connected;
  final bool degraded;
  final VoidCallback onTap;

  Color get _color {
    if (!connected) return DashboardTheme.rpmHot;
    if (degraded) return const Color(0xFFFFC857);
    return const Color(0xFF35E36C);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 0, 4),
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _color,
            boxShadow: [
              BoxShadow(
                color: _color.withValues(alpha: 0.55),
                blurRadius: 6,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Three-column navigation dashboard: RPM tumbler, map, speed/gear/trip.
class SplitNavigationView extends StatefulWidget {
  const SplitNavigationView({super.key});

  @override
  State<SplitNavigationView> createState() => _SplitNavigationViewState();
}

class _SplitNavigationViewState extends State<SplitNavigationView> {
  bool _fullscreenNav = false;

  @override
  Widget build(BuildContext context) {
    return Selector<TelemetryService, Telemetry>(
      selector: (_, service) => service.telemetry,
      builder: (_, telemetry, __) => NavDashboardView(
        telemetry: telemetry,
        fullscreenNav: _fullscreenNav,
        onToggleFullscreen: (value) => setState(() => _fullscreenNav = value),
      ),
    );
  }
}
