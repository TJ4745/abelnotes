import 'package:flutter/foundation.dart';

final ValueNotifier<bool> webTouchDevice = ValueNotifier(false);
bool get isWebTouchDevice => false;
void noteWebTouchInput() {}
String webDeviceDiagnostics() => '';
bool get webDiagnostics => false;
void installWebPointerProbe(void Function(String) log) {}
void startWebDiagUpload(String Function() read) {}
