import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Lightweight connectivity monitor.
///
/// Periodically pings the Nextcloud server and exposes a ValueNotifier
/// so the UI and sync engine can react to online/offline transitions.
class ConnectivityService {
  final String serverHost;
  final int serverPort;

  Timer? _pollTimer;
  final ValueNotifier<bool> isOnline = ValueNotifier(false);

  /// Fires once when transitioning offline → online.
  void Function()? onReconnected;

  ConnectivityService({required this.serverHost, this.serverPort = 80});

  /// Start periodic connectivity checks.
  void startMonitoring({Duration interval = const Duration(seconds: 15)}) {
    _check(); // immediate first check
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(interval, (_) => _check());
  }

  void stopMonitoring() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void>? _inFlight;
  bool _disposed = false;

  // Overlapping callers (first check, timer, checkNow) share one probe.
  Future<void> _check() => _inFlight ??= _probe().whenComplete(() {
        _inFlight = null;
      });

  Future<void> _probe() async {
    if (_disposed) return;
    final wasOnline = isOnline.value;
    try {
      final socket = await Socket.connect(
        serverHost,
        serverPort,
        timeout: const Duration(seconds: 5),
      );
      socket.destroy();
      if (_disposed) return;
      isOnline.value = true;

      if (!wasOnline) {
        debugPrint('[Connectivity] Back online!');
        onReconnected?.call();
      }
    } catch (_) {
      if (_disposed) return;
      isOnline.value = false;
      if (wasOnline) {
        debugPrint('[Connectivity] Gone offline.');
      }
    }
  }

  /// One-shot connectivity check.
  Future<bool> checkNow() async {
    await _check();
    return !_disposed && isOnline.value;
  }

  void dispose() {
    _disposed = true;
    stopMonitoring();
    isOnline.dispose();
  }
}
