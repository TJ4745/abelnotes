// `dart:io` with a browser-safe stand-in for the parts the app uses for local
// storage. Native builds get the real library untouched; the web build gets a
// virtual file system persisted in IndexedDB (see io_web.dart), so the offline
// loose store keeps working inside a PWA without any other code changing.
export 'dart:io' if (dart.library.js_interop) 'io_web.dart';
