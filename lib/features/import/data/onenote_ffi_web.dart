// Web stand-in for onenote_ffi.dart: the OneNote parser is a native Rust
// library loaded over FFI, which the browser cannot do.
class OneNoteBridge {
  OneNoteBridge._();
  static bool get available => false;
  static Map<String, dynamic> parseFile(String filePath) =>
      throw const FormatException('OneNote import is not available on the web');
}
