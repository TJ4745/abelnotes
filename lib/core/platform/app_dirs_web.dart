import 'io_web.dart';

Future<Directory> getApplicationDocumentsDirectory() async =>
    Directory('/documents');

Future<Directory> getTemporaryDirectory() async => Directory('/tmp');
