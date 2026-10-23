// A PUT whose body the server keeps truncating must not leave the broken file
// behind once the retries run out, and unreadable dates must read as unknown.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:abelnotes/core/services/webdav_service.dart';

void main() {
  late HttpServer server;
  late Map<String, int> stored;
  late List<String> deleted;
  // Size the server reports per PUT body length; null omits the property.
  late int? Function(int sent) reported;

  setUp(() async {
    stored = {};
    deleted = [];
    reported = (sent) => sent ~/ 2;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path;
      switch (req.method) {
        case 'PUT':
          final body = await req.fold<int>(0, (n, c) => n + c.length);
          stored[path] = reported(body) ?? -1;
          req.response.statusCode = 201;
        case 'PROPFIND':
          await req.drain<void>();
          req.response.statusCode = 207;
          req.response.write('<?xml version="1.0"?>'
              '<d:multistatus xmlns:d="DAV:"><d:response><d:propstat><d:prop>'
              '${stored[path] == -1 ? '' : '<d:getcontentlength>${stored[path] ?? 0}</d:getcontentlength>'}'
              '</d:prop></d:propstat></d:response></d:multistatus>');
        case 'DELETE':
          await req.drain<void>();
          deleted.add(path);
          stored.remove(path);
          req.response.statusCode = 204;
        default:
          await req.drain<void>();
          req.response.statusCode = 200;
      }
      await req.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  WebDavService dav() {
    final d = WebDavService(
        serverUrl: 'http://127.0.0.1:${server.port}',
        username: 'u',
        password: 'p',
        serverType: WebDavServerType.generic);
    addTearDown(d.dispose);
    return d;
  }

  test('a truncated copy (server smaller) is deleted after the retries',
      () async {
    await expectLater(
        dav().uploadFile('/nb/doc.json', Uint8List(100), criticalVerify: true),
        throwsA(isA<WebDavSizeMismatchException>()));
    expect(deleted, ['/nb/doc.json']);
    expect(stored, isEmpty);
  });

  test('a larger copy (another device won) is left alone', () async {
    reported = (sent) => sent + 20;
    await expectLater(
        dav().uploadFile('/nb/doc.json', Uint8List(100), criticalVerify: true),
        throwsA(isA<WebDavSizeMismatchException>()));
    expect(deleted, isEmpty);
    expect(stored, {'/nb/doc.json': 120});
  });

  test('an unknown server size never deletes', () async {
    reported = (_) => null;
    await dav().uploadFile('/nb/doc.json', Uint8List(100), criticalVerify: true);
    expect(deleted, isEmpty);
    expect(stored, hasLength(1));
  });

  group('parseHttpDate', () {
    test('reads the year from the string', () {
      expect(parseHttpDate('Wed, 15 Jul 2026 10:00:00 GMT'),
          DateTime.utc(2026, 7, 15, 10));
      expect(parseHttpDate('Sun, 06 Nov 1994 08:49:37 GMT'),
          DateTime.utc(1994, 11, 6, 8, 49, 37));
      expect(parseHttpDate('Mon, 02 Jan 2031 00:00:01 GMT'),
          DateTime.utc(2031, 1, 2, 0, 0, 1));
    });

    test('ISO 8601 still parses', () {
      expect(parseHttpDate('2026-07-15T10:00:00Z'),
          DateTime.utc(2026, 7, 15, 10));
    });

    test('garbage is unknown, never now', () {
      expect(parseHttpDate('not a date'), isNull);
      expect(parseHttpDate(''), isNull);
      expect(parseHttpDate('Wed, 15 Foo 2026 10:00:00 GMT'), isNull);
      expect(parseHttpDate('Wed, xx Jul 2026 10:00:00 GMT'), isNull);
      expect(parseHttpDate('Wed, 15 Jul abcd 10:00:00 GMT'), isNull);
      expect(parseHttpDate('Wed, 15 Jul 2026 99:00:00 GMT'), isNull);
    });
  });
}
