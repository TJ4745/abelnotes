import 'dart:async';

import 'package:flutter/foundation.dart';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

/// iPhone/iPad/Android by user agent, plus the iPad posing as a Mac: a
/// "Macintosh" with a multi-touch screen (no real Mac has one). A first
/// guess only — [noteWebTouchInput] settles it from real input.
bool _byUserAgent() {
  final nav = web.window.navigator;
  final ua = nav.userAgent;
  if (RegExp('iPad|iPhone|iPod|Android').hasMatch(ua)) return true;
  return ua.contains('Macintosh') && nav.maxTouchPoints > 1;
}

/// Listenable so the editor chrome can swap its mouse toggle for the
/// finger-draws one the moment the device turns out to be a tablet.
final ValueNotifier<bool> webTouchDevice = ValueNotifier(_byUserAgent());

bool get isWebTouchDevice => webTouchDevice.value;

/// A pen or a finger touched the page: this is a touch device, whatever the
/// user agent claimed.
void noteWebTouchInput() => webTouchDevice.value = true;

String webDeviceDiagnostics() {
  final nav = web.window.navigator;
  return 'ua="${nav.userAgent}" maxTouchPoints=${nav.maxTouchPoints} '
      'touchDevice=${webTouchDevice.value}';
}

/// Pen diagnostics, for bugs that only show on a real tablet. Turned on by
/// opening the app with `?diag=1` (remembered on this device) and off again
/// with `?diag=0`. It makes the crash log record every pointer event.
final bool webDiagnostics = () {
  const key = 'abelnotes_diag';
  final q = Uri.base.queryParameters['diag'];
  try {
    final store = web.window.localStorage;
    if (q == '1') store.setItem(key, '1');
    if (q == '0') store.removeItem(key);
    return store.getItem(key) == '1';
  } catch (_) {
    return q == '1';
  }
}();

/// Logs what the browser itself delivers — before Flutter sees anything —
/// so a lost pen-down can be pinned to Safari, the engine or the app.
void installWebPointerProbe(void Function(String) log) {
  final counts = <int, int>{};
  void listen(String type) {
    web.window.addEventListener(
      type,
      ((web.PointerEvent e) {
        if (type == 'pointermove') {
          if (e.buttons != 0) {
            counts[e.pointerId] = (counts[e.pointerId] ?? 0) + 1;
          }
          return;
        }
        final moves = counts.remove(e.pointerId);
        log('JS $type type=${e.pointerType} id=${e.pointerId} '
            'btn=${e.button}/${e.buttons} p=${e.pressure.toStringAsFixed(2)} '
            'x=${e.clientX.toStringAsFixed(1)} y=${e.clientY.toStringAsFixed(1)} '
            't=${e.timeStamp.toStringAsFixed(0)}'
            '${moves != null ? ' moves=$moves' : ''} '
            'target=${(e.target as web.Element?)?.tagName}');
      }).toJS,
      true.toJS,
    );
  }

  // Stylus touches too: whether WebKit still lets the page cancel them
  // (cancelable) and whether a pointer event followed shows Scribble at work.
  void listenTouch(String type) {
    web.window.addEventListener(
      type,
      ((web.TouchEvent e) {
        final touches = e.changedTouches;
        for (var i = 0; i < touches.length; i++) {
          final t = touches.item(i);
          if (t?.touchType != 'stylus') continue;
          log('JS $type stylus id=${t!.identifier} cancelable=${e.cancelable} '
              'prevented=${e.defaultPrevented} '
              'x=${t.clientX.toStringAsFixed(1)} y=${t.clientY.toStringAsFixed(1)} '
              't=${e.timeStamp.toStringAsFixed(0)}');
        }
      }).toJS,
      true.toJS,
    );
  }

  for (final t in ['touchstart', 'touchend', 'touchcancel']) {
    listenTouch(t);
  }

  for (final t in [
    'pointerdown',
    'pointerup',
    'pointercancel',
    'pointermove',
    'lostpointercapture',
  ]) {
    listen(t);
  }
}

/// Diagnostics only: puts the log next to the app on its own server
/// (`diag/abelnotes.log`) every few seconds, so a log from the tablet needs
/// no copy and paste. Fails silently where the server has no such endpoint.
void startWebDiagUpload(String Function() read) {
  var sent = -1;
  Timer.periodic(const Duration(seconds: 5), (_) {
    final log = read();
    if (log.length == sent) return;
    sent = log.length;
    web.window
        .fetch('diag/abelnotes.log'.toJS,
            web.RequestInit(method: 'PUT', body: log.toJS))
        .toDart
        .then((_) {}, onError: (_) {});
  });
}
