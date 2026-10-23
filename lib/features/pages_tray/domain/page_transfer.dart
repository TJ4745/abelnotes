import 'dart:math';

import 'package:uuid/uuid.dart';

import 'package:abelnotes/features/pages_tray/domain/pages_tray.dart';
import 'package:abelnotes/shared/models/ncnote_format.dart';

// Pure planners behind the pages tray; rationale in ../README.md.

/// Where pages land: after [afterPageId] (null = at the start), in
/// [chapterId] (null only in a notebook without chapters).
class PasteSlot {
  final String? afterPageId;
  final String? chapterId;
  const PasteSlot({this.afterPageId, this.chapterId});

  PasteSlot copyWith({String? chapterId}) =>
      PasteSlot(afterPageId: afterPageId, chapterId: chapterId ?? this.chapterId);

  @override
  bool operator ==(Object other) =>
      other is PasteSlot &&
      other.afterPageId == afterPageId &&
      other.chapterId == chapterId;

  @override
  int get hashCode => Object.hash(afterPageId, chapterId);

  @override
  String toString() => 'PasteSlot(after=$afterPageId, chapter=$chapterId)';
}

bool chapterExists(List<Chapter> chapters, String? id) =>
    id != null && chapters.any((c) => c.id == id);

/// Chapter for pages landing next to [tapped]: its own chapter, else the
/// first one. Null in a notebook without chapters.
String? chapterForPage(List<Chapter> chapters, PageEntry? tapped) {
  if (chapters.isEmpty) return null;
  return chapterExists(chapters, tapped?.chapterId)
      ? tapped!.chapterId
      : chapters.first.id;
}

/// Slot after [afterPageId] with the chapter of the page that was tapped.
PasteSlot slotAfter(List<Chapter> chapters, DocumentStructure doc,
    {required String? afterPageId, required String? tappedPageId}) {
  PageEntry? tapped;
  for (final e in doc.pages) {
    if (e.pageId == tappedPageId) tapped = e;
  }
  return PasteSlot(
      afterPageId: afterPageId, chapterId: chapterForPage(chapters, tapped));
}

/// End of [chapterId] (after its last page, else after the last page of the
/// notebook); flat notebooks end at the last page.
PasteSlot endOfChapterSlot(
    List<Chapter> chapters, DocumentStructure doc, String? chapterId) {
  final pages = doc.pages;
  final last = pages.isEmpty ? null : pages.last.pageId;
  if (chapters.isEmpty) return PasteSlot(afterPageId: last);
  final ch = chapterExists(chapters, chapterId) ? chapterId : chapters.last.id;
  final inCh = pages.where((p) => p.chapterId == ch).toList();
  return PasteSlot(
      afterPageId: inCh.isEmpty ? last : inCh.last.pageId, chapterId: ch);
}

/// Library card menu: the end of the last chapter.
PasteSlot appendSlot(List<Chapter> chapters, DocumentStructure doc) =>
    endOfChapterSlot(
        chapters, doc, chapters.isEmpty ? null : chapters.last.id);

/// Slot a freshly opened destination starts with: after the current page,
/// else the end of the last chapter, else the start.
PasteSlot defaultSlot(List<Chapter> chapters, DocumentStructure doc,
    {String? currentPageId}) {
  for (final e in doc.pages) {
    if (e.pageId == currentPageId) {
      return PasteSlot(
          afterPageId: e.pageId, chapterId: chapterForPage(chapters, e));
    }
  }
  if (doc.pages.isNotEmpty) return appendSlot(chapters, doc);
  return PasteSlot(chapterId: chapters.isEmpty ? null : chapters.first.id);
}

/// "After a page that is itself moving" means after the closest earlier page
/// that is not.
String? skipMoving(DocumentStructure doc, String? afterPageId, Set<String> ids) {
  if (afterPageId == null || !ids.contains(afterPageId)) return afterPageId;
  var i = doc.pages.indexWhere((e) => e.pageId == afterPageId);
  while (i >= 0 && ids.contains(doc.pages[i].pageId)) {
    i--;
  }
  return i >= 0 ? doc.pages[i].pageId : null;
}

int _indexAfter(List<PageEntry> pages, String? afterPageId) {
  if (afterPageId == null) return 0;
  final i = pages.indexWhere((e) => e.pageId == afterPageId);
  return i < 0 ? pages.length : i + 1;
}

/// Chapter the pages of [slot] get in a notebook with [chapters]: the slot's
/// if real, else the page it follows, else the first. Never invented.
String? resolveChapter(
    List<Chapter> chapters, DocumentStructure doc, PasteSlot slot) {
  if (chapters.isEmpty) return null;
  if (chapterExists(chapters, slot.chapterId)) return slot.chapterId;
  final i = _indexAfter(doc.pages, slot.afterPageId);
  final neighbour = i > 0 ? doc.pages[i - 1] : null;
  return chapterForPage(chapters, neighbour);
}

final _pageFileRe = RegExp(r'page_(\d+)(?:_[a-z0-9]+)?\.json');
final _rand = Random.secure();

String mintPageFileName(int number) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final tag =
      List.generate(4, (_) => chars[_rand.nextInt(chars.length)]).join();
  return 'page_${number.toString().padLeft(3, '0')}_$tag.json';
}

/// A page file name unused in [existing], numbered past the highest.
String nextPageFileName(Iterable<String> existing) {
  final names = existing.toList();
  var maxNum = names.length;
  for (final fn in names) {
    final m = _pageFileRe.firstMatch(fn);
    final n = m == null ? 0 : int.tryParse(m.group(1)!) ?? 0;
    if (n > maxNum) maxNum = n;
  }
  return mintPageFileName(maxNum + 1);
}

List<PageEntry> _renumbered(List<PageEntry> pages) => [
      for (var i = 0; i < pages.length; i++)
        pages[i].copyWith(pageNumber: i + 1),
    ];

/// Chapter membership lists rebuilt from the entries, as every save does.
List<Chapter> chaptersWithMembership(
    List<Chapter> chapters, DocumentStructure doc) {
  final byChapter = <String, List<String>>{};
  for (final e in doc.pages) {
    final cid = e.chapterId;
    if (cid != null) (byChapter[cid] ??= []).add(e.pageId);
  }
  return [
    for (final c in chapters)
      c.copyWith(pageIds: byChapter[c.id] ?? const <String>[]),
  ];
}

class InsertPlan {
  final DocumentStructure document;
  final List<PageEntry> newEntries;

  /// New page data by file name, pageId already updated.
  final Map<String, PageData> newPages;
  final int insertIndex;
  const InsertPlan(
      this.document, this.newEntries, this.newPages, this.insertIndex);

  List<String> get newPageIds => [for (final e in newEntries) e.pageId];
}

/// Inserts [pages] at [slot]. Fresh page ids and file names unless
/// [keepIdentity] (restoring pages a move took out), where each page also
/// keeps its own chapter while that chapter still exists. [pageIds] fixes
/// the new ids in advance (a crash journal needs them before the write).
InsertPlan planInsert({
  required DocumentStructure document,
  required List<Chapter> chapters,
  required List<TrayPage> pages,
  required PasteSlot slot,
  required DateTime now,
  bool keepIdentity = false,
  List<String>? pageIds,
}) {
  final chapter = resolveChapter(chapters, document, slot);
  final taken = {for (final e in document.pages) e.fileName};
  final ids = {for (final e in document.pages) e.pageId};
  final entries = <PageEntry>[];
  final data = <String, PageData>{};
  for (var i = 0; i < pages.length; i++) {
    final tp = pages[i];
    final reuse = keepIdentity &&
        !taken.contains(tp.entry.fileName) &&
        !ids.contains(tp.entry.pageId);
    final pageId = reuse
        ? tp.entry.pageId
        : (pageIds != null ? pageIds[i] : const Uuid().v4());
    final fileName = reuse ? tp.entry.fileName : nextPageFileName(taken);
    taken.add(fileName);
    ids.add(pageId);
    final ownChapter =
        keepIdentity && chapterExists(chapters, tp.entry.chapterId)
            ? tp.entry.chapterId
            : chapter;
    entries.add(PageEntry(
      pageId: pageId,
      pageNumber: 0,
      fileName: fileName,
      width: tp.entry.width,
      height: tp.entry.height,
      chapterId: chapters.isEmpty ? null : ownChapter,
      lastModified: now,
    ));
    data[fileName] = tp.data.copyWith(pageId: pageId, modifiedAt: now);
  }
  final at = _indexAfter(document.pages, slot.afterPageId);
  final list = [...document.pages]..insertAll(at, entries);
  final numbered = _renumbered(list);
  return InsertPlan(
      document.copyWith(pages: numbered),
      [for (var i = 0; i < entries.length; i++) numbered[at + i]],
      data,
      at);
}

class RemovedPage {
  final PageEntry entry;

  /// Closest earlier page that stayed, to put the page back after it.
  final String? afterPageId;
  const RemovedPage(this.entry, this.afterPageId);
}

class RemovePlan {
  final DocumentStructure document;
  final List<Chapter> chapters;
  final List<RemovedPage> removed;

  /// Set when every page was removed: the blank page that keeps the
  /// notebook from having none.
  final PageEntry? blankEntry;
  final PageData? blankData;
  const RemovePlan(this.document, this.chapters, this.removed, this.blankEntry,
      this.blankData);

  Set<String> get removedFileNames =>
      {for (final r in removed) r.entry.fileName};
}

/// Removes [pageIds]; those not in the document are ignored. A notebook
/// never ends with no page: if all go, one blank page of [paperType] stays.
RemovePlan planRemove({
  required DocumentStructure document,
  required List<Chapter> chapters,
  required Set<String> pageIds,
  required String paperType,
  required DateTime now,
}) {
  final removed = <RemovedPage>[];
  final kept = <PageEntry>[];
  String? lastKept;
  for (final e in document.pages) {
    if (pageIds.contains(e.pageId)) {
      removed.add(RemovedPage(e, lastKept));
    } else {
      kept.add(e);
      lastKept = e.pageId;
    }
  }
  PageEntry? blankEntry;
  PageData? blankData;
  if (kept.isEmpty && removed.isNotEmpty) {
    final id = const Uuid().v4();
    final fileName =
        nextPageFileName({for (final e in document.pages) e.fileName});
    final first = removed.first.entry;
    blankEntry = PageEntry(
      pageId: id,
      pageNumber: 1,
      fileName: fileName,
      width: first.width,
      height: first.height,
      chapterId: chapters.isEmpty ? null : chapters.first.id,
      lastModified: now,
    );
    blankData = PageData(
      pageId: id,
      pageNumber: 1,
      width: first.width,
      height: first.height,
      layers: RenderingLayers(
          background: BackgroundLayer(type: paperType), content: const []),
      createdAt: now,
      modifiedAt: now,
    );
    kept.add(blankEntry);
  }
  final doc = document.copyWith(pages: _renumbered(kept));
  return RemovePlan(doc, chaptersWithMembership(chapters, doc), removed,
      blankEntry, blankData);
}

/// Moves [pageIds] (kept in document order) to [slot] inside the notebook;
/// they take the slot's chapter. A slot after a moving page falls back to the
/// closest earlier page that stays.
DocumentStructure planMoveWithin({
  required DocumentStructure document,
  required List<Chapter> chapters,
  required Set<String> pageIds,
  required PasteSlot slot,
}) {
  final chapter = resolveChapter(chapters, document, slot);
  final after = skipMoving(document, slot.afterPageId, pageIds);
  final moving = [
    for (final e in document.pages)
      if (pageIds.contains(e.pageId))
        e.copyWith(chapterId: chapters.isEmpty ? null : chapter),
  ];
  final rest = [
    for (final e in document.pages)
      if (!pageIds.contains(e.pageId)) e,
  ];
  final at = _indexAfter(rest, after);
  rest.insertAll(at, moving);
  return document.copyWith(pages: _renumbered(rest));
}

/// Page order and chapters back to [before] for the pages still present;
/// pages added since stay where they are. Undo of an in-notebook move.
DocumentStructure restoreOrder(
    DocumentStructure current, List<PageEntry> before) {
  final byId = {for (final e in current.pages) e.pageId: e};
  final out = <PageEntry>[];
  final used = <String>{};
  for (final b in before) {
    final cur = byId[b.pageId];
    if (cur == null) continue;
    out.add(cur.copyWith(chapterId: b.chapterId));
    used.add(b.pageId);
  }
  for (final e in current.pages) {
    if (!used.contains(e.pageId)) out.add(e);
  }
  return current.copyWith(pages: _renumbered(out));
}

/// Title of the chapter all [pages] came from, if they share one.
({String? title, bool mixed}) sourceChapterInfo(
    List<Chapter> chapters, List<PageEntry> pages) {
  final ids = {for (final p in pages) p.chapterId};
  if (ids.length != 1) return (title: null, mixed: ids.length > 1);
  final id = ids.first;
  final ch = chapters.where((c) => c.id == id);
  return (title: ch.isEmpty ? null : ch.first.title, mixed: false);
}
