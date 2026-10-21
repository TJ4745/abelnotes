import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:abelnotes/core/services/folder_sync_service.dart';
import 'package:abelnotes/core/services/remote_store.dart';
import 'package:abelnotes/shared/models/folder_doc.dart';

import 'support/fake_remote_store.dart';

const _path = '/AbelNotes/folders.json';

/// One device: its local doc plus the marker the sync keeps between runs.
class _Device {
  _Device(this.store);
  final FakeRemoteStore store;
  FolderDoc doc = FolderDoc.empty;
  bool dirty = false;
  String? version;

  void edit(FolderDoc Function(FolderDoc) f) {
    doc = f(doc);
    dirty = true;
  }

  Future<FolderSyncResult> sync({FolderRemoteState? known}) async {
    final r = await FolderSyncService(store, nowMs: () => 1000).sync(
        local: doc, dirty: dirty, knownVersion: version, known: known);
    final merged = r.doc;
    if (merged != null) {
      doc = merged;
      dirty = false;
      version = r.remoteVersion;
    }
    return r;
  }
}

FolderDoc _remote(FakeRemoteStore s) =>
    FolderDoc.decode(s.files[_path]!.toList());

void main() {
  late FakeRemoteStore store;
  setUp(() => store = FakeRemoteStore());

  _Device device() => _Device(store);

  test('a user without folders makes no request when the listing has none',
      () async {
    final d = device();
    final r = await d.sync(known: (exists: false, version: null));
    expect(r.doc, isNull);
    expect(store.calls, isEmpty);
    expect(store.files, isEmpty);
  });

  test('a user without folders and no listing costs a single lookup',
      () async {
    final r = await device().sync();
    expect(r.doc, isNull);
    expect(store.calls.where((c) => c.startsWith('upload')), isEmpty);
    expect(store.calls.where((c) => c.startsWith('download')), isEmpty);
    expect(store.files, isEmpty);
  });

  test('first upload creates folders.json, only if absent', () async {
    final d = device()..edit((x) => x.withFolderCreated('f1', 'Math', 100));
    final r = await d.sync(known: (exists: false, version: null));
    expect(r.uploaded, isTrue);
    expect(_remote(store).folders['f1']!.name, 'Math');
    expect(store.calls, contains('upload-if $_path'));
    expect(r.remoteVersion, isNotNull);
  });

  test('unchanged remote and nothing dirty: no download, no upload', () async {
    final d = device()..edit((x) => x.withFolderCreated('f1', 'Math', 100));
    await d.sync(known: (exists: false, version: null));
    d.dirty = false;
    store.calls.clear();
    final v = d.version;
    final r = await d.sync(known: (exists: true, version: v));
    expect(r.doc, isNull);
    expect(store.calls, isEmpty);
  });

  test('a second device receives the folders and its own appear remotely',
      () async {
    final a = device()
      ..edit((x) => x
          .withFolderCreated('f1', 'Math', 100)
          .withAssignment('nb1', 'f1', 101));
    await a.sync();

    final b = device();
    final r = await b.sync();
    expect(r.uploaded, isFalse, reason: 'nothing to add on B');
    expect(b.doc.liveFolders.single.value.name, 'Math');
    expect(b.doc.liveAssignments, {'nb1': 'f1'});

    b.edit((x) => x.withFolderRenamed('f1', 'Maths', 200));
    await b.sync();
    await a.sync();
    expect(a.doc.liveFolders.single.value.name, 'Maths');
  });

  test('edits of different folders on two devices both land', () async {
    final a = device()
      ..edit((x) => x
          .withFolderCreated('f1', 'One', 100)
          .withFolderCreated('f2', 'Two', 101));
    await a.sync();
    final b = device();
    await b.sync();

    a.edit((x) => x.withFolderRenamed('f1', 'Uno', 300));
    b.edit((x) => x.withFolderRenamed('f2', 'Due', 310));
    await a.sync();
    await b.sync(); // sees A's file, merges, uploads
    await a.sync();
    for (final d in [a, b]) {
      expect(d.doc.folders['f1']!.name, 'Uno');
      expect(d.doc.folders['f2']!.name, 'Due');
    }
    expect(_remote(store).folders['f1']!.name, 'Uno');
    expect(_remote(store).folders['f2']!.name, 'Due');
  });

  test('a write racing ours is merged on the retry, not clobbered', () async {
    final a = device()..edit((x) => x.withFolderCreated('f1', 'One', 100));
    await a.sync();
    final b = device();
    await b.sync();

    a.edit((x) => x.withFolderRenamed('f1', 'Uno', 300));
    b.edit((x) => x.withFolderCreated('f2', 'Two', 310));
    // While A is about to write, B gets in first.
    var raced = false;
    store.beforeConditionalCheck = (path) {
      if (raced) return;
      raced = true;
      store.files[path] = Uint8List.fromList(
          b.doc.encode()); // what B would have uploaded
      store.bumpVersion(path);
    };
    store.calls.clear();
    final r = await a.sync();
    expect(r.uploaded, isTrue);
    final remote = _remote(store);
    expect(remote.folders['f1']!.name, 'Uno');
    expect(remote.folders.containsKey('f2'), isTrue,
        reason: 'B\'s folder must survive A\'s write');
    expect(store.calls.where((c) => c.startsWith('upload-if')).length, 2);
  });

  test('gives up after three lost races and keeps local state', () async {
    final a = device()..edit((x) => x.withFolderCreated('f1', 'One', 100));
    store.beforeConditionalCheck = (path) {
      store.files[path] = Uint8List.fromList(
          utf8.encode('{"version":1,"folders":{},"assignments":{}}'));
      store.bumpVersion(path);
    };
    await expectLater(
        a.sync(known: (exists: false, version: null)),
        throwsA(isA<RemoteStoreException>()
            .having((e) => e.statusCode, 'status', 412)));
    expect(store.calls.where((c) => c.startsWith('upload-if')).length, 3);
    expect(a.doc.liveFolders.single.value.name, 'One');
    expect(a.dirty, isTrue);
  });

  test('a folders.json from a newer version is left untouched', () async {
    const future = '{"version":2,"folders":{"x":1},"newThing":[1,2,3]}';
    store.files[_path] = Uint8List.fromList(utf8.encode(future));
    final a = device()..edit((x) => x.withFolderCreated('f1', 'One', 100));
    final r = await a.sync();
    expect(r.skippedNewerVersion, isTrue);
    expect(r.doc, isNull);
    expect(utf8.decode(store.files[_path]!), future);
    expect(store.calls.where((c) => c.startsWith('upload')), isEmpty);
  });

  test('a corrupt folders.json is not overwritten and surfaces as an error',
      () async {
    store.files[_path] = Uint8List.fromList(utf8.encode('{not json'));
    final a = device()..edit((x) => x.withFolderCreated('f1', 'One', 100));
    await expectLater(a.sync(), throwsA(isA<FormatException>()));
    expect(utf8.decode(store.files[_path]!), '{not json');
  });

  test('upload failure throws and leaves the device dirty for next cycle',
      () async {
    store.failUploads.add(_path);
    final a = device()..edit((x) => x.withFolderCreated('f1', 'One', 100));
    await expectLater(a.sync(), throwsA(isA<RemoteStoreException>()));
    expect(a.dirty, isTrue);
    expect(a.doc.liveFolders, hasLength(1));
    store.failUploads.clear();
    await a.sync();
    expect(_remote(store).folders.keys, {'f1'});
  });

  test('remote file deleted by hand is restored from local state', () async {
    final a = device()..edit((x) => x.withFolderCreated('f1', 'One', 100));
    await a.sync();
    store.files.remove(_path);
    final r = await a.sync();
    expect(r.uploaded, isTrue);
    expect(_remote(store).folders.keys, {'f1'});
  });

  test('stateFromListing reads existence and version from a root listing', () {
    final items = [
      RemoteItem(path: '/AbelNotes/a.abelnote', name: 'a.abelnote', isDirectory: false),
      RemoteItem(
          path: _path, name: 'folders.json', isDirectory: false, version: 'e1'),
    ];
    expect(FolderSyncService.stateFromListing(items),
        (exists: true, version: 'e1'));
    expect(FolderSyncService.stateFromListing(items.take(1)),
        (exists: false, version: null));
  });
}
