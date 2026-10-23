// Regression: the painter's zero-alloc type dispatch cast anything that was
// not stroke/text/image/shape to MathElement, so a page holding an element
// from a newer build threw on every frame and drew nothing.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:abelnotes/features/canvas/data/render_engine.dart';
import 'package:abelnotes/shared/models/ncnote_format.dart';

PageData _page() => PageData(
      pageId: 'p1',
      pageNumber: 0,
      width: 400,
      height: 600,
      layers: const RenderingLayers(
        content: [
          ContentElement.math(
            id: 'm1',
            zIndex: 2,
            data: MathData(x: 10, y: 10, width: 120, height: 40, latex: 'x^2'),
          ),
          ContentElement.unknown(
            id: 'c1',
            zIndex: 1,
            raw: {'type': 'chart', 'id': 'c1', 'zIndex': 1, 'data': {}},
          ),
          ContentElement.math(
            id: 'm2',
            zIndex: 0,
            data: MathData(x: 10, y: 80, width: 120, height: 40, latex: 'y'),
          ),
        ],
      ),
    );

void main() {
  setUp(CanvasRenderEngine.disposeStaticCache);

  test('a page with an unknown element paints without throwing', () {
    final recorder = ui.PictureRecorder();
    expect(
      () => CanvasRenderEngine(pageData: _page()).paint(Canvas(recorder), const Size(400, 600)),
      returnsNormally,
    );
    recorder.endRecording().dispose();
  });
}
