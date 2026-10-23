// Stale page index, eraser throttle teardown and bulk-flag reset.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:abelnotes/core/providers/canvas_provider.dart';
import 'package:abelnotes/shared/models/ncnote_format.dart';

ContentElement _line(String id, double y) => ContentElement.stroke(
      id: id,
      zIndex: 0,
      data: StrokeData(
          points: [StrokePoint(x: 10, y: y), StrokePoint(x: 100, y: y)]),
    );

PageData _page(String id, List<ContentElement> content) => PageData(
      pageId: id,
      pageNumber: 1,
      width: 595,
      height: 842,
      layers: RenderingLayers(content: content),
    );

CanvasState _state(PageData page,
    {int index = 0, CanvasTool tool = CanvasTool.pen}) {
  final now = DateTime(2026);
  return CanvasState(
    metadata: NotebookMetadata(id: 'n', title: 't', createdAt: now, modifiedAt: now),
    document: DocumentStructure(notebookId: 'n', pages: [
      PageEntry(pageId: page.pageId, pageNumber: 1, fileName: 'p1.json'),
    ]),
    pages: {'p1.json': page},
    currentPageIndex: index,
    currentTool: tool,
    remotePath: '',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer c;
  late CanvasNotifier n;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    c = ProviderContainer();
    n = c.read(canvasProvider.notifier);
  });

  test('addPage with a stale currentPageIndex appends instead of throwing', () {
    n.state = _state(_page('p1', []), index: 5);
    n.addPage();
    final s = c.read(canvasProvider)!;
    expect(s.document.pages.length, 2);
    expect(s.currentPageIndex, 1);
    c.dispose();
  });

  test('movePagesToPosition with a stale currentPageIndex does not throw', () {
    final s0 = _state(_page('p1', []), index: 9);
    n.state = s0.copyWith(
      document: s0.document.copyWith(pages: [
        ...s0.document.pages,
        PageEntry(pageId: 'p2', pageNumber: 2, fileName: 'p2.json'),
      ]),
    );
    n.movePagesToPosition([0], 2);
    expect(c.read(canvasProvider)!.document.pages.length, 2);
    c.dispose();
  });

  test('cancelStroke drops a buffered erase instead of flushing it later', () async {
    n.state = _state(_page('p1', [_line('a', 10), _line('b', 300)]),
        tool: CanvasTool.eraserStroke);
    n.startStroke(const Offset(10, 10), 1); // flushes at once
    n.continueStroke(const Offset(10, 300), 1); // buffered behind the timer
    n.cancelStroke();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final count = c.read(canvasProvider)!.pages['p1.json']!.layers.content.length;
    expect(count, 1);
    c.dispose();
  });

  test('dispose with a buffered erase leaves no live timer', () async {
    n.state = _state(_page('p1', [_line('a', 10), _line('b', 300)]),
        tool: CanvasTool.eraserStroke);
    n.startStroke(const Offset(10, 10), 1);
    n.continueStroke(const Offset(10, 300), 1);
    c.dispose();
    // A surviving timer would write state on a disposed notifier and throw.
    await Future<void>.delayed(const Duration(milliseconds: 80));
  });

  test('openNotebook clears a stuck bulk-operation flag', () async {
    n.beginBulkOperation();
    final now = DateTime(2026);
    final page = _page('p1', []);
    await n.openNotebook(
      metadata: NotebookMetadata(id: 'n', title: 't', createdAt: now, modifiedAt: now),
      document: DocumentStructure(notebookId: 'n', pages: [
        PageEntry(pageId: 'p1', pageNumber: 1, fileName: 'p1.json'),
      ]),
      pages: {'p1.json': page},
      remotePath: '',
    );
    expect(n.bulkOperationInProgress, isFalse);
    c.dispose();
  });
}
