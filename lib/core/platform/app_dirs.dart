// path_provider has no web implementation; the browser build uses fixed roots
// inside the IndexedDB-backed virtual file system instead.
export 'app_dirs_native.dart' if (dart.library.js_interop) 'app_dirs_web.dart';
