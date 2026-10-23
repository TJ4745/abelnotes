// Pure planners of the pages tray: where pages land, which chapter they
// get, insertion, removal and in-notebook moves.

import 'package:flutter_test/flutter_test.dart';
import 'package:abelnotes/features/pages_tray/domain/page_transfer.dart';
import 'package:abelnotes/features/pages_tray/domain/pages_tray.dart';
import 'package:abelnotes/shared/models/ncnote_format.dart';

final _t0 = DateTime(2026);

PageData _data(String id) => PageData(
    pageId: id,
    pageNumber: 1,
    width: 595,
    height: 842,
    layers: const RenderingLayers(content: []));

PageEntry _e(String id, String? ch) => PageEntry(
    pageId: id, pageNumber: 1, fileName: 'page_$id.json', chapterId: ch);

DocumentStructure _doc(List<PageEntry> e) =>
    DocumentStructure(notebookId: 'nb', pages: e);

List<Chapter> _chs(List<String> ids) =>
    [for (final c in ids) Chapter(id: c, title: 'T$c')];

TrayPage _tp(String id, [String? ch]) => TrayPage(_e(id, ch), _data(id));

List<String> _ids(DocumentStructure d) => [for (final e in d.pages) e.pageId];
List<String?> _chapters(DocumentStructure d) =>
    [for (final e in d.pages) e.chapterId];

// Chaptered notebook: X (x1 x2), Y (y1 y2).
DocumentStructure _xy() =>
    _doc([_e('x1', 'X'), _e('x2', 'X'), _e('y1', 'Y'), _e('y2', 'Y')]);

void main() {
  final xy = _chs(['X', 'Y']);

  group('chapter of the destination', () {
    test('tapped page decides, either side', () {
      final d = _xy();
      // Tap y1 centre: after y1, chapter Y.
      expect(slotAfter(xy, d, afterPageId: 'y1', tappedPageId: 'y1'),
          const PasteSlot(afterPageId: 'y1', chapterId: 'Y'));
      // Tap y1 left edge: after x2 but chapter still Y.
      expect(slotAfter(xy, d, afterPageId: 'x2', tappedPageId: 'y1'),
          const PasteSlot(afterPageId: 'x2', chapterId: 'Y'));
    });

    test('flat notebook stays flat, never a chapter', () {
      final d = _doc([_e('a', null), _e('b', null)]);
      expect(slotAfter(const [], d, afterPageId: 'a', tappedPageId: 'a')
          .chapterId, isNull);
      final plan = planInsert(
          document: d,
          chapters: const [],
          pages: [_tp('c', 'srcChapter')],
          slot: const PasteSlot(afterPageId: 'a', chapterId: 'srcChapter'),
          now: _t0);
      expect(_chapters(plan.document), [null, null, null]);
    });

    test('a chaptered notebook never yields no chapter', () {
      final d = _doc([_e('legacy', null), _e('x1', 'X')]);
      // Tapping a chapterless legacy page gives the first chapter.
      expect(chapterForPage(xy, d.pages.first), 'X');
      expect(chapterForPage(xy, null), 'X');
      // An unknown chapter in the slot is replaced by the neighbour's.
      final plan = planInsert(
          document: _xy(),
          chapters: xy,
          pages: [_tp('n', 'gone')],
          slot: const PasteSlot(afterPageId: 'y1', chapterId: 'gone'),
          now: _t0);
      expect(plan.newEntries.single.chapterId, 'Y');
      // No slot chapter at all and nothing before: first chapter.
      final atStart = planInsert(
          document: _xy(),
          chapters: xy,
          pages: [_tp('n', null)],
          slot: const PasteSlot(),
          now: _t0);
      expect(atStart.newEntries.single.chapterId, 'X');
    });

    test('source chapters are never recreated or reused by id', () {
      final plan = planInsert(
          document: _xy(),
          chapters: xy,
          pages: [_tp('n', 'srcOnly')],
          slot: const PasteSlot(afterPageId: 'x2', chapterId: 'X'),
          now: _t0);
      expect(plan.newEntries.single.chapterId, 'X');
    });
  });

  group('slots', () {
    test('default: after the current page, else end of last chapter', () {
      final d = _xy();
      expect(defaultSlot(xy, d, currentPageId: 'x2'),
          const PasteSlot(afterPageId: 'x2', chapterId: 'X'));
      expect(defaultSlot(xy, d),
          const PasteSlot(afterPageId: 'y2', chapterId: 'Y'));
      expect(defaultSlot(xy, _doc(const [])),
          const PasteSlot(afterPageId: null, chapterId: 'X'));
      expect(defaultSlot(const [], _doc(const [])), const PasteSlot());
    });

    test('end of a chapter that is empty goes after the last page', () {
      final d = _doc([_e('x1', 'X')]);
      expect(endOfChapterSlot(xy, d, 'Y'),
          const PasteSlot(afterPageId: 'x1', chapterId: 'Y'));
      expect(endOfChapterSlot(xy, _xy(), 'X'),
          const PasteSlot(afterPageId: 'x2', chapterId: 'X'));
    });

    test('append (library card) = end of the last chapter, flat = end', () {
      expect(appendSlot(xy, _xy()),
          const PasteSlot(afterPageId: 'y2', chapterId: 'Y'));
      final flat = _doc([_e('a', null), _e('b', null)]);
      expect(appendSlot(const [], flat), const PasteSlot(afterPageId: 'b'));
    });

    test('after a page that is moving falls back to the earlier one', () {
      final d = _xy();
      expect(skipMoving(d, 'x2', {'x2', 'x1'}), isNull);
      expect(skipMoving(d, 'y1', {'x2', 'y1'}), 'x1');
      expect(skipMoving(d, 'y2', {'x1'}), 'y2');
    });
  });

  group('insert', () {
    test('lands after the slot, renumbers, fresh ids and files', () {
      final d = _xy();
      final plan = planInsert(
          document: d,
          chapters: xy,
          pages: [_tp('a', 'S'), _tp('b', 'S')],
          slot: const PasteSlot(afterPageId: 'x1', chapterId: 'X'),
          now: _t0);
      expect(_ids(plan.document).sublist(0, 1), ['x1']);
      expect(plan.insertIndex, 1);
      expect(plan.document.pages.length, 6);
      expect(plan.document.pages.map((e) => e.pageNumber), [1, 2, 3, 4, 5, 6]);
      expect(_chapters(plan.document), ['X', 'X', 'X', 'X', 'Y', 'Y']);
      final fresh = plan.newEntries;
      expect(fresh.map((e) => e.pageId).toSet().length, 2);
      expect(fresh.every((e) => e.pageId != 'a' && e.pageId != 'b'), isTrue);
      expect(plan.newPages.keys.toSet(), fresh.map((e) => e.fileName).toSet());
      for (final e in fresh) {
        expect(plan.newPages[e.fileName]!.pageId, e.pageId);
      }
      expect(plan.document.pages[1].pageId, fresh[0].pageId);
    });

    test('at the start, and after an unknown page = at the end', () {
      final start = planInsert(
          document: _xy(),
          chapters: xy,
          pages: [_tp('a')],
          slot: const PasteSlot(chapterId: 'X'),
          now: _t0);
      expect(start.insertIndex, 0);
      final unknown = planInsert(
          document: _xy(),
          chapters: xy,
          pages: [_tp('a')],
          slot: const PasteSlot(afterPageId: 'nope', chapterId: 'X'),
          now: _t0);
      expect(unknown.insertIndex, 4);
    });

    test('keepIdentity restores ids, files and own chapters', () {
      final plan = planInsert(
          document: _doc([_e('x1', 'X')]),
          chapters: xy,
          pages: [_tp('p', 'Y'), _tp('q', 'gone')],
          slot: const PasteSlot(afterPageId: 'x1', chapterId: 'X'),
          now: _t0,
          keepIdentity: true);
      expect(_ids(plan.document), ['x1', 'p', 'q']);
      expect(plan.newEntries.map((e) => e.fileName),
          ['page_p.json', 'page_q.json']);
      expect(_chapters(plan.document), ['X', 'Y', 'X']);
    });

    test('keepIdentity mints new ids when they are taken', () {
      final plan = planInsert(
          document: _doc([_e('p', 'X')]),
          chapters: xy,
          pages: [_tp('p', 'X')],
          slot: const PasteSlot(afterPageId: 'p', chapterId: 'X'),
          now: _t0,
          keepIdentity: true);
      expect(plan.newEntries.single.pageId, isNot('p'));
      expect(plan.newEntries.single.fileName, isNot('page_p.json'));
    });

    test('page size of the source entry is kept', () {
      final big = TrayPage(
          const PageEntry(
              pageId: 'big',
              pageNumber: 1,
              fileName: 'page_big.json',
              width: 6000,
              height: 6000),
          _data('big'));
      final plan = planInsert(
          document: _xy(),
          chapters: xy,
          pages: [big],
          slot: const PasteSlot(afterPageId: 'x1', chapterId: 'X'),
          now: _t0);
      expect(plan.newEntries.single.width, 6000);
    });
  });

  group('remove', () {
    test('drops pages, renumbers, purges chapter pageIds', () {
      final d = _xy();
      final chapters = [
        const Chapter(id: 'X', title: 'X', pageIds: ['x1', 'x2']),
        const Chapter(id: 'Y', title: 'Y', pageIds: ['y1', 'y2']),
      ];
      final plan = planRemove(
          document: d,
          chapters: chapters,
          pageIds: {'x2', 'y1', 'ghost'},
          paperType: 'lined',
          now: _t0);
      expect(_ids(plan.document), ['x1', 'y2']);
      expect(plan.document.pages.map((e) => e.pageNumber), [1, 2]);
      expect(plan.chapters[0].pageIds, ['x1']);
      expect(plan.chapters[1].pageIds, ['y2']);
      expect(plan.removed.map((r) => r.entry.pageId), ['x2', 'y1']);
      expect(plan.removed.map((r) => r.afterPageId), ['x1', 'x1']);
      expect(plan.removedFileNames, {'page_x2.json', 'page_y1.json'});
      expect(plan.blankEntry, isNull);
    });

    test('removing everything leaves one blank page', () {
      final plan = planRemove(
          document: _xy(),
          chapters: xy,
          pageIds: {'x1', 'x2', 'y1', 'y2'},
          paperType: 'grid',
          now: _t0);
      expect(plan.document.pages.length, 1);
      expect(plan.blankEntry!.chapterId, 'X');
      expect(plan.blankData!.layers.background.type, 'grid');
      expect(plan.blankData!.layers.content, isEmpty);
      expect(plan.document.pages.single.pageId, plan.blankEntry!.pageId);
    });

    test('removing nothing changes nothing', () {
      final plan = planRemove(
          document: _xy(),
          chapters: xy,
          pageIds: {'zz'},
          paperType: 'lined',
          now: _t0);
      expect(_ids(plan.document), ['x1', 'x2', 'y1', 'y2']);
      expect(plan.removed, isEmpty);
      expect(plan.blankEntry, isNull);
    });

    test('remove then insert with keepIdentity round-trips', () {
      final d = _xy();
      final plan = planRemove(
          document: d,
          chapters: xy,
          pageIds: {'x2', 'y1'},
          paperType: 'lined',
          now: _t0);
      var doc = plan.document;
      for (final r in plan.removed.reversed) {
        doc = planInsert(
                document: doc,
                chapters: xy,
                pages: [TrayPage(r.entry, _data(r.entry.pageId))],
                slot: PasteSlot(afterPageId: r.afterPageId, chapterId: 'X'),
                now: _t0,
                keepIdentity: true)
            .document;
      }
      expect(_ids(doc), ['x1', 'x2', 'y1', 'y2']);
      expect(_chapters(doc), ['X', 'X', 'Y', 'Y']);
    });
  });

  group('move inside a notebook', () {
    test('position and chapter follow the slot', () {
      final doc = planMoveWithin(
          document: _xy(),
          chapters: xy,
          pageIds: {'x1'},
          slot: const PasteSlot(afterPageId: 'y1', chapterId: 'Y'));
      expect(_ids(doc), ['x2', 'y1', 'x1', 'y2']);
      expect(_chapters(doc), ['X', 'Y', 'Y', 'Y']);
      expect(doc.pages.map((e) => e.pageNumber), [1, 2, 3, 4]);
    });

    test('slot after a moving page uses the earlier page', () {
      final doc = planMoveWithin(
          document: _xy(),
          chapters: xy,
          pageIds: {'x2', 'y1'},
          slot: const PasteSlot(afterPageId: 'y1', chapterId: 'Y'));
      // y1 moves too: lands after x1 (closest earlier page that stays).
      expect(_ids(doc), ['x1', 'x2', 'y1', 'y2']);
      expect(_chapters(doc), ['X', 'Y', 'Y', 'Y']);
    });

    test('to the start; moving pages keep their relative order', () {
      final doc = planMoveWithin(
          document: _xy(),
          chapters: xy,
          pageIds: {'y2', 'x2'},
          slot: const PasteSlot(chapterId: 'X'));
      expect(_ids(doc), ['x2', 'y2', 'x1', 'y1']);
    });

    test('flat notebook gets no chapter', () {
      final doc = planMoveWithin(
          document: _doc([_e('a', 'stale'), _e('b', null)]),
          chapters: const [],
          pageIds: {'a'},
          slot: const PasteSlot(afterPageId: 'b'));
      expect(_ids(doc), ['b', 'a']);
      expect(_chapters(doc), [null, null]);
    });

    test('restoreOrder undoes it and keeps pages added since', () {
      final before = _xy();
      final moved = planMoveWithin(
          document: before,
          chapters: xy,
          pageIds: {'x1'},
          slot: const PasteSlot(afterPageId: 'y2', chapterId: 'Y'));
      final withNew = moved.copyWith(pages: [...moved.pages, _e('new', 'Y')]);
      final back = restoreOrder(withNew, before.pages);
      expect(_ids(back), ['x1', 'x2', 'y1', 'y2', 'new']);
      expect(_chapters(back), ['X', 'X', 'Y', 'Y', 'Y']);
    });
  });

  group('chapter info of the source', () {
    test('one chapter, several, none', () {
      final one = [_e('a', 'X'), _e('b', 'X')];
      expect(sourceChapterInfo(xy, one).title, 'TX');
      final mixed = [_e('a', 'X'), _e('b', 'Y')];
      expect(sourceChapterInfo(xy, mixed).mixed, isTrue);
      expect(sourceChapterInfo(xy, [_e('a', null)]).title, isNull);
      expect(sourceChapterInfo(xy, [_e('a', null)]).mixed, isFalse);
    });
  });

  test('file names are unique and numbered past the highest', () {
    final a = nextPageFileName(['page_001.json', 'page_007_abcd.json']);
    expect(a.startsWith('page_008_'), isTrue);
    expect(nextPageFileName(const []).startsWith('page_001_'), isTrue);
  });
}
