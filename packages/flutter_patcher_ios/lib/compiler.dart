/// Developer-side compiler. Run under Flutter's headless test engine; this
/// imports Flutter bridges and is not a standalone Dart VM library.
library;

import 'dart:typed_data';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'src/models.dart';

Uint8List compilePatchSources(Map<String, Map<String, String>> sources) {
  if (sources.containsKey('flutter_patcher_bootstrap')) {
    throw const PatchException('COMPILE', 'Reserved package name');
  }
  final compiler = Compiler()..addPlugin(flutterEvalPlugin);
  for (final p in sources.entries) {
    for (final file in p.value.keys) {
      compiler.entrypoints.add('package:${p.key}/$file');
    }
  }
  return compiler.compile({
    ...sources,
    'flutter_patcher_bootstrap': {
      'main.dart': "String runtimeId() => '$iosPatchRuntimeId';",
    },
  }).write();
}
