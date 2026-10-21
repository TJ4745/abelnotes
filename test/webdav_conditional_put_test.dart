// uploadFileConditional must turn into If-Match / If-None-Match on the wire
// and a failed precondition into a 412 the caller can branch on.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:abelnotes/core/services/remote_store.dart';
import 'package:abelnotes/core/services/webdav_service.dart';

void main() {
  late HttpServer server;
  final store = <String, ({List<int> body, String etag})>{};
  final putHeaders = <Map<String, String?>>[];
  var counter = 0;

  setUp(() async {
    store.clear();
    putHeaders.clear();
    counter = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await req.fold<List<int>>([], (a, b) => a..addAll(b));
      final path = req.uri.path;
      if (req.method == 'PUT') {
        putHeaders.add({
          'if-match': req.headers.value('if-match'),
          'if-none-match': req.headers.value('if-none-match'),
        });
        final cur = store[path];
        final ifMatch = req.headers.value('if-match');
        final ifNone = req.headers.value('if-none-match');
        final failed = (ifNone == '*' && cur != null) ||
            (ifMatch != null && (cur == null || '"${cur.etag}"' != ifMatch));
        if (failed) {
          req.response.statusCode = 412;
        } else {
          final etag = 'e${++counter}';
          store[path] = (body: body, etag: etag);
          req.response.statusCode = cur == null ? 201 : 204;
          req.response.headers.set('etag', '"$etag"');
        }
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  WebDavService dav() {
    final d = WebDavService(
        serverUrl: 'http://127.0.0.1:${server.port}',
        username: 'u',
        password: 'p');
    addTearDown(d.dispose);
    return d;
  }

  Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

  test('ifAbsent creates once, then reports 412', () async {
    final d = dav();
    final v1 = await d.uploadFileConditional('/f.json', bytes('1'), ifAbsent: true);
    expect(v1, 'e1');
    expect(putHeaders.single['if-none-match'], '*');
    await expectLater(
        d.uploadFileConditional('/f.json', bytes('2'), ifAbsent: true),
        throwsA(isA<RemoteStoreException>()
            .having((e) => e.statusCode, 'status', 412)));
    expect(utf8.decode(store.values.single.body), '1');
  });

  test('ifMatchVersion writes only over the version it was based on', () async {
    final d = dav();
    final v1 = await d.uploadFile('/f.json', bytes('1'));
    final v2 = await d.uploadFileConditional('/f.json', bytes('2'),
        ifMatchVersion: v1);
    expect(v2, 'e2');
    expect(putHeaders.last['if-match'], '"e1"');
    await expectLater(
        d.uploadFileConditional('/f.json', bytes('3'), ifMatchVersion: v1),
        throwsA(isA<RemoteStoreException>()
            .having((e) => e.statusCode, 'status', 412)));
    expect(utf8.decode(store.values.single.body), '2');
  });

  test('a lost race is not retried as if it were a transient error', () async {
    final d = dav();
    await d.uploadFile('/f.json', bytes('1'));
    putHeaders.clear();
    await expectLater(
        d.uploadFileConditional('/f.json', bytes('x'), ifMatchVersion: 'stale'),
        throwsA(isA<RemoteStoreException>()));
    expect(putHeaders, hasLength(1));
  });

  test('plain uploadFile sends no precondition headers', () async {
    await dav().uploadFile('/f.json', bytes('1'));
    expect(putHeaders.single['if-match'], isNull);
    expect(putHeaders.single['if-none-match'], isNull);
  });
}
