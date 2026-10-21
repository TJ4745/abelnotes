import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:abelnotes/core/services/folder_merge.dart';
import 'package:abelnotes/shared/models/folder_doc.dart';

const _day = 24 * 3600 * 1000;
const _now = 1000 * _day;

// Small default `now`: nothing is old enough to be pruned unless a test says so.
FolderDoc _merge(FolderDoc a, FolderDoc b, {int now = 1000}) =>
    mergeFolderDocs(a, b, nowMs: now);

FolderDoc _doc(
    {Map<String, FolderEntry> folders = const {},
    Map<String, AssignmentEntry> assignments = const {}}) {
  return FolderDoc(folders: folders, assignments: assignments);
}

FolderEntry _f(String name, int t, {bool deleted = false, int? created}) =>
    FolderEntry(
        name: name, createdAt: created ?? t, updatedAt: t, deleted: deleted);

AssignmentEntry _a(String? folder, int t) =>
    AssignmentEntry(folderId: folder, updatedAt: t);

void main() {
  group('merge, two devices', () {
    test('concurrent creation of different folders keeps both', () {
      final a = FolderDoc.empty.withFolderCreated('fa', 'Math', _now - 50);
      final b = FolderDoc.empty.withFolderCreated('fb', 'Physics', _now - 40);
      final m = _merge(a, b);
      expect(m.folders.keys, {'fa', 'fb'});
      expect(m.liveFolders.map((e) => e.value.name), ['Math', 'Physics']);
    });

    test('renaming different folders on each device keeps both renames', () {
      final base = FolderDoc.empty
          .withFolderCreated('f1', 'One', 100)
          .withFolderCreated('f2', 'Two', 101);
      final a = base.withFolderRenamed('f1', 'Uno', 200);
      final b = base.withFolderRenamed('f2', 'Due', 210);
      final m = _merge(a, b);
      expect(m.folders['f1']!.name, 'Uno');
      expect(m.folders['f2']!.name, 'Due');
    });

    test('the same folder renamed twice: the later rename wins', () {
      final base = FolderDoc.empty.withFolderCreated('f1', 'One', 100);
      final a = base.withFolderRenamed('f1', 'A-name', 200);
      final b = base.withFolderRenamed('f1', 'B-name', 300);
      expect(_merge(a, b).folders['f1']!.name, 'B-name');
      expect(_merge(b, a).folders['f1']!.name, 'B-name');
    });

    test('assignments of different notebooks both survive', () {
      final base = FolderDoc.empty.withFolderCreated('f1', 'One', 100);
      final a = base.withAssignment('nb1', 'f1', 200);
      final b = base.withAssignment('nb2', 'f1', 201);
      expect(_merge(a, b).liveAssignments, {'nb1': 'f1', 'nb2': 'f1'});
    });

    test('a notebook moved on both devices: the later move wins', () {
      final base = FolderDoc.empty
          .withFolderCreated('f1', 'One', 100)
          .withFolderCreated('f2', 'Two', 101)
          .withAssignment('nb', 'f1', 110);
      final a = base.withAssignment('nb', 'f2', 200);
      final b = base.withAssignment('nb', null, 300);
      expect(_merge(a, b).liveAssignments, isEmpty);
      expect(_merge(b, a).liveAssignments, isEmpty);
    });

    test('a deleted folder disappears and its notebooks read as unfiled', () {
      final base = FolderDoc.empty
          .withFolderCreated('f1', 'One', 100)
          .withAssignment('nb', 'f1', 110);
      final deleted = base.withFolderDeleted('f1', 200);
      final m = _merge(base, deleted);
      expect(m.liveFolders, isEmpty);
      expect(m.liveAssignments, isEmpty);
      expect(m.folders['f1']!.deleted, isTrue);
    });

    test('a rename after the delete (concurrent) brings the folder back', () {
      final base = FolderDoc.empty
          .withFolderCreated('f1', 'One', 100)
          .withAssignment('nb', 'f1', 110);
      final deleted = base.withFolderDeleted('f1', 200);
      final renamed = base.withFolderRenamed('f1', 'Renamed', 300);
      for (final m in [_merge(deleted, renamed), _merge(renamed, deleted)]) {
        expect(m.liveFolders.single.value.name, 'Renamed');
        expect(m.liveAssignments, {'nb': 'f1'});
      }
    });

    test('a rename before the delete loses to the tombstone', () {
      final base = FolderDoc.empty.withFolderCreated('f1', 'One', 100);
      final renamed = base.withFolderRenamed('f1', 'Renamed', 200);
      final deleted = base.withFolderDeleted('f1', 300);
      expect(_merge(renamed, deleted).liveFolders, isEmpty);
    });

    test('assigning into a folder the other device deleted stays unfiled', () {
      final base = FolderDoc.empty.withFolderCreated('f1', 'One', 100);
      final deleted = base.withFolderDeleted('f1', 200);
      final assigned = base.withAssignment('nb', 'f1', 300);
      final m = _merge(deleted, assigned);
      expect(m.liveFolders, isEmpty);
      expect(m.liveAssignments, isEmpty);
      expect(m.assignments.containsKey('nb'), isTrue);
    });

    test('equal stamps break ties the same way on both sides', () {
      final a = _doc(folders: {'f': _f('alpha', 500)});
      final b = _doc(folders: {'f': _f('beta', 500)});
      expect(_merge(a, b).encodeString(), _merge(b, a).encodeString());
      expect(_merge(a, b).folders['f']!.name, 'beta');
      final del = _doc(folders: {'f': _f('alpha', 500, deleted: true)});
      expect(_merge(a, del).folders['f']!.deleted, isTrue);
      expect(_merge(del, a).folders['f']!.deleted, isTrue);
      final x = _doc(assignments: {'n': _a('f1', 500)});
      final y = _doc(assignments: {'n': _a('f2', 500)});
      expect(_merge(x, y).encodeString(), _merge(y, x).encodeString());
    });
  });

  group('clock skew', () {
    test('an edit on a slow clock still beats the version it was based on',
        () {
      // Remote entry stamped by a device whose clock runs far ahead.
      final ahead = FolderDoc.empty.withFolderCreated('f', 'Old', 9000);
      // This device's clock says 100: the stamp is bumped past 9000.
      final edited = ahead.withFolderRenamed('f', 'New', 100);
      expect(edited.folders['f']!.updatedAt, 9001);
      expect(_merge(ahead, edited).folders['f']!.name, 'New');
      expect(_merge(edited, ahead).folders['f']!.name, 'New');
    });

    test('assignment and delete stamps are bumped the same way', () {
      var d = FolderDoc.empty.withFolderCreated('f', 'x', 9000);
      d = d.withAssignment('nb', 'f', 9000);
      final unfiled = d.withAssignment('nb', null, 10);
      expect(unfiled.assignments['nb']!.updatedAt, 9001);
      final deleted = d.withFolderDeleted('f', 10);
      expect(deleted.folders['f']!.updatedAt, 9001);
    });

    test('a no-op edit changes nothing and keeps the same object', () {
      final d = FolderDoc.empty.withFolderCreated('f', 'x', 100);
      expect(identical(d.withFolderRenamed('f', 'x', 200), d), isTrue);
      expect(identical(d.withAssignment('nb', null, 200), d), isTrue);
      expect(identical(d.withFolderDeleted('ghost', 200), d), isTrue);
      expect(
          identical(d.withFolderDeleted('f', 200).withFolderDeleted('f', 300),
              d.withFolderDeleted('f', 200)),
          isFalse);
    });
  });

  group('algebra', () {
    final x = FolderDoc.empty
        .withFolderCreated('f1', 'One', _now - 500)
        .withFolderCreated('f2', 'Two', _now - 490)
        .withAssignment('n1', 'f1', _now - 480)
        .withAssignment('n2', 'f2', _now - 470);
    final y = x
        .withFolderRenamed('f1', 'Uno', _now - 300)
        .withAssignment('n1', 'f2', _now - 290)
        .withFolderCreated('f3', 'Three', _now - 280);
    final z = x
        .withFolderDeleted('f2', _now - 200)
        .withAssignment('n3', 'f1', _now - 190)
        .withFolderRenamed('f1', 'Eins', _now - 180);

    String s(FolderDoc d) => d.encodeString();

    test('idempotent', () {
      for (final d in [x, y, z, FolderDoc.empty]) {
        expect(s(_merge(d, d)), s(d));
      }
    });
    test('commutative', () {
      expect(s(_merge(x, y)), s(_merge(y, x)));
      expect(s(_merge(y, z)), s(_merge(z, y)));
      expect(s(_merge(x, z)), s(_merge(z, x)));
    });
    test('associative', () {
      expect(s(_merge(_merge(x, y), z)), s(_merge(x, _merge(y, z))));
      expect(s(_merge(_merge(y, z), x)), s(_merge(y, _merge(z, x))));
    });
    test('merging an old state back in changes nothing', () {
      final all = _merge(_merge(x, y), z);
      expect(s(_merge(all, x)), s(all));
      expect(s(_merge(all, y)), s(all));
    });
    test('empty is the identity', () {
      expect(s(_merge(y, FolderDoc.empty)), s(y));
      expect(s(_merge(FolderDoc.empty, FolderDoc.empty)),
          s(FolderDoc.empty));
    });
    test('createdAt is the smaller of the two so order is stable', () {
      final a = _doc(folders: {'f': _f('n', 700, created: 500)});
      final b = _doc(folders: {'f': _f('n', 800, created: 600)});
      expect(_merge(a, b).folders['f']!.createdAt, 500);
      expect(_merge(b, a).folders['f']!.createdAt, 500);
    });
  });

  group('tombstones', () {
    test('folder tombstones are kept for 90 days, then dropped', () {
      final old = _doc(folders: {
        'young': _f('y', _now - 89 * _day, deleted: true),
        'old': _f('o', _now - 91 * _day, deleted: true),
        'live': _f('l', _now - 400 * _day),
      });
      final m = _merge(old, FolderDoc.empty, now: _now);
      expect(m.folders.keys, {'young', 'live'});
    });

    test('unfiled markers go with the same ttl, live assignments never', () {
      final d = _doc(
        folders: {'f': _f('x', _now - 400 * _day)},
        assignments: {
          'gone': _a(null, _now - 91 * _day),
          'recent': _a(null, _now - 5 * _day),
          'filed': _a('f', _now - 400 * _day),
          'dangling': _a('missing', _now - 91 * _day),
          'danglingNew': _a('missing', _now - 1 * _day),
        },
      );
      final m = _merge(d, FolderDoc.empty, now: _now);
      expect(m.assignments.keys, {'recent', 'filed', 'danglingNew'});
    });

    test('assignments to notebooks unknown to this device are kept', () {
      final d = FolderDoc.empty
          .withFolderCreated('f', 'x', _now - 10)
          .withAssignment('nb-not-downloaded-here', 'f', _now - 9);
      expect(_merge(d, FolderDoc.empty, now: _now).liveAssignments,
          {'nb-not-downloaded-here': 'f'});
    });
  });

  group('format', () {
    test('empty remote document is the identity element', () {
      final d = FolderDoc.decode(utf8.encode('{"version":1}'));
      expect(d.isEmpty, isTrue);
      final local = FolderDoc.empty.withFolderCreated('f', 'x', 5);
      expect(_merge(d, local).folders.keys, {'f'});
    });

    test('unknown fields survive a decode, merge and encode round trip', () {
      const raw = '{"version":1,"color":"blue","folders":'
          '{"f":{"name":"x","createdAt":1,"updatedAt":2,"icon":"star"}},'
          '"assignments":{"n":{"folderId":"f","updatedAt":3,"pinned":true}}}';
      final remote = FolderDoc.decode(utf8.encode(raw));
      final local = FolderDoc.empty.withFolderCreated('g', 'y', 900);
      final out = jsonDecode(_merge(local, remote).encodeString())
          as Map<String, dynamic>;
      expect(out['color'], 'blue');
      expect(out['folders']['f']['icon'], 'star');
      expect(out['assignments']['n']['pinned'], true);
      expect(out['folders']['g']['name'], 'y');
    });

    test('a newer version is flagged and refuses to merge', () {
      final future =
          FolderDoc.decode(utf8.encode('{"version":2,"folders":{"f":7}}'));
      expect(future.isFuture, isTrue);
      expect(() => _merge(future, FolderDoc.empty), throwsArgumentError);
      expect(() => _merge(FolderDoc.empty, future), throwsArgumentError);
    });

    test('garbage is a FormatException, malformed entries are skipped', () {
      expect(() => FolderDoc.decode(utf8.encode('[1,2]')), throwsFormatException);
      expect(() => FolderDoc.decode(utf8.encode('nope')), throwsFormatException);
      final d = FolderDoc.decode(utf8.encode(
          '{"version":1,"folders":{"ok":{"name":"a","updatedAt":1},"bad":3}}'));
      expect(d.folders.keys, {'ok'});
    });

    test('encoding is deterministic regardless of insertion order', () {
      final a = _doc(folders: {'b': _f('b', 1), 'a': _f('a', 2)});
      final b = _doc(folders: {'a': _f('a', 2), 'b': _f('b', 1)});
      expect(a.encodeString(), b.encodeString());
      expect(a.sameContent(b), isTrue);
    });

    test('legacy local state migrates with the sentinel stamp and order', () {
      final d = FolderDoc.fromLegacy([
        (id: 'a', name: 'First'),
        (id: 'b', name: 'Second'),
      ], {'nb': 'b'});
      expect(d.liveFolders.map((e) => e.key), ['a', 'b']);
      expect(d.liveAssignments, {'nb': 'b'});
      expect(d.folders['a']!.updatedAt, FolderDoc.legacyStamp);
    });

    test('legacy entries lose to every real remote entry, either order', () {
      final legacy = FolderDoc.fromLegacy(
          [(id: 'f', name: 'Local name'), (id: 'dead', name: 'Gone')],
          {'nb': 'f', 'nb2': 'dead'});
      final remote = FolderDoc.empty
          .withFolderCreated('f', 'Remote name', 100)
          .withFolderCreated('dead', 'Gone', 100)
          .withFolderDeleted('dead', 200)
          .withFolderCreated('g', 'G', 100)
          .withAssignment('nb', 'g', 300);
      for (final m in [_merge(legacy, remote), _merge(remote, legacy)]) {
        expect(m.folders['f']!.name, 'Remote name');
        expect(m.liveAssignments, {'nb': 'g'});
        expect(m.folders['dead']!.deleted, isTrue, reason: 'not revived');
      }
    });

    test('legacy entries the remote lacks survive, and a real edit beats them',
        () {
      final legacy =
          FolderDoc.fromLegacy([(id: 'f', name: 'Only here')], {'nb': 'f'});
      final m = _merge(legacy, FolderDoc.empty.withFolderCreated('x', 'X', 50),
          now: 10 * _day);
      expect(m.liveFolders.map((e) => e.key), containsAll(['f', 'x']));
      expect(m.liveAssignments, {'nb': 'f'});
      final edited = m.withFolderRenamed('f', 'Renamed', 20);
      expect(_merge(edited, legacy, now: 10 * _day).folders['f']!.name,
          'Renamed');
    });
  });
}
