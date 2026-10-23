import 'dart:convert';
import 'dart:ui';

import 'package:abelnotes/core/providers/canvas_provider.dart';
import 'package:abelnotes/core/providers/canvas_state.dart';
import 'package:abelnotes/shared/models/ncnote_format.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final future = {
    'type': 'futureWidget',
    'id': 'c1',
    'zIndex': 3,
    'data': {'kind': 'bode', 'x': 10.0},
  };
  final pageJson = {
    'pageId': 'p1',
    'pageNumber': 1,
    'width': 595.0,
    'height': 842.0,
    'layers': {
      'content': [future],
    },
  };

  test('unknown element type loads instead of failing the page', () {
    final page = PageData.fromJson(pageJson);
    final el = page.layers.content.single;
    expect(el, isA<UnknownElement>());
    expect(el.id, 'c1');
    expect(el.zIndex, 3);
  });

  test('unknown element round-trips verbatim, with updated id/zIndex', () {
    final page = PageData.fromJson(pageJson);
    final out = page.toJson()['layers'] as Map;
    expect((out['content'] as List).single, future);

    final moved = page.copyWith(
        layers: page.layers.copyWith(content: [
      (page.layers.content.single as UnknownElement).copyWith(zIndex: 7),
    ]));
    final c = ((moved.toJson()['layers'] as Map)['content'] as List).single;
    expect(c['zIndex'], 7);
    expect(c['type'], 'futureWidget');
    expect(c['data'], future['data']);
  });

  Map<String, dynamic> pageWith(List<dynamic> content) => {
        ...pageJson,
        'layers': {'content': content},
      };

  test('id-less unknown elements get distinct stable ids, written back as-is',
      () {
    final raw = [
      {'type': 'futureA', 'data': 1},
      {'type': 'futureB', 'data': 2},
      {'type': 'futureA', 'data': 1},
    ];
    final a = PageData.fromJson(pageWith(raw)).layers.content;
    final b = PageData.fromJson(pageWith(raw)).layers.content;
    expect(a.map((e) => e.id).toSet().length, 3);
    expect(a.map((e) => e.id), b.map((e) => e.id));

    final out = PageData.fromJson(pageWith(raw)).toJson()['layers'] as Map;
    expect(out['content'], raw);
  });

  test('wrong-typed id/zIndex load as missing instead of failing the page', () {
    final raw = [
      {'type': 'futureA', 'id': 5, 'zIndex': 'high'},
      {'type': 'futureA', 'id': 'ok', 'zIndex': null},
    ];
    final page = PageData.fromJson(pageWith(raw));
    final els = page.layers.content;
    expect(els.map((e) => e.zIndex), [0, 0]);
    expect(els[0].id, isNot(''));
    expect(els[1].id, 'ok');
    expect((page.toJson()['layers'] as Map)['content'][0], raw[0]);
  });

  test('non-map list entries are kept verbatim as unknown', () {
    final raw = ['junk', 42, null, future];
    final page = PageData.fromJson(pageWith(raw));
    final els = page.layers.content;
    expect(els, hasLength(4));
    expect(els.take(3), everyElement(isA<UnknownElement>()));
    expect(els.map((e) => e.id).toSet().length, 4);
    expect((page.toJson()['layers'] as Map)['content'], raw);
  });

  test('symbol containing an unknown element round-trips', () {
    final sym = ReusableSymbol(
      id: 's',
      name: 'n',
      elements: [
        ContentElement.unknown(id: 'c1', zIndex: 3, raw: future),
      ],
      bounds: const Rect.fromLTRB(0, 0, 10, 10),
      createdAt: DateTime(2026),
    );
    final back = ReusableSymbol.fromJson(
        jsonDecode(jsonEncode(sym.toJson())) as Map<String, dynamic>);
    expect(back.elements.single, sym.elements.single);
  });

  test('selectAll skips unknown elements but selects the visible ones', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(canvasProvider.notifier);
    final now = DateTime(2026);
    final page = PageData(
      pageId: 'p1',
      pageNumber: 1,
      width: 595,
      height: 842,
      layers: RenderingLayers(content: [
        ContentElement.stroke(
          id: 's1',
          zIndex: 0,
          data: StrokeData(
              points: [StrokePoint(x: 10, y: 10), StrokePoint(x: 100, y: 10)]),
        ),
        ContentElement.unknown(id: 'c1', zIndex: 1, raw: future),
      ]),
    );
    n.state = CanvasState(
      metadata: NotebookMetadata(id: 'n', title: 't', createdAt: now, modifiedAt: now),
      document: DocumentStructure(
          notebookId: 'n',
          pages: [PageEntry(pageId: 'p1', pageNumber: 1, fileName: 'p1.json')]),
      pages: {'p1.json': page},
      remotePath: '',
    );

    n.selectAll();
    expect(c.read(canvasProvider)!.lassoSelection!.selectedIds, ['s1']);

    // Only an unknown element on the page: nothing to select.
    n.state = n.state!.copyWith(
        clearLasso: true,
        pages: {
          'p1.json': page.copyWith(
              layers: RenderingLayers(content: [page.layers.content.last]))
        });
    n.selectAll();
    expect(c.read(canvasProvider)!.lassoSelection, isNull);
  });

  test('a chart written by a newer build survives a load/save cycle', () {
    final chart = {
      'id': '8bf7d203-8ebc-4263-812b-37cb5c3e3090',
      'zIndex': 260,
      'data': {
        'x': 124.486, 'y': 330.168, 'width': 360.0, 'height': 220.0,
        'mode': 'function',
        'curves': [
          {'expr': 'sin(x)', 'numerator': [1.0], 'denominator': [1.0, 1.0],
           'color': 4279592384, 'label': ''},
        ],
        'xMin': -10.0, 'xMax': 10.0, 'freqMin': 0.1, 'freqMax': 1000.0,
        'title': '', 'axisColor': 4278190080,
        'magnitudeInDb': true, 'phaseInDegrees': true,
      },
      'type': 'chart',
    };
    final json = jsonDecode(jsonEncode({
      ...pageJson,
      'layers': {'content': [chart]},
    })) as Map<String, dynamic>;
    final page = PageData.fromJson(json);
    expect(page.layers.content.single, isA<UnknownElement>());
    final again = jsonDecode(jsonEncode(page.toJson())) as Map<String, dynamic>;
    expect((again['layers'] as Map)['content'], [chart]);
  });
}
