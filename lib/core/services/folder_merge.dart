import 'dart:convert';

import 'package:abelnotes/shared/models/folder_doc.dart';

/// How long a tombstone is kept before the merge drops it.
const folderTombstoneTtl = Duration(days: 90);

/// Merges two folder documents entry by entry, newest `updatedAt` wins.
///
/// Commutative, associative and idempotent for a fixed [nowMs], so devices
/// converge whatever order they sync in. Ties break on (tombstone, name) so
/// both sides pick the same winner. Neither input may be [FolderDoc.isFuture].
FolderDoc mergeFolderDocs(
  FolderDoc a,
  FolderDoc b, {
  required int nowMs,
  Duration tombstoneTtl = folderTombstoneTtl,
}) {
  if (a.isFuture || b.isFuture) {
    throw ArgumentError('cannot merge a folders.json from a newer version');
  }
  final cutoff = nowMs - tombstoneTtl.inMilliseconds;

  final folders = <String, FolderEntry>{};
  for (final id in {...a.folders.keys, ...b.folders.keys}) {
    final x = a.folders[id];
    final y = b.folders[id];
    final e = x == null ? y! : (y == null ? x : _pickFolder(x, y));
    if (e.deleted && e.updatedAt < cutoff) continue;
    folders[id] = e;
  }

  final assignments = <String, AssignmentEntry>{};
  for (final nb in {...a.assignments.keys, ...b.assignments.keys}) {
    final x = a.assignments[nb];
    final y = b.assignments[nb];
    final e = x == null ? y! : (y == null ? x : _pickAssignment(x, y));
    final live = e.folderId != null && !(folders[e.folderId]?.deleted ?? true);
    if (!live && e.updatedAt < cutoff) continue;
    assignments[nb] = e;
  }

  return FolderDoc(
    folders: folders,
    assignments: assignments,
    extra: _mergeExtra(a.extra, b.extra),
  );
}

FolderEntry _pickFolder(FolderEntry x, FolderEntry y) {
  final win = _cmpFolder(x, y) >= 0 ? x : y;
  final created = x.createdAt < y.createdAt ? x.createdAt : y.createdAt;
  return created == win.createdAt
      ? win
      : FolderEntry(
          name: win.name,
          createdAt: created,
          updatedAt: win.updatedAt,
          deleted: win.deleted,
          extra: win.extra);
}

int _cmpFolder(FolderEntry x, FolderEntry y) {
  var c = x.updatedAt.compareTo(y.updatedAt);
  if (c != 0) return c;
  c = (x.deleted ? 1 : 0).compareTo(y.deleted ? 1 : 0);
  if (c != 0) return c;
  c = x.name.compareTo(y.name);
  if (c != 0) return c;
  return jsonEncode(x.extra).compareTo(jsonEncode(y.extra));
}

AssignmentEntry _pickAssignment(AssignmentEntry x, AssignmentEntry y) {
  var c = x.updatedAt.compareTo(y.updatedAt);
  if (c == 0) c = (x.folderId ?? '').compareTo(y.folderId ?? '');
  if (c == 0) c = jsonEncode(x.extra).compareTo(jsonEncode(y.extra));
  return c >= 0 ? x : y;
}

Map<String, dynamic> _mergeExtra(Map<String, dynamic> a, Map<String, dynamic> b) {
  final out = {...a};
  b.forEach((k, v) {
    final mine = out[k];
    if (mine == null || jsonEncode(v).compareTo(jsonEncode(mine)) > 0) out[k] = v;
  });
  return out;
}
