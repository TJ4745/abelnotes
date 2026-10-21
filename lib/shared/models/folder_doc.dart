import 'dart:convert';

/// One library folder inside [FolderDoc]. Deleted folders stay as tombstones.
class FolderEntry {
  final String name;
  final int createdAt;
  final int updatedAt;
  final bool deleted;

  /// Fields a newer app wrote that this version does not know.
  final Map<String, dynamic> extra;

  const FolderEntry({
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.deleted = false,
    this.extra = const {},
  });

  FolderEntry copyWith({String? name, int? updatedAt, bool? deleted}) =>
      FolderEntry(
        name: name ?? this.name,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        deleted: deleted ?? this.deleted,
        extra: extra,
      );

  Map<String, dynamic> toJson() => {
        ...extra,
        'name': name,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        if (deleted) 'deleted': true,
      };

  static FolderEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final known = {'name', 'createdAt', 'updatedAt', 'deleted'};
    final updatedAt = (raw['updatedAt'] as num?)?.toInt() ?? 0;
    return FolderEntry(
      name: raw['name'] as String? ?? '',
      createdAt: (raw['createdAt'] as num?)?.toInt() ?? updatedAt,
      updatedAt: updatedAt,
      deleted: raw['deleted'] == true,
      extra: {
        for (final e in raw.entries)
          if (e.key is String && !known.contains(e.key)) e.key as String: e.value
      },
    );
  }
}

/// Which folder a notebook sits in, or null for "unfiled" (also a tombstone).
class AssignmentEntry {
  final String? folderId;
  final int updatedAt;
  final Map<String, dynamic> extra;

  const AssignmentEntry({
    required this.folderId,
    required this.updatedAt,
    this.extra = const {},
  });

  Map<String, dynamic> toJson() =>
      {...extra, 'folderId': folderId, 'updatedAt': updatedAt};

  static AssignmentEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final known = {'folderId', 'updatedAt'};
    return AssignmentEntry(
      folderId: raw['folderId'] as String?,
      updatedAt: (raw['updatedAt'] as num?)?.toInt() ?? 0,
      extra: {
        for (final e in raw.entries)
          if (e.key is String && !known.contains(e.key)) e.key as String: e.value
      },
    );
  }
}

/// The synced library folders: `folders.json` at the root of the remote.
///
/// Every entry carries its own `updatedAt` (UTC ms) so devices merge per
/// entry (see `mergeFolderDocs`). Instances are treated as immutable.
class FolderDoc {
  static const supportedVersion = 1;
  static const fileName = 'folders.json';

  final int version;
  final Map<String, FolderEntry> folders;
  final Map<String, AssignmentEntry> assignments;
  final Map<String, dynamic> extra;

  FolderDoc({
    this.version = supportedVersion,
    this.folders = const {},
    this.assignments = const {},
    this.extra = const {},
  });

  static final empty = FolderDoc();

  /// Written by a newer app: read-only for us, never merged or overwritten.
  bool get isFuture => version > supportedVersion;

  bool get isEmpty => folders.isEmpty && assignments.isEmpty;

  /// Live folders in creation order (id breaks ties), as the UI lists them.
  late final List<MapEntry<String, FolderEntry>> liveFolders = () {
    final out = folders.entries.where((e) => !e.value.deleted).toList()
      ..sort((a, b) {
        final c = a.value.createdAt.compareTo(b.value.createdAt);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    return out;
  }();

  /// notebookId -> folderId for notebooks sitting in a live folder.
  late final Map<String, String> liveAssignments = () {
    final out = <String, String>{};
    assignments.forEach((nb, a) {
      final f = a.folderId;
      if (f != null && folders[f] != null && !folders[f]!.deleted) out[nb] = f;
    });
    return out;
  }();

  /// Same bytes on the wire: the comparison the sync uses to skip uploads.
  bool sameContent(FolderDoc other) => encodeString() == other.encodeString();

  Map<String, dynamic> toJson() {
    final fKeys = folders.keys.toList()..sort();
    final aKeys = assignments.keys.toList()..sort();
    return {
      ...extra,
      'version': version,
      'folders': {for (final k in fKeys) k: folders[k]!.toJson()},
      'assignments': {for (final k in aKeys) k: assignments[k]!.toJson()},
    };
  }

  String encodeString() => jsonEncode(toJson());

  List<int> encode() => utf8.encode(encodeString());

  /// Throws [FormatException] when [bytes] are not a folders document.
  static FolderDoc decode(List<int> bytes) {
    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is! Map) throw const FormatException('folders.json is not an object');
    return FolderDoc.fromJson(raw);
  }

  static FolderDoc fromJson(Map<dynamic, dynamic> raw) {
    final folders = <String, FolderEntry>{};
    final rawFolders = raw['folders'];
    if (rawFolders is Map) {
      rawFolders.forEach((k, v) {
        final e = FolderEntry.fromJson(v);
        if (k is String && e != null) folders[k] = e;
      });
    }
    final assignments = <String, AssignmentEntry>{};
    final rawAssign = raw['assignments'];
    if (rawAssign is Map) {
      rawAssign.forEach((k, v) {
        final e = AssignmentEntry.fromJson(v);
        if (k is String && e != null) assignments[k] = e;
      });
    }
    const known = {'version', 'folders', 'assignments'};
    return FolderDoc(
      version: (raw['version'] as num?)?.toInt() ?? supportedVersion,
      folders: folders,
      assignments: assignments,
      extra: {
        for (final e in raw.entries)
          if (e.key is String && !known.contains(e.key)) e.key as String: e.value
      },
    );
  }

  /// Doc for a pre-sync install: the old local folders and assignments,
  /// stamped [nowMs] (+ index, so the creation order survives).
  static FolderDoc fromLegacy(
    List<({String id, String name})> folders,
    Map<String, String> assignments,
    int nowMs,
  ) {
    return FolderDoc(
      folders: {
        for (var i = 0; i < folders.length; i++)
          folders[i].id: FolderEntry(
              name: folders[i].name, createdAt: nowMs + i, updatedAt: nowMs),
      },
      assignments: {
        for (final e in assignments.entries)
          e.key: AssignmentEntry(folderId: e.value, updatedAt: nowMs),
      },
    );
  }

  // Local edits. An edit is stamped past the entry's previous stamp even when
  // this device's clock is behind, so it still beats what it was based on.

  static int _stamp(int nowMs, int? previous) =>
      previous == null || nowMs > previous ? nowMs : previous + 1;

  FolderDoc withFolderCreated(String id, String name, int nowMs) {
    // Strictly after every folder already here, so the listing order is stable.
    final latest = folders.values.fold<int?>(
        null, (m, f) => m == null || f.createdAt > m ? f.createdAt : m);
    return _copy(folders: {
      ...folders,
      id: FolderEntry(
          name: name,
          createdAt: _stamp(nowMs, latest),
          updatedAt: _stamp(nowMs, folders[id]?.updatedAt)),
    });
  }

  FolderDoc withFolderRenamed(String id, String name, int nowMs) {
    final f = folders[id];
    if (f == null || f.deleted || f.name == name) return this;
    return _copy(folders: {
      ...folders,
      id: f.copyWith(name: name, updatedAt: _stamp(nowMs, f.updatedAt)),
    });
  }

  FolderDoc withFolderDeleted(String id, int nowMs) {
    final f = folders[id];
    if (f == null || f.deleted) return this;
    return _copy(folders: {
      ...folders,
      id: f.copyWith(deleted: true, updatedAt: _stamp(nowMs, f.updatedAt)),
    });
  }

  /// Files [notebookId] into [folderId], or unfiles it with null.
  FolderDoc withAssignment(String notebookId, String? folderId, int nowMs) {
    final a = assignments[notebookId];
    if (a == null ? folderId == null : a.folderId == folderId) return this;
    return _copy(assignments: {
      ...assignments,
      notebookId: AssignmentEntry(
          folderId: folderId,
          updatedAt: _stamp(nowMs, a?.updatedAt),
          extra: a?.extra ?? const {}),
    });
  }

  FolderDoc _copy({
    Map<String, FolderEntry>? folders,
    Map<String, AssignmentEntry>? assignments,
  }) =>
      FolderDoc(
        version: version,
        folders: folders ?? this.folders,
        assignments: assignments ?? this.assignments,
        extra: extra,
      );
}
