// Overlapping checks (first check, timer tick, checkNow) must not each fire
// onReconnected, and a probe finishing after dispose must not throw.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:abelnotes/core/services/connectivity_service.dart';

void main() {
  late ServerSocket server;
  setUp(() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) => s.destroy());
  });
  tearDown(() => server.close());

  ConnectivityService svc() => ConnectivityService(
      serverHost: '127.0.0.1', serverPort: server.port);

  test('overlapping checks fire onReconnected once', () async {
    final c = svc();
    var fired = 0;
    c.onReconnected = () => fired++;
    c.startMonitoring(interval: const Duration(milliseconds: 1));
    await Future.wait([c.checkNow(), c.checkNow(), c.checkNow()]);
    c.stopMonitoring();
    expect(c.isOnline.value, isTrue);
    expect(fired, 1);
    c.dispose();
  });

  test('dispose during a probe does not throw', () async {
    final c = svc();
    final pending = c.checkNow();
    c.dispose();
    expect(await pending, isFalse);
  });

  test('an unreachable server settles offline', () async {
    final port = server.port;
    await server.close();
    final c = ConnectivityService(serverHost: '127.0.0.1', serverPort: port);
    expect(await c.checkNow(), isFalse);
    c.dispose();
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  });
}
