import 'package:flutter/widgets.dart';

import 'app.dart';
import 'services/app_services.dart';
import 'services/native_bridge.dart';
import 'services/playback_recognition.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await AppServices.create();
  runApp(TimNhacApp(services: services));
}

/// Started by PlaybackCaptureService (Android 10+) in a headless engine: recognises the music
/// other apps are playing and reports it as a notification (lib/services/playback_recognition.dart).
@pragma('vm:entry-point')
Future<void> playbackCaptureMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await playbackCaptureEntry(MethodChannelNativeBridge());
}
