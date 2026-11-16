import 'dart:async';
import 'dart:convert';

class SseEvent {
  const SseEvent(this.event, this.data);

  final String event;
  final String data;
}

/// Minimal Server-Sent Events parser (event + data fields; comments ignored).
class SseParser extends StreamTransformerBase<String, SseEvent> {
  const SseParser();

  @override
  Stream<SseEvent> bind(Stream<String> stream) async* {
    var event = 'message';
    final data = StringBuffer();
    var hasData = false;
    await for (final line in stream.transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (hasData) yield SseEvent(event, data.toString());
        event = 'message';
        data.clear();
        hasData = false;
        continue;
      }
      if (line.startsWith(':')) continue;
      final colon = line.indexOf(':');
      final field = colon < 0 ? line : line.substring(0, colon);
      var value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      if (field == 'event') {
        event = value;
      } else if (field == 'data') {
        if (hasData) data.write('\n');
        data.write(value);
        hasData = true;
      }
    }
    if (hasData) yield SseEvent(event, data.toString());
  }
}
