// Whether the web build runs on a phone/tablet. Always false natively, where
// `defaultTargetPlatform` already tells the truth. In the browser it doesn't:
// iPadOS Safari asks for desktop sites and reports itself as a Mac, so the
// framework sees macOS on an iPad.
export 'device_class_stub.dart'
    if (dart.library.js_interop) 'device_class_web.dart';
