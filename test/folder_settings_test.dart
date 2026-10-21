import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:abelnotes/core/providers/app_settings_provider.dart';
import 'package:abelnotes/shared/models/folder_doc.dart';

const _key = 'app_settings_v1';

Future<AppSettingsNotifier> _boot([Map<String, dynamic>? stored]) async {
  SharedPreferences.setMockInitialValues(
      stored == null ? {} : {_key: jsonEncode(stored)});
  final n = AppSettingsNotifier();
  await n.ready;
  return n;
}

Future<Map<String, dynamic>> _stored() async {
  final prefs = await SharedPreferences.getInstance();
  return jsonDecode(prefs.getString(_key)!) as Map<String, dynamic>;
}

void main() {
  test('a fresh install has no folders and nothing to sync', () async {
    final n = await _boot();
    expect(n.state.folders, isEmpty);
    expect(n.state.folderDirty, isFalse);
  });

  test('pre-sync folders migrate once with a stable stamp, order kept',
      () async {
    final n = await _boot({
      'folders': [
        {'id': 'a', 'name': 'First'},
        {'id': 'b', 'name': 'Second'},
      ],
      'notebook_folder': {'nb1': 'b'},
    });
    expect(n.state.folders.map((f) => f.name), ['First', 'Second']);
    expect(n.state.notebookFolderId, {'nb1': 'b'});
    expect(n.state.folderDirty, isTrue);
    final stamp = n.state.folderDoc.folders['a']!.updatedAt;
    expect(stamp, greaterThan(0));

    final stored = await _stored();
    expect(stored['folder_doc'], isNotNull, reason: 'persisted immediately');

    final again = AppSettingsNotifier();
    await again.ready;
    expect(again.state.folderDoc.folders['a']!.updatedAt, stamp);
    expect(again.state.folders.map((f) => f.name), ['First', 'Second']);
  });

  test('the old plain keys are still written for older builds', () async {
    final n = await _boot();
    n.createFolder('Math');
    n.setNotebookFolder('nb', n.state.folders.single.id);
    await Future<void>.delayed(Duration.zero);
    final stored = await _stored();
    expect((stored['folders'] as List).single['name'], 'Math');
    expect((stored['notebook_folder'] as Map).keys, ['nb']);
  });

  test('edits mark the folders dirty and keep their order', () async {
    final n = await _boot();
    n.createFolder('One');
    n.createFolder('Two');
    expect(n.state.folderDirty, isTrue);
    expect(n.state.folders.map((f) => f.name), ['One', 'Two']);
    final id = n.state.folders.first.id;
    n.renameFolder(id, 'Uno');
    expect(n.state.folders.map((f) => f.name), ['Uno', 'Two']);
  });

  test('deleting a folder unfiles its notebooks but keeps a tombstone',
      () async {
    final n = await _boot();
    n.createFolder('One');
    final id = n.state.folders.single.id;
    n.setNotebookFolder('nb', id);
    n.deleteFolder(id);
    expect(n.state.folders, isEmpty);
    expect(n.state.notebookFolderId, isEmpty);
    expect(n.state.folderDoc.folders[id]!.deleted, isTrue);
  });

  test('purging a notebook unfiles it with a stamp other devices can merge',
      () async {
    final n = await _boot();
    n.createFolder('One');
    n.setNotebookFolder('nb', n.state.folders.single.id);
    n.purgeNotebook('nb');
    expect(n.state.notebookFolderId, isEmpty);
    expect(n.state.folderDoc.assignments['nb']!.folderId, isNull);
  });

  test('purging an unfiled notebook does not dirty the folders', () async {
    final n = await _boot();
    n.purgeNotebook('whatever');
    expect(n.state.folderDirty, isFalse);
  });

  test('a sync result keeps edits made while it ran and stays dirty',
      () async {
    final n = await _boot();
    n.createFolder('One');
    final started = n.state.folderDoc; // what the sync was handed
    n.createFolder('Typed meanwhile');
    await n.applyFolderSync(started, 'v1');
    expect(n.state.folders.map((f) => f.name), ['One', 'Typed meanwhile']);
    expect(n.state.folderDirty, isTrue);
    expect(n.state.folderRemoteVersion, 'v1');

    await n.applyFolderSync(n.state.folderDoc, 'v2');
    expect(n.state.folderDirty, isFalse);
  });

  test('a synced-in remote folder shows up and is not dirty', () async {
    final n = await _boot();
    final remote = FolderDoc.empty.withFolderCreated('r1', 'Remote', 5000);
    await n.applyFolderSync(remote, 'v7');
    expect(n.state.folders.single.name, 'Remote');
    expect(n.state.folderDirty, isFalse);
    expect((await _stored())['folder_remote_version'], 'v7');
  });
}
