import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:abelnotes/core/providers/app_settings_provider.dart';
import 'package:abelnotes/core/providers/remote_store_provider.dart';
import 'package:abelnotes/core/services/folder_sync_service.dart';
import 'package:abelnotes/core/services/remote_store.dart';

/// Runs the library-folder sync: on every library refresh (with the root
/// listing it already has) and shortly after a local folder edit.
class FolderSyncController {
  static const debounce = Duration(seconds: 3);

  final Ref _ref;
  Timer? _timer;
  bool _running = false;
  bool _again = false;

  FolderSyncController(this._ref) {
    _ref.listen(appSettingsProvider.select((s) => s.folderDoc), (_, __) {
      if (_ref.read(appSettingsProvider).folderDirty) syncSoon();
    });
    _ref.onDispose(() => _timer?.cancel());
  }

  void syncSoon() {
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(sync()));
  }

  /// [root] is the remote root listing when the caller just fetched one.
  /// Never throws: a failure only means the next cycle tries again.
  Future<void> sync({Iterable<RemoteItem>? root}) async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        await _once(root);
        root = null;
      } while (_again);
    } catch (e) {
      debugPrint('[Folders] sync failed: $e');
    } finally {
      _running = false;
    }
  }

  Future<void> _once(Iterable<RemoteItem>? root) async {
    final remote = _ref.read(remoteStoreProvider);
    if (remote == null) return;
    final settings = _ref.read(appSettingsProvider.notifier);
    await settings.ready;
    final s = _ref.read(appSettingsProvider);
    final result = await FolderSyncService(remote).sync(
      local: s.folderDoc,
      dirty: s.folderDirty,
      knownVersion: s.folderRemoteVersion,
      known: root == null ? null : FolderSyncService.stateFromListing(root),
    );
    if (result.skippedNewerVersion) {
      debugPrint('[Folders] folders.json is from a newer app version; skipped');
    }
    final doc = result.doc;
    if (doc == null) return;
    final editedMeanwhile =
        !identical(_ref.read(appSettingsProvider).folderDoc, s.folderDoc);
    await settings.applyFolderSync(doc, result.remoteVersion);
    if (editedMeanwhile) syncSoon();
  }
}

final folderSyncProvider =
    Provider<FolderSyncController>((ref) => FolderSyncController(ref));
