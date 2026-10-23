import 'package:flutter_test/flutter_test.dart';
import 'package:abelnotes/core/services/pen_monitor_service.dart';

// `xinput list` from a GAOMON tablet on X11: the stylus is the pointer named
// "Pad", while "Pen" is a keyboard device that rejects the matrix.
const _gaomonList = '''
⎡ Virtual core pointer                    \tid=2\t[master pointer  (3)]
⎜   ↳ Virtual core XTEST pointer              \tid=4\t[slave  pointer  (2)]
⎜   ↳ GAOMON Gaomon Tablet Pad                \tid=7\t[slave  pointer  (2)]
⎜   ↳ Logi M196 Mouse                         \tid=15\t[slave  pointer  (2)]
⎣ Virtual core keyboard                   \tid=3\t[master keyboard (2)]
    ↳ Virtual core XTEST keyboard             \tid=5\t[slave  keyboard (3)]
    ↳ GAOMON Gaomon Tablet Pen                \tid=6\t[slave  keyboard (3)]
    ↳ NOVATEK USB Keyboard                    \tid=8\t[slave  keyboard (3)]
''';

const _wacomList = '''
⎡ Virtual core pointer                    \tid=2\t[master pointer  (3)]
⎜   ↳ Virtual core XTEST pointer              \tid=4\t[slave  pointer  (2)]
⎜   ↳ Wacom Intuos S Pen stylus               \tid=10\t[slave  pointer  (2)]
⎜   ↳ Wacom Intuos S Pad pad                  \tid=11\t[slave  pointer  (2)]
⎜   ↳ Wacom Intuos S Pen eraser               \tid=16\t[slave  pointer  (2)]
⎣ Virtual core keyboard                   \tid=3\t[master keyboard (2)]
''';

const _stylusLong = '''
GAOMON Gaomon Tablet Pad                	id=7	[slave  pointer  (2)]
	Reporting 5 classes:
		Class originated from: 7. Type: XIButtonClass
		Buttons supported: 8
		Class originated from: 7. Type: XIValuatorClass
		Detail for Valuator 0:
		  Label: Abs X
		  Range: 0.000000 - 16777215.000000
		Class originated from: 7. Type: XIValuatorClass
		Detail for Valuator 2:
		  Label: Abs Pressure
		  Range: 0.000000 - 16777215.000000
''';

const _mouseLong = '''
Logi M196 Mouse                         	id=15	[slave  pointer  (2)]
	Reporting 7 classes:
		Class originated from: 15. Type: XIValuatorClass
		Detail for Valuator 0:
		  Label: Rel X
''';

void main() {
  group('parseSlavePointers', () {
    test('keeps real pointers, drops XTEST and keyboard devices', () {
      final p = PenMonitorService.parseSlavePointers(_gaomonList);
      expect(p.map((d) => d.id), [7, 15]);
      expect(p.first.name, 'GAOMON Gaomon Tablet Pad');
    });

    test('lists every Wacom tool by id', () {
      final p = PenMonitorService.parseSlavePointers(_wacomList);
      expect(p.map((d) => d.id), [10, 11, 16]);
      expect(p.map((d) => d.name), contains('Wacom Intuos S Pen eraser'));
    });
  });

  test('hasPressureAxis tells the stylus from a mouse', () {
    expect(PenMonitorService.hasPressureAxis(_stylusLong), isTrue);
    expect(PenMonitorService.hasPressureAxis(_mouseLong), isFalse);
  });
}
