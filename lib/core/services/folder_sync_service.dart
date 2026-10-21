import 'dart:typed_data';

import 'package:abelnotes/core/services/folder_merge.dart';
import 'package:abelnotes/core/services/remote_store.dart';
import 'package:abelnotes/shared/models/folder_doc.dart';

/// What the remote currently holds for `folders.json`.
typedef FolderRemoteState = ({bool exists, String? version});

/// Result of one [FolderSyncService.sync] run.
class FolderSyncResult {
  /// Local state to adopt; null when nothing was done.
  final FolderDoc? doc;

  /// Version token of the remote file as of [doc], null if unknown.
  final String? remoteVersion;
  final bool uploaded;

  /// The remote file is from a newer app version and was left alone.
  final bool skippedNewerVersion;

  const FolderSyncResult({
    this.doc,
    this.remoteVersion,
    this.uploaded = false,
    this.skippedNewerVersion = false,
  });

  static const nothingToDo = FolderSyncResult();
}

/// Keeps `folders.json` at the remote root in step with the local folders.
///
/// Read, merge, conditional write; a lost race re-reads and merges again.
/// Failures throw and leave local state untouched, so the next cycle retries.
class FolderSyncService {
  static const maxAttempts = 3;

  final RemoteStore _store;
  final int Function() _nowMs;

  FolderSyncService(this._store, {int Function()? nowMs})
      : _nowMs = nowMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  String get _path => '${_store.basePath}${FolderDoc.fileName}';

  /// [known] is the file's state from a listing the caller already has (no
  /// extra request); otherwise it is looked up. [knownVersion] is the version
  /// this device last merged, [dirty] says local edits are not uploaded yet.
  Future<FolderSyncResult> sync({
    required FolderDoc local,
    required bool dirty,
    String? knownVersion,
    FolderRemoteState? known,
  }) async {
    var state = known ?? await _lookup();
    if (!state.exists && local.isEmpty) return FolderSyncResult.nothingToDo;
    if (state.exists &&
        !dirty &&
        state.version != null &&
        state.version == knownVersion) {
      return FolderSyncResult.nothingToDo;
    }

    var current = local;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      var remote = FolderDoc.empty;
      if (state.exists) {
        try {
          remote = FolderDoc.decode(await _store.downloadFile(_path,
              criticalVerify: true));
        } on RemoteStoreException catch (e) {
          if (e.statusCode != 404) rethrow;
          state = (exists: false, version: null);
        }
      }
      if (remote.isFuture) {
        return FolderSyncResult(
            skippedNewerVersion: true, remoteVersion: state.version);
      }

      final merged =
          mergeFolderDocs(current, remote, nowMs: _nowMs());
      if (state.exists && merged.sameContent(remote)) {
        return FolderSyncResult(doc: merged, remoteVersion: state.version);
      }

      try {
        final bytes = Uint8List.fromList(merged.encode());
        final version = state.exists
            ? await _store.uploadFileConditional(_path, bytes,
                ifMatchVersion: state.version)
            : await _store.uploadFileConditional(_path, bytes, ifAbsent: true);
        return FolderSyncResult(
            doc: merged, remoteVersion: version, uploaded: true);
      } on RemoteStoreException catch (e) {
        if (e.statusCode != 412) rethrow;
        // Someone else wrote first: fold their version in and try again.
        current = merged;
        state = await _lookup();
      }
    }
    throw RemoteStoreException(
        'folders.json changed under us $maxAttempts times', 412);
  }

  Future<FolderRemoteState> _lookup() async {
    final quick = await _store.getVersionFast(_path);
    if (quick != null) return (exists: true, version: quick);
    final info = await _store.getFileInfo(_path);
    return info == null
        ? (exists: false, version: null)
        : (exists: true, version: info.version);
  }

  /// State of `folders.json` out of a root listing, null when it has none.
  static FolderRemoteState stateFromListing(Iterable<RemoteItem> root) {
    for (final item in root) {
      if (!item.isDirectory && item.name == FolderDoc.fileName) {
        return (exists: true, version: item.version);
      }
    }
    return (exists: false, version: null);
  }
}
