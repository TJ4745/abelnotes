import 'package:flutter_test/flutter_test.dart';
import 'package:abelnotes/ui/services/notebook_opener.dart';

void main() {
  test('second open is refused while one is in flight', () {
    final g = OpenGate();
    final a = g.begin()!;
    expect(g.begin(), isNull);
    g.end(a);
    expect(g.begin(), isNotNull);
  });

  test('cancel frees the guard at once and invalidates the stale call', () {
    final g = OpenGate();
    final a = g.begin()!;
    g.cancel(a);
    expect(g.isCurrent(a), isFalse);
    expect(g.cancelledWithoutSuccessor(a), isTrue);
    final b = g.begin()!;
    expect(g.isCurrent(b), isTrue);
    // The stale call resumes: it must not close or end the newer open.
    expect(g.isCurrent(a), isFalse);
    expect(g.cancelledWithoutSuccessor(a), isFalse);
    g.end(a);
    expect(g.isCurrent(b), isTrue);
    expect(g.begin(), isNull);
  });

  test('successor that already finished still blocks the stale close', () {
    final g = OpenGate();
    final a = g.begin()!;
    g.cancel(a);
    final b = g.begin()!;
    g.end(b);
    expect(g.cancelledWithoutSuccessor(a), isFalse);
  });
}
