// Headless edits of a closed notebook: the loose store, the dirty marks and
// the pending deletes that make the sync pick the change up later.

// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:abelnotes/core/providers/canvas_provider.dart'
    show compactPageJson;
import 'package:abelnotes/core/services/file_service.dart';
import 'package:abelnotes/features/pages_tray/data/closed_notebook_editor.dart';
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

final _t0 = DateTime(2026);

PageData _data(String id, {String? asset}) => PageData(
    pageId: id,
    pageNumber: 1,
    width: 595,
    height: 842,
    layers: RenderingLayers(content: [
      if (asset != null)
        ContentElement.image(
            id: 'i$id',
            zIndex: 1,
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
  late ClosedNotebookEditor ed;
  var open = <String>{};

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('closed_editor_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    fs = FileService();
    await fs.init();
    open = {};
    ed = ClosedNotebookEditor(fs, isOpenInEditor: open.contains);
  });
  tearDown(() => tmp.delete(recursive: true));

  // Notebook `id` with chapters X (x1 x2) and Y (y1) and an image on x2.
  Future<void> seed(String id,
      {List<PageEntry>? entries, List<Chapter>? chapters}) async {
    final es = entries ?? [_e('x1', 'X'), _e('x2', 'X'), _e('y1', 'Y')];
    final chs = chapters ??
        const [Chapter(id: 'X', title: 'X'), Chapter(id: 'Y', title: 'Y')];
    final meta = NotebookMetadata(
        id: id,
        title: 'NB $id',
        createdAt: _t0,
        modifiedAt: _t0,
        pageCount: es.length,
        chapters: chaptersWithMembership(
            chs, DocumentStructure(notebookId: id, pages: es)));
    await fs.saveNotebookIncremental(
      id,
      metadataJson: _b(jsonEncode(meta.toJson())),
      documentJson: _b(jsonEncode(
          DocumentStructure(notebookId: id, pages: es).toJson())),
      changedPages: {
        for (final e in es)
          e.fileName: _b(compactPageJson(
              _data(e.pageId, asset: e.pageId == 'x2' ? 'img-x2' : null))),
      },
      changedAssets: {'img-x2': _b('IMG'), 'orphan': _b('O')},
    );
    await fs.upsertNotebookMeta(
        id: id,
        title: meta.title,
        remotePath: '/AbelNotes/$id.ncnote',
        localModifiedAt: _t0,
        pageCount: es.length,
        syncStatus: 'synced');
  }

  String dir(String id) => fs.notebookStoreDir(id);
  Map<String, dynamic> readJson(String id, String name) =>
      jsonDecode(File(p.join(dir(id), name)).readAsStringSync())
          as Map<String, dynamic>;
  bool pageFile(String id, String fn) =>
      File(p.join(dir(id), 'pages', fn)).existsSync();
  List<String> docIds(String id) => [
        for (final e in readJson(id, 'document.json')['pages'] as List)
          (e as Map)['pageId'] as String
      ];

  group('removePages', () {
    test('document, chapters, files, count and sync marks follow', () async {
      await seed('a');
      final r = await ed.removePages('a', {'x2', 'y1'});
      expect(r.removed.map((e) => e.entry.pageId), ['x2', 'y1']);
      expect(docIds('a'), ['x1']);
      expect(pageFile('a', 'page_x2.json'), isFalse);
      expect(pageFile('a', 'page_y1.json'), isFalse);
      expect(pageFile('a', 'page_x1.json'), isTrue);
      final meta = readJson('a', 'metadata.json');
      expect(meta['pageCount'], 1);
      final chapters = {
        for (final c in meta['chapters'] as List)
          (c as Map)['id']: c['pageIds']
      };
      expect(chapters['X'], ['x1']);
      expect(chapters['Y'], isEmpty);
      // Assets stay (orphans are pruned by the editor later, never here).
      expect(File(p.join(dir('a'), 'assets', 'img-x2')).existsSync(), isTrue);
      // Sync marks.
      expect(await fs.dirtyPagesOf('a'), contains('doc'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('pending_page_deletes_a')!.toSet(),
          {'page_x2.json', 'page_y1.json'});
      expect(prefs.getString('unpushed_base_doc_a'), isNotNull);
      final base = jsonDecode(prefs.getString('unpushed_base_doc_a')!) as Map;
      expect((base['pages'] as List).length, 3);
      final row = (await fs.getNotebookMeta('a'))!;
      expect(row['sync_status'], 'modified');
      expect(row['page_count'], 1);
    });

    test('removing again is a no-op', () async {
      await seed('a');
      await ed.removePages('a', {'x1'});
      final again = await ed.removePages('a', {'x1'});
      expect(again.removed, isEmpty);
      expect(docIds('a'), ['x2', 'y1']);
    });

    test('the baseline of earlier unpushed work is not overwritten',
        () async {
      await seed('a');
      await fs.addDirtyPages('a', ['page_x1.json']);
      SharedPreferences.setMockInitialValues({'unpushed_base_doc_a': 'OLD'});
      await ed.removePages('a', {'y1'});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('unpushed_base_doc_a'), 'OLD');
    });

    test('moving every page leaves one blank page of the same paper',
        () async {
      await seed('a');
      final r = await ed.removePages('a', {'x1', 'x2', 'y1'});
      expect(r.blankPageId, isNotNull);
      expect(docIds('a'), [r.blankPageId]);
      expect(readJson('a', 'metadata.json')['pageCount'], 1);
      final fn = ((readJson('a', 'document.json')['pages'] as List).single
          as Map)['fileName'] as String;
      expect(pageFile('a', fn), isTrue);
      expect(await fs.dirtyPagesOf('a'), contains(fn));
    });

    test('an open notebook is refused and left untouched', () async {
      await seed('a');
      open.add('a');
      await expectLater(ed.removePages('a', {'x1'}),
          throwsA(isA<NotebookBusyException>()));
      expect(docIds('a'), ['x1', 'x2', 'y1']);
      expect(pageFile('a', 'page_x1.json'), isTrue);
    });

    test('a notebook without a local copy is refused', () async {
      await expectLater(ed.removePages('nope', {'x1'}),
          throwsA(isA<NotebookUnavailableException>()));
    });

    test('a failed write takes the pending mark back and changes nothing',
        () async {
      await seed('a');
      final d = Directory(dir('a'));
      Process.runSync('chmod', ['a-w', d.path]);
      try {
        await expectLater(ed.removePages('a', {'x1'}), throwsA(anything));
      } finally {
        Process.runSync('chmod', ['u+w', d.path]);
      }
      expect(await fs.dirtyPagesOf('a'), isEmpty);
      expect((await fs.getNotebookMeta('a'))!['sync_status'], 'synced');
      expect(docIds('a'), ['x1', 'x2', 'y1']);
      expect(pageFile('a', 'page_x1.json'), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('pending_page_deletes_a'), isNull);
    });

    test('a corrupt document is refused, files untouched', () async {
      await seed('a');
      File(p.join(dir('a'), 'document.json')).writeAsStringSync('{nope');
      await expectLater(ed.removePages('a', {'x1'}),
          throwsA(isA<NotebookUnavailableException>()));
      expect(pageFile('a', 'page_x1.json'), isTrue);
    });
  });

  group('insertPages', () {
    TrayPage tp(String id, {String? asset}) =>
        TrayPage(_e(id, 'srcChapter'), _data(id, asset: asset));

    test('pages, assets, chapter and sync marks land', () async {
      await seed('b');
      final r = await ed.insertPages(
          'b',
          [tp('n1', asset: 'img-new'), tp('n2')],
          {'img-new': _b('NEW')},
          const PasteSlot(afterPageId: 'x1', chapterId: 'Y'));
      final doc = readJson('b', 'document.json')['pages'] as List;
      expect(doc.length, 5);
      expect((doc[1] as Map)['pageId'], r.newPageIds[0]);
      expect((doc[1] as Map)['chapterId'], 'Y');
      expect((doc[2] as Map)['chapterId'], 'Y');
      for (final fn in r.newFileNames) {
        expect(pageFile('b', fn), isTrue);
      }
      expect(File(p.join(dir('b'), 'assets', 'img-new')).readAsBytesSync(),
          _b('NEW'));
      final meta = readJson('b', 'metadata.json');
      expect(meta['pageCount'], 5);
      final y = (meta['chapters'] as List)
          .firstWhere((c) => (c as Map)['id'] == 'Y') as Map;
      expect((y['pageIds'] as List).length, 3);
      final dirty = await fs.dirtyPagesOf('b');
      expect(dirty, containsAll(['doc', 'asset:img-new', ...r.newFileNames]));
      expect((await fs.getNotebookMeta('b'))!['page_count'], 5);
    });

    test('an asset the notebook already has is not rewritten or re-marked',
        () async {
      await seed('b');
      final r = await ed.insertPages(
          'b',
          [tp('n1', asset: 'img-x2')],
          {'img-x2': _b('DIFFERENT')},
          const PasteSlot(afterPageId: 'x1', chapterId: 'X'));
      expect(File(p.join(dir('b'), 'assets', 'img-x2')).readAsBytesSync(),
          _b('IMG'));
      expect(await fs.dirtyPagesOf('b'), isNot(contains('asset:img-x2')));
      expect(r.newPageIds.length, 1);
    });

    test('storesPages tells present pages from missing ones', () async {
      await seed('b');
      final r = await ed.insertPages('b', [tp('n1')], const {},
          const PasteSlot(afterPageId: 'x1', chapterId: 'X'));
      expect(await ed.storesPages('b', r.newPageIds.toSet()), isTrue);
      expect(await ed.storesPages('b', {...r.newPageIds, 'ghost'}), isFalse);
      File(p.join(dir('b'), 'pages', r.newFileNames.single)).deleteSync();
      expect(await ed.storesPages('b', r.newPageIds.toSet()), isFalse);
      expect(await ed.storesPages('missing', {'x'}), isFalse);
    });

    test('flat notebook stays flat', () async {
      await seed('c',
          entries: [_e('a', null), _e('b', null)], chapters: const []);
      final r = await ed.insertPages('c', [tp('n1')], const {},
          const PasteSlot(afterPageId: 'b'));
      final doc = readJson('c', 'document.json')['pages'] as List;
      expect((doc.last as Map)['chapterId'], isNull);
      expect(r.insertIndex, 2);
    });
  });

  group('restoreRemoved', () {
    test('Undo of a removal puts ids, files, order and chapters back',
        () async {
      await seed('a');
      final data = {
        'x2': _data('x2', asset: 'img-x2'),
        'y1': _data('y1'),
      };
      final r = await ed.removePages('a', {'x2', 'y1'});
      await ed.restoreRemoved('a', r, data);
      expect(docIds('a'), ['x1', 'x2', 'y1']);
      expect(pageFile('a', 'page_x2.json'), isTrue);
      expect(pageFile('a', 'page_y1.json'), isTrue);
      final chapters = [
        for (final e in readJson('a', 'document.json')['pages'] as List)
          (e as Map)['chapterId']
      ];
      expect(chapters, ['X', 'X', 'Y']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('pending_page_deletes_a'), isEmpty);
      expect(readJson('a', 'metadata.json')['pageCount'], 3);
    });

    test('after emptying the notebook the blank page goes away again',
        () async {
      await seed('a');
      final data = {
        'x1': _data('x1'),
        'x2': _data('x2', asset: 'img-x2'),
        'y1': _data('y1')
      };
      final r = await ed.removePages('a', {'x1', 'x2', 'y1'});
      final blankFile = ((readJson('a', 'document.json')['pages'] as List)
          .single as Map)['fileName'] as String;
      await ed.restoreRemoved('a', r, data);
      expect(docIds('a'), ['x1', 'x2', 'y1']);
      expect(pageFile('a', blankFile), isFalse);
    });
  });

  test('cross-notebook move: insert in B, verify, remove from A', () async {
    await seed('a');
    await seed('b');
    final moved = [
      TrayPage(_e('x2', 'X'), _data('x2', asset: 'img-x2')),
    ];
    final ins = await ed.insertPages('b', moved, {'img-x2': _b('IMG')},
        const PasteSlot(afterPageId: 'y1', chapterId: 'Y'));
    expect(await ed.storesPages('b', ins.newPageIds.toSet()), isTrue);
    await ed.removePages('a', {'x2'});
    expect(docIds('a'), ['x1', 'y1']);
    expect(docIds('b').length, 4);
    expect(docIds('b').last, ins.newPageIds.single);
  });
}
