// Flows of the pages tray against real loose stores: copy, move (this
// notebook, into an open notebook, into a closed one), cancel, Undo, restart,
// crash recovery, deleted source, and the failures that must lose nothing.

// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:abelnotes/core/providers/canvas_provider.dart';
import 'package:abelnotes/core/providers/offline_providers.dart';
import 'package:abelnotes/core/services/file_service.dart';
import 'package:abelnotes/features/pages_tray/application/pages_tray_provider.dart';
import 'package:abelnotes/features/pages_tray/data/closed_notebook_editor.dart';
import 'package:abelnotes/features/pages_tray/data/tray_store.dart';
import 'package:abelnotes/features/pages_tray/domain/page_transfer.dart';
import 'package:abelnotes/features/pages_tray/domain/pages_tray.dart';
import 'package:abelnotes/shared/models/ncnote_format.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
}

/// A canvas whose save writes the loose store like the real one does.
class _TestCanvas extends CanvasNotifier {
  _TestCanvas(super.ref, this.fs);
  final FileService fs;
  bool failSave = false;

  @override
  Future<bool> saveLocally() async {
    final s = state;
    if (s == null || failSave) return false;
    final meta = s.metadata.copyWith(
        chapters: chaptersWithMembership(s.metadata.chapters, s.document),
        pageCount: s.document.pages.length);
    final dir = fs.notebookStoreDir(meta.id);
    final onDisk = Directory(p.join(dir, 'pages')).existsSync()
        ? Directory(p.join(dir, 'pages'))
            .listSync()
            .map((f) => p.basename(f.path))
            .toSet()
        : <String>{};
    await fs.saveNotebookIncremental(
      meta.id,
      metadataJson: Uint8List.fromList(utf8.encode(jsonEncode(meta.toJson()))),
      documentJson:
          Uint8List.fromList(utf8.encode(jsonEncode(s.document.toJson()))),
      changedPages: {
        for (final e in s.pages.entries)
          e.key: Uint8List.fromList(utf8.encode(compactPageJson(e.value))),
      },
      changedAssets: Map.of(s.assetBytes),
      deletedPages: [
        for (final f in onDisk)
          if (!s.pages.containsKey(f)) f
      ],
    );
    state = state!.copyWith(isDirty: false);
    return true;
  }
}

final _t0 = DateTime(2026);

PageData _data(String id, {String? asset}) => PageData(
    pageId: id,
    pageNumber: 1,
    width: 595,
    height: 842,
    layers: RenderingLayers(content: [
      ContentElement.stroke(
          id: 's$id',
          zIndex: 1,
          data: const StrokeData(points: [StrokePoint(x: 1, y: 2)])),
      if (asset != null)
        ContentElement.image(
            id: 'i$id',
            zIndex: 2,
            data: ImageData(
                x: 0, y: 0, width: 5, height: 5, assetPath: asset)),
    ]),
    assetReferences: [if (asset != null) asset]);

PageEntry _e(String id, String? ch) => PageEntry(
    pageId: id, pageNumber: 1, fileName: 'page_$id.json', chapterId: ch);

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  late Directory tmp;
  late FileService fs;
  late ProviderContainer c;
  late _TestCanvas canvas;
  late TrayStore store;
  late PagesTrayController tray;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  PagesTrayController newController(ProviderContainer cc, TrayStore st) {
    final provider = StateNotifierProvider<PagesTrayController, PagesTrayState>(
        (ref) => PagesTrayController(ref,
            store: st,
            renderThumbs: (_, __) async => const [[1, 2, 3]],
            reloadLibrary: () async {},
            pushClosedNotebooks: () async {}));
    return cc.read(provider.notifier);
  }

  ProviderContainer newContainer() => ProviderContainer(overrides: [
        fileServiceProvider.overrideWithValue(fs),
        canvasProvider.overrideWith((ref) => _TestCanvas(ref, fs)),
      ]);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('tray_ctrl_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    fs = FileService();
    await fs.init();
    c = newContainer();
    canvas = c.read(canvasProvider.notifier) as _TestCanvas;
    store = TrayStore(p.join(tmp.path, 'pages_tray'));
    tray = newController(c, store);
  });
  tearDown(() async {
    c.dispose();
    await tmp.delete(recursive: true);
  });

  // Notebook `id`: pages as [(id, chapter)], chapters, asset on page `img`.
  Future<void> seed(String id, List<(String, String?)> pages,
      List<String> chapters, {String? imgOn}) async {
    final es = [for (final (pid, ch) in pages) _e(pid, ch)];
    final doc = DocumentStructure(notebookId: id, pages: es);
    final meta = NotebookMetadata(
        id: id,
        title: 'NB $id',
        createdAt: _t0,
        modifiedAt: _t0,
        pageCount: es.length,
        chapters: chaptersWithMembership(
            [for (final ch in chapters) Chapter(id: ch, title: 'T$ch')], doc));
    await fs.saveNotebookIncremental(
      id,
      metadataJson: _b(jsonEncode(meta.toJson())),
      documentJson: _b(jsonEncode(doc.toJson())),
      changedPages: {
        for (final e in es)
          e.fileName: _b(compactPageJson(
              _data(e.pageId, asset: e.pageId == imgOn ? 'img-$id' : null))),
      },
      changedAssets: imgOn == null ? const {} : {'img-$id': _b('IMG-$id')},
    );
    await fs.upsertNotebookMeta(
        id: id,
        title: meta.title,
        remotePath: '/AbelNotes/$id.ncnote',
        localModifiedAt: _t0,
        pageCount: es.length);
  }

  CanvasState load(String id) {
    final dir = fs.notebookStoreDir(id);
    final meta = NotebookMetadata.fromJson(
        jsonDecode(File(p.join(dir, 'metadata.json')).readAsStringSync())
            as Map<String, dynamic>);
    final doc = DocumentStructure.fromJson(
        jsonDecode(File(p.join(dir, 'document.json')).readAsStringSync())
            as Map<String, dynamic>);
    final pages = <String, PageData>{
      for (final e in doc.pages)
        e.fileName: decodePageData(jsonDecode(
                File(p.join(dir, 'pages', e.fileName)).readAsStringSync())
            as Map<String, dynamic>),
    };
    final assets = <String, Uint8List>{};
    final ad = Directory(p.join(dir, 'assets'));
    if (ad.existsSync()) {
      for (final f in ad.listSync()) {
        assets[p.basename(f.path)] = File(f.path).readAsBytesSync();
      }
    }
    return CanvasState(
        metadata: meta,
        document: doc,
        pages: pages,
        assetBytes: assets,
        remotePath: '');
  }

  void open(String id) => canvas.state = load(id);

  DocumentStructure docOf(String id) => DocumentStructure.fromJson(jsonDecode(
          File(p.join(fs.notebookStoreDir(id), 'document.json'))
              .readAsStringSync())
      as Map<String, dynamic>);
  List<String> ids(String id) => [for (final e in docOf(id).pages) e.pageId];
  List<String?> chs(String id) =>
      [for (final e in docOf(id).pages) e.chapterId];
  bool hasFile(String id, String fn) =>
      File(p.join(fs.notebookStoreDir(id), 'pages', fn)).existsSync();

  // A: X(x1 x2 x3) Y(y1) with an image on x2.  B: P(p1 p2) Q(q1).  F: flat.
  Future<void> seedAll() async {
    await seed('A', [('x1', 'X'), ('x2', 'X'), ('x3', 'X'), ('y1', 'Y')],
        ['X', 'Y'], imgOn: 'x2');
    await seed('B', [('p1', 'P'), ('p2', 'P'), ('q1', 'Q')], ['P', 'Q']);
    await seed('F', [('f1', null), ('f2', null)], const []);
  }

  Future<void> takeFromA(TrayMode mode, Set<int> idx) async {
    open('A');
    final r = await tray.capture(mode, canvas.state!, idx);
    expect(r, CaptureResult.ok);
    canvas.state = null; // the editor closes before the library is used
  }

  group('capture', () {
    test('copy and move leave the source untouched and fill the tray',
        () async {
      await seedAll();
      final before = docOf('A').toJson();
      await takeFromA(TrayMode.copy, {1, 2});
      var t = tray.state.tray!;
      expect(t.mode, TrayMode.copy);
      expect(t.pages.map((e) => e.pageId), ['x2', 'x3']);
      expect(t.sourceNotebookId, 'A');
      expect(t.sourceChapterTitle, 'TX');
      expect(t.assetIds, {'img-A'});
      expect(tray.state.toast, isNull, reason: 'the panel says it, no toast');
      expect(tray.state.tray!.saved, isTrue);
      await takeFromA(TrayMode.move, {0, 3});
      t = tray.state.tray!;
      expect(t.mode, TrayMode.move, reason: 'a new batch replaces the old');
      expect(t.pages.map((e) => e.pageId), ['x1', 'y1']);
      expect(t.mixedChapters, isTrue);
      expect(tray.state.toast, isNull);
      expect(docOf('A').toJson(), before);
      expect(hasFile('A', 'page_x1.json'), isTrue);
    });

    test('pages that are not loaded or lack an asset are skipped, counted',
        () async {
      await seedAll();
      open('A');
      final s = canvas.state!;
      final broken = s.copyWith(
          pages: Map.of(s.pages)..remove('page_x1.json'),
          assetBytes: <String, Uint8List>{});
      final r = await tray.capture(TrayMode.copy, broken, {0, 1, 2});
      expect(r, CaptureResult.ok);
      expect(tray.state.tray!.pages.map((e) => e.pageId), ['x3']);
      expect(tray.state.toast!.skipped, 2);
    });

    test('nothing capturable and over the cap change no tray', () async {
      await seedAll();
      open('A');
      expect(await tray.capture(TrayMode.copy, canvas.state!, {99}),
          CaptureResult.nothing);
      expect(tray.state.tray, isNull);
      final many = [
        for (var i = 0; i < kTrayPageCap + 1; i++) _e('m$i', null)
      ];
      final s = CanvasState(
          metadata: canvas.state!.metadata,
          document: DocumentStructure(notebookId: 'A', pages: many),
          pages: {for (final e in many) e.fileName: _data(e.pageId)},
          remotePath: '');
      expect(
          await tray.capture(TrayMode.copy, s, {for (var i = 0; i < kTrayPageCap + 1; i++) i}),
          CaptureResult.tooMany);
      expect(tray.state.tray, isNull);
      expect(tray.state.toast!.event, TrayEvent.tooMany);
    });

    test('the tray survives a restart and can still be pasted', () async {
      await seedAll();
      await takeFromA(TrayMode.move, {1});
      final second = newController(c, store);
      await second.start();
      expect(second.state.tray!.pages.single.pageId, 'x2');
      expect(second.state.tray!.mode, TrayMode.move);
      expect(second.state.tray!.saved, isTrue);
      final r = await second.pasteIntoClosed('B');
      expect(r.status, PasteStatus.ok);
      expect(ids('A'), ['x1', 'x3', 'y1']);
      expect(ids('B').length, 4);
    });
  });

  group('cancel', () {
    test('cancelling a move removes nothing; clearing a copy clears it',
        () async {
      await seedAll();
      final before = docOf('A').toJson();
      await takeFromA(TrayMode.move, {0, 1});
      await tray.cancel();
      expect(tray.state.tray, isNull);
      expect(tray.state.toast!.event, TrayEvent.moveCancelled);
      expect(docOf('A').toJson(), before);
      expect(await store.read(), isNull);
      await takeFromA(TrayMode.copy, {0});
      await tray.cancel();
      expect(tray.state.toast!.event, TrayEvent.trayCleared);
    });
  });

  group('move into a closed notebook (library card)', () {
    test('the undo toast goes once the user moves on', () async {
      await seedAll();
      await takeFromA(TrayMode.move, {1});
      await tray.pasteIntoClosed('B');
      expect(tray.state.toast!.canUndo, isTrue);
      tray.holdToast(true);
      tray.holdToast(false);
      expect(tray.state.toast, isNotNull, reason: 'hover alone keeps it');
      tray.dismissUndoToast();
      expect(tray.state.toast, isNull);
      // Let the graveyard purge it starts finish before the temp dir goes.
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    test('moving on leaves a toast without undo alone', () async {
      await seedAll();
      await takeFromA(TrayMode.copy, {1});
      tray.dismissUndoToast();
      expect(tray.state.toast?.canUndo ?? false, isFalse);
    });

    test('destination gains the pages at the end of its last chapter, '
        'source loses them, tray is consumed', () async {
      await seedAll();
      await takeFromA(TrayMode.move, {1, 2});
      final r = await tray.pasteIntoClosed('B');
      expect(r.status, PasteStatus.ok);
      expect(ids('A'), ['x1', 'y1']);
      expect(ids('B').sublist(0, 3), ['p1', 'p2', 'q1']);
      expect(ids('B').sublist(3), r.newPageIds);
      expect(chs('B'), ['P', 'P', 'Q', 'Q', 'Q']);
      // The asset travelled.
      expect(
          File(p.join(fs.notebookStoreDir('B'), 'assets', 'img-A'))
              .readAsStringSync(),
          'IMG-A');
      expect(tray.state.tray, isNull);
      expect(await store.read(), isNull);
      expect(tray.state.toast!.event, TrayEvent.moved);
      expect(tray.state.toast!.canUndo, isTrue);
      expect(tray.state.toast!.showNotebookId, 'B');
      // Both are marked for the sync.
      expect(await fs.dirtyPagesOf('A'), contains('doc'));
      expect(await fs.dirtyPagesOf('B'), containsAll(['doc', 'asset:img-A']));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('pending_page_deletes_A')!.toSet(),
          {'page_x2.json', 'page_x3.json'});
      // Source chapter membership and count agree.
      final meta = jsonDecode(File(p.join(fs.notebookStoreDir('A'), 'metadata.json'))
          .readAsStringSync()) as Map;
      expect(meta['pageCount'], 2);
    });

    test('into a flat notebook the pages stay chapterless', () async {
      await seedAll();
      await takeFromA(TrayMode.move, {0});
      await tray.pasteIntoClosed('F');
      expect(chs('F'), [null, null, null]);
    });

    test('a copy stays in the tray and can be pasted again', () async {
      await seedAll();
      await takeFromA(TrayMode.copy, {0});
      final a = await tray.pasteIntoClosed('B');
      final b = await tray.pasteIntoClosed('F');
      expect(a.newPageIds.single, isNot(b.newPageIds.single));
      expect(ids('A'), ['x1', 'x2', 'x3', 'y1']);
      expect(tray.state.tray!.mode, TrayMode.copy);
      expect(tray.state.toast!.event, TrayEvent.pasted);
      expect(await store.read(), isNotNull);
    });

    test('moving every page leaves the source one blank page', () async {
      await seedAll();
      await takeFromA(TrayMode.move, {0, 1, 2, 3});
      await tray.pasteIntoClosed('B');
      expect(ids('A').length, 1);
      expect(ids('B').length, 7);
    });
  });

  group('move into the open notebook', () {
    test('slot decides position and chapter; saved before the source is '
        'edited', () async {
      await seedAll();
      await takeFromA(TrayMode.move, {1});
      open('B');
      final slot = slotAfter(canvas.state!.metadata.chapters,
          canvas.state!.document,
          afterPageId: 'p1', tappedPageId: 'p1');
      final r = await tray.pasteIntoOpen(slot);
      expect(r.status, PasteStatus.ok);
      expect(ids('B'), ['p1', r.newPageIds.single, 'p2', 'q1']);
      expect(chs('B'), ['P', 'P', 'P', 'Q']);
      expect(ids('A'), ['x1', 'x3', 'y1']);
      expect(canvas.state!.document.pages.length, 4);
      expect(tray.state.landing!.pageIds, r.newPageIds.toSet());
      expect(tray.state.toast!.where!.kind, TrayWhereKind.afterPage);
      expect(tray.state.toast!.where!.page, 1);
      expect(tray.state.toast!.showNotebookId, isNull);
      expect(File(p.join(fs.notebookStoreDir('B'), 'assets', 'img-A'))
          .existsSync(), isTrue);
    });

    test('a failed local save changes nothing: no source edit, tray intact',
        () async {
      await seedAll();
      await takeFromA(TrayMode.move, {1});
      open('B');
      canvas.failSave = true;
      final r = await tray.pasteIntoOpen(
          const PasteSlot(afterPageId: 'p1', chapterId: 'P'));
      expect(r.status, PasteStatus.destFailed);
      expect(ids('A'), ['x1', 'x2', 'x3', 'y1']);
      expect(canvas.state!.document.pages.length, 3, reason: 'rolled back');
      expect(tray.state.tray!.mode, TrayMode.move);
      expect(tray.state.tray!.journal, isNull);
      expect((await store.read())!.journal, isNull);
      expect(tray.state.toast!.event, TrayEvent.pasteDestFailed);
    });
  });

  group('failures lose nothing', () {
    test('source edit fails: pages are in both, the tray becomes a copy',
        () async {
      await seedAll();
      await takeFromA(TrayMode.move, {1});
      File(p.join(fs.notebookStoreDir('A'), 'document.json'))
          .writeAsStringSync('{broken');
      final r = await tray.pasteIntoClosed('B');
      expect(r.status, PasteStatus.sourceFailed);
      expect(ids('B').length, 4);
      expect(hasFile('A', 'page_x2.json'), isTrue);
      expect(tray.state.tray!.mode, TrayMode.copy);
      expect((await store.read())!.mode, TrayMode.copy);
      expect(tray.state.toast!.event, TrayEvent.moveSourceFailed);
      expect(tray.state.toast!.canUndo, isFalse);
    });

    test('destination unavailable: nothing removed, tray intact', () async {
      await seedAll();
      await takeFromA(TrayMode.move, {1});
      final r = await tray.pasteIntoClosed('nope');
      expect(r.status, PasteStatus.destUnavailable);
      expect(ids('A'), ['x1', 'x2', 'x3', 'y1']);
      expect(tray.state.tray!.mode, TrayMode.move);
      expect((await store.read())!.journal, isNull);
    });

    test('a destination edited under us is refused', () async {
      await seedAll();
      await takeFromA(TrayMode.move, {1});
      open('B');
      final r = await tray.pasteIntoClosed('B');
      expect(r.status, PasteStatus.destUnavailable);
      expect(ids('A').length, 4);
    });

    test('a damaged tray (asset missing on disk) pastes nothing', () async {
      await seedAll();
      await takeFromA(TrayMode.move, {1});
      File(p.join(store.root, 'assets', 'img-A')).deleteSync();
      final r = await tray.pasteIntoClosed('B');
      expect(r.status, PasteStatus.trayDamaged);
      expect(ids('A').length, 4);
      expect(ids('B').length, 3);
    });
  });

  group('crash recovery', () {
    test('after the destination was written the restart finishes the '
        'removal', () async {
      await seedAll();
      await takeFromA(TrayMode.move, {1, 2});
      // Simulate: journal written, destination written, crash before removal.
      final t = tray.state.tray!;
      final newIds = ['n1', 'n2'];
      await store.updateManifest(
          t.copyWith(journal: TrayJournal('B', newIds)));
      // The destination write itself (as the controller does it).
      await ClosedNotebookEditor(fs, isOpenInEditor: (_) => false)
          .insertPages('B', t.pages, const {}, const PasteSlot(),
              pageIds: newIds);
      expect(ids('A').length, 4);
      final restarted = newController(c, store);
      await restarted.start();
      expect(ids('A'), ['x1', 'y1']);
      expect(restarted.state.tray, isNull);
      expect(restarted.state.toast!.event, TrayEvent.moveResumed);
      expect(ids('B').length, 5);
    });

    test('a journal whose destination never got the pages is dropped, the '
        'move stays pending', () async {
      await seedAll();
      await takeFromA(TrayMode.move, {1});
      await store.updateManifest(
          tray.state.tray!.copyWith(journal: const TrayJournal('B', ['zz'])));
      final restarted = newController(c, store);
      await restarted.start();
      expect(restarted.state.tray!.mode, TrayMode.move);
      expect(restarted.state.tray!.journal, isNull);
      expect(ids('A').length, 4);
      expect((await store.read())!.journal, isNull);
    });
  });

  group('source deleted', () {
    test('a pending move becomes a copy, also after a restart', () async {
      await seedAll();
      await takeFromA(TrayMode.move, {1});
      await tray.onNotebookDeleted('A');
      expect(tray.state.tray!.mode, TrayMode.copy);
      expect(tray.state.tray!.sourceDeleted, isTrue);
      final restarted = newController(c, store);
      await restarted.start();
      expect(restarted.state.tray!.mode, TrayMode.copy);
      expect(restarted.state.tray!.sourceDeleted, isTrue);
      final r = await restarted.pasteIntoClosed('B');
      expect(r.status, PasteStatus.ok);
      expect(restarted.state.tray, isNotNull, reason: 'a copy stays');
    });

    test('deleting another notebook leaves the move alone', () async {
      await seedAll();
      await takeFromA(TrayMode.move, {1});
      await tray.onNotebookDeleted('B');
      expect(tray.state.tray!.mode, TrayMode.move);
    });

    test('a source missing at start or at paste time is caught too',
        () async {
      await seedAll();
      await takeFromA(TrayMode.move, {1});
      await fs.deleteNotebook('A');
      final restarted = newController(c, store);
      await restarted.start();
      expect(restarted.state.tray!.mode, TrayMode.copy);
      expect(restarted.state.tray!.sourceDeleted, isTrue);
    });

    test('at paste time', () async {
      await seedAll();
      await takeFromA(TrayMode.move, {1});
      await fs.deleteNotebook('A');
      final r = await tray.pasteIntoClosed('B');
      expect(r.status, PasteStatus.ok);
      expect(tray.state.tray!.mode, TrayMode.copy);
      expect(ids('B').length, 4);
    });
  });

  group('move inside the notebook', () {
    test('reorders and rechapters, consumes the tray; Undo restores both',
        () async {
      await seedAll();
      open('A');
      await tray.capture(TrayMode.move, canvas.state!, {0});
      final before = [for (final e in canvas.state!.document.pages) e.pageId];
      final r = await tray.pasteIntoOpen(
          const PasteSlot(afterPageId: 'y1', chapterId: 'Y'));
      expect(r.status, PasteStatus.ok);
      final s = canvas.state!;
      expect([for (final e in s.document.pages) e.pageId],
          ['x2', 'x3', 'y1', 'x1']);
      expect([for (final e in s.document.pages) e.chapterId],
          ['X', 'X', 'Y', 'Y']);
      expect(tray.state.tray, isNull);
      expect(tray.state.toast!.canUndo, isTrue);
      await tray.undoLast();
      expect([for (final e in canvas.state!.document.pages) e.pageId], before);
      expect([for (final e in canvas.state!.document.pages) e.chapterId],
          ['X', 'X', 'X', 'Y']);
      expect(tray.state.tray!.mode, TrayMode.move);
      expect(tray.state.toast!.event, TrayEvent.undone);
    });

    test('a copy pasted into its own notebook makes new pages', () async {
      await seedAll();
      open('A');
      await tray.capture(TrayMode.copy, canvas.state!, {0});
      final r = await tray.pasteIntoOpen(
          const PasteSlot(afterPageId: 'x3', chapterId: 'X'));
      expect(canvas.state!.document.pages.length, 5);
      expect(r.newPageIds.single, isNot('x1'));
      expect(tray.state.tray, isNotNull);
    });
  });

  group('duplicate and delete', () {
    test('Duplicate puts each copy right after its original; Undo removes '
        'just the copies', () async {
      await seedAll();
      open('A');
      final before = [for (final e in canvas.state!.document.pages) e.pageId];
      tray.duplicatePages({'x1', 'x3'});
      final s = canvas.state!;
      final ids = [for (final e in s.document.pages) e.pageId];
      expect(ids.length, 6);
      expect(ids[0], 'x1');
      expect(ids[1], isNot(anyOf(before)));
      expect(ids[2], 'x2');
      expect(ids[3], 'x3');
      expect(ids[4], isNot(anyOf(before)));
      expect(s.document.pages[1].chapterId, 'X');
      expect(tray.state.toast!.event, TrayEvent.duplicated);
      expect(tray.state.toast!.count, 2);
      await tray.undoLast();
      expect([for (final e in canvas.state!.document.pages) e.pageId], before);
    });

    test('pages deleted from a move source leave the tray; none left, no '
        'tray', () async {
      await seedAll();
      await takeFromA(TrayMode.move, {0, 1});
      await tray.pagesDeleted('A', {'x1'});
      expect(tray.state.tray!.pages.map((e) => e.pageId), ['x2']);
      expect((await store.read())!.pages.map((e) => e.pageId), ['x2']);
      await tray.pagesDeleted('other', {'x2'});
      expect(tray.state.tray!.count, 1, reason: 'another notebook: no change');
      await tray.pagesDeleted('A', {'x2'});
      expect(tray.state.tray, isNull);
      expect(await store.read(), isNull);
    });

    test('a copy tray keeps its pages when the source loses them', () async {
      await seedAll();
      await takeFromA(TrayMode.copy, {0});
      await tray.pagesDeleted('A', {'x1'});
      expect(tray.state.tray!.count, 1);
    });
  });

  group('Undo', () {
    test('Undo of a move across notebooks restores source, destination and '
        'tray', () async {
      await seedAll();
      await takeFromA(TrayMode.move, {1, 2});
      final aBefore = docOf('A').toJson();
      final bBefore = ids('B');
      await tray.pasteIntoClosed('B');
      expect(ids('A').length, 2);
      await tray.undoLast();
      final aAfter = docOf('A');
      expect([for (final e in aAfter.pages) e.pageId],
          [for (final e in DocumentStructure.fromJson(aBefore).pages) e.pageId]);
      expect([for (final e in aAfter.pages) e.fileName],
          [for (final e in DocumentStructure.fromJson(aBefore).pages) e.fileName]);
      expect(ids('B'), bBefore);
      expect(hasFile('A', 'page_x2.json'), isTrue);
      expect(tray.state.tray!.mode, TrayMode.move);
      expect(tray.state.tray!.pages.map((e) => e.pageId), ['x2', 'x3']);
      expect(tray.state.toast!.event, TrayEvent.undone);
      // And the restored tray can be moved again.
      final r = await tray.pasteIntoClosed('F');
      expect(r.status, PasteStatus.ok);
      expect(ids('A'), ['x1', 'y1']);
    });

    test('Undo of a paste into the open notebook removes just those pages',
        () async {
      await seedAll();
      await takeFromA(TrayMode.copy, {0, 1});
      open('B');
      await tray.pasteIntoOpen(
          const PasteSlot(afterPageId: 'p1', chapterId: 'P'));
      expect(canvas.state!.document.pages.length, 5);
      await tray.undoLast();
      expect([for (final e in canvas.state!.document.pages) e.pageId],
          ['p1', 'p2', 'q1']);
      expect(ids('B'), ['p1', 'p2', 'q1']);
      expect(tray.state.tray, isNotNull, reason: 'the copy stays');
    });

    test('the toast timing out ends Undo and frees the discarded tray',
        () async {
      await seedAll();
      await takeFromA(TrayMode.move, {1});
      await tray.pasteIntoClosed('B');
      tray.dismissToast();
      await tray.undoLast();
      expect(ids('A').length, 3, reason: 'no undo after the toast is gone');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await store.restoreDiscarded(), isFalse);
    });
  });
}
