import 'package:sqflite_common/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import 'io_web.dart';

Future<void> initWebStorage() async {
  await WebFs.init();
  // Without a shared worker: that variant needs cross-origin isolation
  // headers, which a plain static host (and Safari) doesn't give us.
  databaseFactory = databaseFactoryFfiWebNoWebWorker;
}
