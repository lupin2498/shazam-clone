// End-to-end check of the platform channels (MainActivity.kt on Android, NativeBridge.swift
// on iOS) on a device, emulator or simulator:
//
//   flutter test integration_test/native_bridge_test.dart -d <device id>
//
// Everything that needs no user interaction is covered: file probing, waveform, cutting and
// AAC encoding, preview playback, connectivity, permissions and, when the microphone
// permission has been granted beforehand, a short capture.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tim_nhac/services/native_bridge.dart';

const _adtsRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];

/// Duration of an ADTS stream, computed like `adts_duration()` in backend/app/audio.py.
double adtsSeconds(Uint8List data) {
  var pos = 0;
  var frames = 0;
  int? rate;
  while (pos + 7 <= data.length) {
    expect(data[pos], 0xFF, reason: 'ADTS sync byte at $pos');
    expect(data[pos + 1] & 0xF6, 0xF0, reason: 'ADTS sync bits at $pos');
    rate ??= _adtsRates[(data[pos + 2] >> 2) & 0x0F];
    final length = ((data[pos + 3] & 0x03) << 11) | (data[pos + 4] << 3) | (data[pos + 5] >> 5);
    expect(length, greaterThanOrEqualTo(7), reason: 'ADTS frame length at $pos');
    frames += (data[pos + 6] & 0x03) + 1;
    pos += length;
  }
  expect(pos, data.length, reason: 'bytes left after the last ADTS frame');
  expect(frames, greaterThan(0));
  return frames * 1024 / rate!;
}

/// 16-bit mono WAV: [silentSeconds] of silence, then a 440 Hz tone with peak 16000.
Uint8List wavTone({required double seconds, double silentSeconds = 0, int rate = 22050}) {
  final silent = (silentSeconds * rate).round();
  final total = silent + (seconds * rate).round();
  final bytes = ByteData(44 + total * 2);
  void ascii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      bytes.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + total * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, rate, Endian.little);
  bytes.setUint32(28, rate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, total * 2, Endian.little);
  for (var i = silent; i < total; i++) {
    bytes.setInt16(44 + i * 2, (16000 * sin(2 * pi * 440 * i / rate)).round(), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final native = MethodChannelNativeBridge();
  late Directory folder;
  late String toneUri;

  setUpAll(() async {
    folder = await Directory.systemTemp.createTemp('native_bridge_test');
    final tone = File('${folder.path}/tone.wav');
    await tone.writeAsBytes(wavTone(silentSeconds: 2, seconds: 3));
    toneUri = Uri.file(tone.path).toString();
  });

  tearDownAll(() async {
    await native.previewStop();
    await native.cancelRecording();
    await folder.delete(recursive: true);
  });

  testWidgets('probe reports duration and name', (tester) async {
    final probe = await native.probeAudio(toneUri);
    expect(probe.durationMs, closeTo(5000, 60));
    expect(probe.name, 'tone.wav');
  });

  testWidgets('waveform has one peak per bucket', (tester) async {
    final peaks = await native.audioWaveform(toneUri, buckets: 50);
    expect(peaks, hasLength(50));
    expect(peaks.every((p) => p >= 0 && p <= 1), isTrue);
    // Silence for the first 2 of 5 seconds, then a tone peaking at 16000 / 32768.
    expect(peaks[5], lessThan(0.02));
    expect(peaks[40], closeTo(0.49, 0.08));
  });

  testWidgets('a segment is cut and encoded as ADTS AAC', (tester) async {
    final sample = await native.encodeSegment(toneUri, startMs: 2500, durationMs: 2000);
    expect(sample.durationMs, closeTo(2000, 60));
    expect(sample.rms, closeTo(16000 / 32768 / sqrt2, 0.04));
    // The backend rejects samples longer than the 15 s limit plus half a second.
    expect(adtsSeconds(sample.aac), closeTo(2.0, 0.25));
    // 64 kbps: about 8 kB per second.
    expect(sample.aac.length, inInclusiveRange(6000, 26000));
  });

  testWidgets('a silent segment is reported as silent, not as an error', (tester) async {
    final sample = await native.encodeSegment(toneUri, startMs: 0, durationMs: 1500);
    expect(sample.rms, lessThan(0.005));
    expect(sample.durationMs, closeTo(1500, 60));
  });

  testWidgets('a segment past the end of the file is empty or short', (tester) async {
    final sample = await native.encodeSegment(toneUri, startMs: 4500, durationMs: 12000);
    expect(sample.durationMs, lessThanOrEqualTo(600));
    if (sample.aac.isNotEmpty) expect(adtsSeconds(sample.aac), lessThan(1.0));
  });

  testWidgets('a file without audio is an error', (tester) async {
    final text = File('${folder.path}/notes.txt');
    await text.writeAsString('không phải âm thanh');
    final uri = Uri.file(text.path).toString();
    await expectLater(native.probeAudio(uri), throwsA(isA<PlatformException>()));
    await expectLater(native.encodeSegment(uri, startMs: 0, durationMs: 1000), throwsA(isA<PlatformException>()));
  });

  testWidgets('preview playback starts and stops', (tester) async {
    expect(await native.previewPlay(toneUri, startMs: 2000, durationMs: 400), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await native.previewStop();
  });

  testWidgets('connectivity and environment queries answer', (tester) async {
    expect(await native.isOnline(), isA<bool>());
    expect(await native.shouldShowMicRationale(), isA<bool>());
    final installed = await native.installedPackages(['com.spotify.music', 'vn.timnhac.no.such.app']);
    expect(installed, isNot(contains('vn.timnhac.no.such.app')));
    // Play Integrity is only prepared with a real Google Cloud project number.
    expect(await native.integrityPrepare(''), isFalse);
    expect(await native.integrityToken('0' * 64), isNull);
    if (await native.isOnline()) {
      expect(await native.connectivity.first.timeout(const Duration(seconds: 10)), isTrue);
    }
    final shared = native.sharedFiles.listen((_) {});
    await shared.cancel();
  });

  testWidgets('background capture, notifications and Google answer on every platform', (tester) async {
    // Android 10+ can capture other apps; iOS cannot.
    expect(await native.playbackCaptureSupported(), Platform.isAndroid);
    final taps = native.notificationTaps.listen((_) {});
    await taps.cancel();
    await native.notify('Tìm Nhạc', 'Kiểm tra thông báo', historyId: 1);
    await native.finishBackgroundTask();
    // Nobody is signed in: a silent request needs the user, or Google is not set up here
    // (no Play services on the emulator image, no iOS client id in this build).
    try {
      final auth = await native.googleAuthorize(interactive: false).timeout(const Duration(seconds: 30));
      expect(auth, isNull);
    } on PlatformException catch (e) {
      expect(e.code, isIn(['not_configured', 'google_error', 'network']));
    }
    await native.googleSignOut();
  });

  testWidgets('microphone capture, or a permission error without the permission', (tester) async {
    if (!await native.hasMicPermission()) {
      await expectLater(
        native.startRecording(maxSeconds: 3),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'permission')),
      );
      return;
    }
    final levels = <double>[];
    final sub = native.levels.listen(levels.add);
    final started = await native.startRecording(maxSeconds: 3);
    if (!started) {
      // No input device (CI machines): reported as "microphone busy", never a crash.
      await sub.cancel();
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final early = await native.snapshotRecording(maxMs: 1000);
    expect(early.durationMs, inInclusiveRange(300, 1000));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final full = await native.stopRecording();
    await sub.cancel();
    expect(full.durationMs, inInclusiveRange(800, 3000));
    expect(adtsSeconds(full.aac), closeTo(full.durationMs / 1000, 0.3));
    expect(levels, isNotEmpty);
    expect(levels.every((l) => l >= 0 && l <= 1), isTrue);
    // A second stop returns the same recording; cancel discards it.
    await native.cancelRecording();
    expect((await native.stopRecording()).durationMs, 0);
  });
}
