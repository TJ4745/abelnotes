// Browser-only start-up work (no-op everywhere else): load the virtual file
// system from IndexedDB and point sqflite at its WASM build.
export 'web_bootstrap_stub.dart'
    if (dart.library.js_interop) 'web_bootstrap_web.dart';
