import 'package:flutter/foundation.dart';

/// Native builds write straight to disk; there is nothing to watch.
final ValueListenable<String?> browserStorageError = ValueNotifier(null);
