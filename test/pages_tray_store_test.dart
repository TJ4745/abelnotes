// The tray is written to disk whole and read back identically (pages,
// assets, previews), survives manifest updates, and Clear/Undo go through
// the graveyard.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:abelnotes/features/pages_tray/data/tray_store.dart';
import 'package:abelnotes/features/pages_tray/domain/pages_tray.dart';
import 'package:abelnotes/shared/models/ncnote_format.dart';

TrayPage _page(String id, {String? asset, String? chapter}) {
  final content = <ContentElement>[
    ContentElement.stroke(
        id: 's$id',
        zIndex: 1,
        data: const StrokeData(points: [
          StrokePoint(x: 1.25, y: 2.5),
          StrokePoint(x: 3, y: 4, pressure: 0.9),
        ])),
    if (asset != null)
      ContentElement.image(
          id: 'i$id',
          zIndex: 2,
          data: ImageData(
              x: 0, y: 0, width: 10, height: 10, assetPath: asset)),
  ];
  return TrayPage(
      PageEntry(
          pageId: id,
          pageNumber: 1,
          fileName: 'page_$id.json',
          chapterId: chapter),
      PageData(
          pageId: id,
          pageNumber: 1,
          width: 595,
          height: 842,
          layers: RenderingLayers(content: content)));
}

PagesTray _tray({TrayMode mode = TrayMode.move, TrayJournal? journal}) =>
    PagesTray(
      id: 't1',
      mode: mode,
      sourceNotebookId: 'src',
      sourceTitle: 'Source',
      sourceChapterTitle: 'Chap',
      pages: [_page('a', asset: 'img1', chapter: 'c1'), _page('b')],
      thumbs: [
        [1, 2, 3],
        [4, 5]
      ],
      journal: journal,
    );

void main() {
  late Directory tmp;
  late TrayStore store;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tray_store_test');
    store = TrayStore(p.join(tmp.path, 'pages_tray'));
  });
  tearDown(() => tmp.delete(recursive: true));

  test('nothing saved reads as no tray', () async {
    expect(await store.read(), isNull);
  });

  test('round trip keeps pages, entries, mode, source, previews', () async {
    final assets = {'img1': Uint8List.fromList([9, 8, 7])};
    await store.write(_tray(), assets);
    final back = (await store.read())!;
    expect(back.id, 't1');
    expect(back.mode, TrayMode.move);
    expect(back.sourceNotebookId, 'src');
    expect(back.sourceTitle, 'Source');
    expect(back.sourceChapterTitle, 'Chap');
    expect(back.saved, isTrue);
    expect(back.pages.map((e) => e.pageId), ['a', 'b']);
    expect(back.pages[0].entry.chapterId, 'c1');
    expect(back.pages[0].entry.fileName, 'page_a.json');
    expect(back.pages[0].data.layers.content.length, 2);
    final stroke = back.pages[0].data.layers.content[0] as StrokeElement;
    expect(stroke.data.points[1].pressure, closeTo(0.9, 1e-9));
    expect(back.pages[0].assetIds, {'img1'});
    expect(back.thumbs, [
      [1, 2, 3],
      [4, 5]
    ]);
    expect((await store.readAssets(back.assetIds))['img1'], [9, 8, 7]);
    expect(await store.readAssets(['missing']), isEmpty);
  });

  test('manifest update changes mode and journal only', () async {
    await store.write(_tray(), const {});
    final t = (await store.read())!;
    await store.updateManifest(
        t.copyWith(journal: const TrayJournal('dest', ['n1', 'n2'])));
    var back = (await store.read())!;
    expect(back.journal!.destNotebookId, 'dest');
    expect(back.journal!.newPageIds, ['n1', 'n2']);
    expect(back.pages.length, 2);
    await store.updateManifest(back.asCopyOfDeletedSource());
    back = (await store.read())!;
    expect(back.mode, TrayMode.copy);
    expect(back.sourceDeleted, isTrue);
    expect(back.journal, isNull);
  });

  test('a new write replaces the old tray entirely', () async {
    await store.write(_tray(), {'img1': Uint8List(3)});
    final next = PagesTray(
        id: 't2',
        mode: TrayMode.copy,
        sourceNotebookId: 'x',
        sourceTitle: 'X',
        pages: [_page('z')]);
    await store.write(next, const {});
    final back = (await store.read())!;
    expect(back.id, 't2');
    expect(back.pages.length, 1);
    expect(await store.readAssets(['img1']), isEmpty);
    expect(Directory('${store.root}.tmp').existsSync(), isFalse);
    expect(Directory('${store.root}.old').existsSync(), isFalse);
  });

  test('discard then restore brings the same tray back', () async {
    await store.write(_tray(), {'img1': Uint8List.fromList([1])});
    await store.discard();
    expect(await store.read(), isNull);
    expect(await store.restoreDiscarded(), isTrue);
    final back = (await store.read())!;
    expect(back.id, 't1');
    expect((await store.readAssets(['img1']))['img1'], [1]);
  });

  test('purge removes the discarded tray for good', () async {
    await store.write(_tray(), const {});
    await store.discard();
    await store.purgeDiscarded();
    expect(await store.restoreDiscarded(), isFalse);
  });

  test('a crash between the two renames still finds the old tray', () async {
    await store.write(_tray(), const {});
    await Directory(store.root).rename('${store.root}.old');
    expect((await store.read())!.id, 't1');
  });

  test('a corrupt manifest reads as no tray, not a crash', () async {
    await store.write(_tray(), const {});
    await File(p.join(store.root, 'tray.json')).writeAsString('{nope');
    expect(await store.read(), isNull);
  });
}
