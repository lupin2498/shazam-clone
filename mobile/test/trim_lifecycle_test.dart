// "Chọn đoạn nhạc": leaving the screen or a failing native call must not leave sound playing
// or the screen stuck.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:tim_nhac/screens/trim_screen.dart';
import 'package:tim_nhac/services/app_services.dart';
import 'package:tim_nhac/services/native_bridge.dart';

import 'fakes.dart';

const _file = PickedFile(uri: 'content://x/1', name: 'song.mp3');

Future<http.Response> _backend(http.Request r) async => jsonResponse(recognitionJson());

/// Home route with a button that opens the trim screen, so the test can go back.
Future<void> _openTrim(WidgetTester tester, AppServices s) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppScope(
    services: s,
    child: MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => const TrimScreen(file: _file))),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.text('Nghe thử'), findsOneWidget);
}

void main() {
  testWidgets('leaving while the preview is starting stops the sound', (tester) async {
    final native = FakeNative()..previewGate = Completer<bool>();
    final s = await fakeServices(native: native, handler: _backend);
    await _openTrim(tester, s);

    await tester.tap(find.text('Nghe thử'));
    await tester.pump();
    expect(native.calls, contains('previewPlay'));

    // Back before the platform answered: the screen is gone, the player is about to start.
    Navigator.of(tester.element(find.text('Nghe thử'))).pop();
    await tester.pumpAndSettle();
    native.previewGate!.complete(true);
    await tester.pumpAndSettle();

    expect(native.calls.where((c) => c == 'previewStop'), isNotEmpty,
        reason: 'nothing else would stop the preview: it keeps playing with no screen');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failing previewStop does not block "Nhận diện đoạn này"', (tester) async {
    final native = FakeNative();
    final s = await fakeServices(native: native, handler: _backend);
    await _openTrim(tester, s);

    await tester.tap(find.text('Nghe thử'));
    await tester.pump();
    expect(find.text('Dừng'), findsOneWidget);

    native.previewStopError = PlatformException(code: 'native_error', message: 'player gone');
    await tester.tap(find.text('Nhận diện đoạn này'));
    await tester.pumpAndSettle();

    expect(native.calls.where((c) => c.startsWith('segment:')), isNotEmpty,
        reason: 'the segment must still be sent');
    expect(tester.takeException(), isNull);
  });

  testWidgets('stopping the preview with a failing platform call does not keep "Dừng"', (tester) async {
    final native = FakeNative();
    final s = await fakeServices(native: native, handler: _backend);
    await _openTrim(tester, s);

    await tester.tap(find.text('Nghe thử'));
    await tester.pump();
    native.previewStopError = PlatformException(code: 'native_error');
    await tester.tap(find.text('Dừng'));
    await tester.pump();

    expect(find.text('Nghe thử'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
