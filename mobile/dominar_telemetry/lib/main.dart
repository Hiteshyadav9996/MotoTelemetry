import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'services/telemetry_service.dart';
import 'theme/dashboard_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const DominarTelemetryApp());
}

class DominarTelemetryApp extends StatelessWidget {
  const DominarTelemetryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => TelemetryService()..init(),
      child: MaterialApp(
        title: 'Dominar TFT',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: DashboardTheme.bg,
          fontFamily: 'Inter',
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
