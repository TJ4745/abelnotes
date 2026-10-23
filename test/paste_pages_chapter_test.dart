// Pasted pages land in a chapter of the destination notebook, stay there
// through the save serialization and the sync merge, and cut pages leave
// no dead ids behind in the source chapters.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:abelnotes/core/providers/canvas_provider.dart';
import 'package:abelnotes/features/pages_tray/domain/page_transfer.dart';
import 'package:abelnotes/shared/models/ncnote_format.dart';

final _t0 = DateTime(2026);

PageData _page(String id) => PageData(
      pageId: id,
      pageNumber: 1,
      width: 595,
      height: 842,
      layers: const RenderingLayers(content: []),
    );

PageEntry _entry(String id, String? chapter) => PageEntry(
    pageId: id, pageNumber: 1, fileName: '$id.json', chapterId: chapter);

CanvasState _state(
  List<PageEntry> entries,
  List<String> chapterIds, {
  String? active,
  int current = 0,
}) =>
    CanvasState(
      metadata: NotebookMetadata(
        id: 'dest',
        title: 't',
        createdAt: _t0,
        modifiedAt: _t0,
        chapters: [for (final c in chapterIds) Chapter(id: c, title: c)],
      ),
      document: DocumentStructure(notebookId: 'dest', pages: entries),
      pages: {for (final e in entries) e.fileName: _page(e.pageId)},
      activeChapterId: active,
      currentPageIndex: current,
      remotePath: '',
    );

// Two chapters X (x1, x2) and Y (y1, y2), as in a typical notebook.
CanvasState _twoChapters({String? active, int current = 0}) => _state([
      _entry('x1', 'X'),
      _entry('x2', 'X'),
      _entry('y1', 'Y'),
      _entry('y2', 'Y'),
    ], ['X', 'Y'], active: active, current: current);

void main() {
  late ProviderContainer c;
  late CanvasNotifier n;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    c = ProviderContainer();
    n = c.read(canvasProvider.notifier);
  });
  tearDown(() => c.dispose());

  // Pages from ANOTHER notebook: chapter ids that don't exist here.
  List<String> pasteForeign([PasteSlot? slot]) => n.pastePages(
        pages: [_page('c1'), _page('c2')],
        entries: [_entry('c1', 'srcA'), _entry('c2', 'srcB')],
        slot: slot,
      );

  List<String?> chaptersOf(CanvasState s) =>
      [for (final e in s.document.pages) e.chapterId];

  test('cross-notebook paste joins the chapter of the slot, after its page',
      () {
    n.state = _twoChapters(active: 'X', current: 3);
    final ids = pasteForeign(
        const PasteSlot(afterPageId: 'x1', chapterId: 'X'));
    final s = n.state!;
    expect(chaptersOf(s), ['X', 'X', 'X', 'X', 'Y', 'Y']);
    expect(s.document.pages.map((e) => e.pageNumber), [1, 2, 3, 4, 5, 6]);
    expect(s.document.pages[1].pageId, ids[0]);
    expect(s.document.pages[2].pageId, ids[1]);
    expect(s.currentPageIndex, 1);
  });

  test('the slot chapter wins over the neighbours and the active chapter',
      () {
    n.state = _twoChapters(active: 'X', current: 0);
    pasteForeign(const PasteSlot(afterPageId: 'x2', chapterId: 'Y'));
    // Position is after x2, chapter is Y: the user chose both.
    expect(chaptersOf(n.state!), ['X', 'X', 'Y', 'Y', 'Y', 'Y']);
  });

  test('without a slot pages go to the end of the last chapter', () {
    n.state = _twoChapters(active: 'X', current: 0);
    pasteForeign();
    expect(chaptersOf(n.state!), ['X', 'X', 'Y', 'Y', 'Y', 'Y']);
    expect(n.state!.document.pages[4].chapterId, 'Y');
  });

  test('a slot chapter that does not exist falls back to the neighbour, '
      'never to no chapter', () {
    n.state = _twoChapters();
    pasteForeign(const PasteSlot(afterPageId: 'y1', chapterId: 'gone'));
    expect(chaptersOf(n.state!), ['X', 'X', 'Y', 'Y', 'Y', 'Y']);
    n.state = _twoChapters();
    pasteForeign(const PasteSlot());
    expect(chaptersOf(n.state!), ['X', 'X', 'X', 'X', 'Y', 'Y']);
  });

  test('notebook without chapters leaves pasted pages chapterless', () {
    n.state = _state([_entry('p1', null)], const []);
    pasteForeign();
    expect(chaptersOf(n.state!), [null, null, null]);
  });

  test('the source chapter is not kept even when its id exists here', () {
    n.state = _twoChapters(active: 'X', current: 0);
    n.pastePages(
      pages: [_page('c1'), _page('c2')],
      entries: [_entry('c1', 'Y'), _entry('c2', 'gone')],
      slot: const PasteSlot(afterPageId: 'x1', chapterId: 'X'),
    );
    final pasted = n.state!.document.pages
        .where((e) => !{'x1', 'x2', 'y1', 'y2'}.contains(e.pageId))
        .toList();
    expect(pasted.map((e) => e.chapterId), ['X', 'X']);
  });

  test('pasted pages get fresh ids and files; data follows the new id', () {
    n.state = _twoChapters();
    final ids = pasteForeign();
    final s = n.state!;
    expect(ids.toSet().length, 2);
    for (final e in s.document.pages.where((e) => ids.contains(e.pageId))) {
      expect(s.pages[e.fileName]!.pageId, e.pageId);
    }
    expect(s.pages.length, 6);
  });

  test('saved chapter membership and entries agree after a paste', () {
    n.state = _twoChapters(active: 'X', current: 3);
    pasteForeign(const PasteSlot(afterPageId: 'x2', chapterId: 'X'));
    final s = n.state!;
    final saved = CanvasNotifier.chaptersWithMembershipForTest(
        s.metadata.chapters, s.document);
    final ids = {for (final ch in saved) ch.id: ch.pageIds};
    final pastedIds =
        s.document.pages.skip(2).take(2).map((e) => e.pageId).toList();
    expect(ids['X'], ['x1', 'x2', ...pastedIds]);
    expect(ids['Y'], ['y1', 'y2']);
    // Every membership list entry points at a page whose entry agrees.
    for (final ch in saved) {
      for (final pid in ch.pageIds) {
        expect(s.document.pages.firstWhere((e) => e.pageId == pid).chapterId,
            ch.id);
      }
    }
  });

  test('pasted pages keep their chapter through the sync merge', () {
    n.state = _twoChapters(active: 'X', current: 3);
    final base = n.state!;
    pasteForeign(const PasteSlot(afterPageId: 'x2', chapterId: 'X'));
    final local = n.state!;
    Map<String, String?> chapterById(DocumentStructure d) =>
        {for (final e in d.pages) e.pageId: e.chapterId};
    final expectChapters = chapterById(local.document);
    final localMeta = local.metadata.copyWith(
        chapters: CanvasNotifier.chaptersWithMembershipForTest(
            local.metadata.chapters, local.document));
    // Server still has the pre-paste notebook.
    final merged = CanvasNotifier.merge3WayForTest(
      baseMeta: base.metadata,
      localMeta: localMeta,
      remoteMeta: base.metadata,
      baseDoc: base.document,
      localDoc: local.document,
      remoteDoc: base.document,
      survivingFileNames: local.pages.keys.toSet(),
    );
    expect(chapterById(merged.document), expectChapters);
    final x = merged.metadata.chapters.firstWhere((ch) => ch.id == 'X');
    expect(x.pageIds.length, 4);

    // First sync, no ancestor: same result.
    final first = CanvasNotifier.merge3WayForTest(
      baseMeta: null,
      localMeta: localMeta,
      remoteMeta: base.metadata,
      baseDoc: null,
      localDoc: local.document,
      remoteDoc: base.document,
      survivingFileNames: local.pages.keys.toSet(),
    );
    expect(chapterById(first.document), expectChapters);
  });

  test('cut (deletePages) purges the dead ids from the source chapters', () {
    n.state = _twoChapters();
    // Source chapters carry stale membership lists, as loaded from disk.
    n.state = n.state!.copyWith(
      metadata: n.state!.metadata.copyWith(chapters: [
        const Chapter(id: 'X', title: 'X', pageIds: ['x1', 'x2']),
        const Chapter(id: 'Y', title: 'Y', pageIds: ['y1', 'y2']),
      ]),
    );
    n.deletePages([1, 2]); // cut x2 and y1
    final m = n.state!.metadata.chapters;
    expect(m.firstWhere((ch) => ch.id == 'X').pageIds, ['x1']);
    expect(m.firstWhere((ch) => ch.id == 'Y').pageIds, ['y2']);
  });

  test('duplicatePage and assignPagesToChapter keep entries consistent', () {
    n.state = _twoChapters();
    n.duplicatePage(2); // y1
    expect(chaptersOf(n.state!), ['X', 'X', 'Y', 'Y', 'Y']);
    n.assignPagesToChapter([0, 4], 'Y');
    expect(chaptersOf(n.state!), ['Y', 'X', 'Y', 'Y', 'Y']);
    final s = n.state!;
    final saved = CanvasNotifier.chaptersWithMembershipForTest(
        s.metadata.chapters, s.document);
    expect(saved.firstWhere((ch) => ch.id == 'Y').pageIds.length, 4);
  });

  test('movePagesToSlot reorders, rechapters, keeps the page on screen', () {
    n.state = _twoChapters(current: 2); // on y1
    n.movePagesToSlot(
        {'x1'}, const PasteSlot(afterPageId: 'y2', chapterId: 'Y'));
    final s = n.state!;
    expect([for (final e in s.document.pages) e.pageId],
        ['x2', 'y1', 'y2', 'x1']);
    expect(chaptersOf(s), ['X', 'Y', 'Y', 'Y']);
    expect(s.document.pages[s.currentPageIndex].pageId, 'y1');
    expect(s.isDirty, isTrue);
  });

  test('restorePageOrder undoes movePagesToSlot', () {
    n.state = _twoChapters();
    final before = n.state!.document.pages;
    n.movePagesToSlot(
        {'x1', 'x2'}, const PasteSlot(afterPageId: 'y2', chapterId: 'Y'));
    n.restorePageOrder(before);
    final s = n.state!;
    expect([for (final e in s.document.pages) e.pageId],
        ['x1', 'x2', 'y1', 'y2']);
    expect(chaptersOf(s), ['X', 'X', 'Y', 'Y']);
  });

  test('deletePagesById removes by id and ignores unknown ids', () {
    n.state = _twoChapters();
    n.deletePagesById({'x2', 'nope'});
    expect([for (final e in n.state!.document.pages) e.pageId],
        ['x1', 'y1', 'y2']);
    expect(n.state!.metadata.pageCount, 3);
  });
}
