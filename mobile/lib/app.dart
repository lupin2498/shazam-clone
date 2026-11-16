import 'package:material_ui/material_ui.dart';

import 'l10n/strings.dart';
import 'screens/home_screen.dart';
import 'services/app_services.dart';

const _seed = Color(0xFF3D5AFE);

class TimNhacApp extends StatelessWidget {
  const TimNhacApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      services: services,
      child: MaterialApp(
        title: S.appName,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: _seed)),
        darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark)),
        home: const HomeScreen(),
      ),
    );
  }
}
