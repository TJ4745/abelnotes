import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:abelnotes/core/providers/app_settings_provider.dart';
import 'package:abelnotes/core/providers/folder_sync_provider.dart';
import 'package:abelnotes/core/providers/remote_store_provider.dart';
import 'package:abelnotes/core/services/remote_store.dart';

import 'support/fake_remote_store.dart';

ProviderContainer _device(RemoteStore? remote) {
  final c = ProviderContainer(
      overrides: [remoteStoreProvider.overrideWithValue(remote)]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('two devices converge through the controller', () async {
    final server = FakeRemoteStore();
    final a = _device(server), b = _device(server);
    await a.read(appSettingsProvider.notifier).ready;
    await b.read(appSettingsProvider.notifier).ready;

    final an = a.read(appSettingsProvider.notifier);
    an.createFolder('Math');
    an.setNotebookFolder('nb1', a.read(appSettingsProvider).folders.single.id);
    await a.read(folderSyncProvider).sync();
    expect(a.read(appSettingsProvider).folderDirty, isFalse);

    await b.read(folderSyncProvider).sync();
    expect(b.read(appSettingsProvider).folders.single.name, 'Math');
    expect(b.read(appSettingsProvider).notebookFolderId.keys, ['nb1']);

    final id = b.read(appSettingsProvider).folders.single.id;
    b.read(appSettingsProvider.notifier).deleteFolder(id);
    await b.read(folderSyncProvider).sync();
    await a.read(folderSyncProvider).sync();
    expect(a.read(appSettingsProvider).folders, isEmpty);
    expect(a.read(appSettingsProvider).notebookFolderId, isEmpty);
  });

  test('local-only mode makes no remote call and keeps the folders', () async {
    final c = _device(null);
    await c.read(appSettingsProvider.notifier).ready;
    c.read(appSettingsProvider.notifier).createFolder('Mine');
    await c.read(folderSyncProvider).sync();
    expect(c.read(appSettingsProvider).folders.single.name, 'Mine');
    expect(c.read(appSettingsProvider).folderDirty, isTrue);
  });

  test('an unreachable server never loses local folders', () async {
    final server = FakeRemoteStore()..failUploads.add('/AbelNotes/folders.json');
    final c = _device(server);
    await c.read(appSettingsProvider.notifier).ready;
    c.read(appSettingsProvider.notifier).createFolder('Mine');
    await c.read(folderSyncProvider).sync(); // swallows the failure
    expect(c.read(appSettingsProvider).folders.single.name, 'Mine');
    expect(c.read(appSettingsProvider).folderDirty, isTrue);
    server.failUploads.clear();
    await c.read(folderSyncProvider).sync();
    expect(c.read(appSettingsProvider).folderDirty, isFalse);
    expect(server.files.keys, contains('/AbelNotes/folders.json'));
  });

  test('a user who never made a folder touches the server not at all',
      () async {
    final server = FakeRemoteStore();
    final c = _device(server);
    await c.read(appSettingsProvider.notifier).ready;
    await c.read(folderSyncProvider).sync(root: const []);
    expect(server.calls, isEmpty);
  });
}
