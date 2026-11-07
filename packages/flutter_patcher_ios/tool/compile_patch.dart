import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher_ios/compiler.dart';
import 'package:flutter_patcher_ios/src/models.dart';

void main() {
  test('compile configured Dart patch sources', () async {
    const path = String.fromEnvironment('PATCH_CONFIG');
    if (path.isEmpty) {
      throw const PatchException('COMPILE', 'PATCH_CONFIG is required');
    }
    final configFile = File(path).absolute;
    final config = objectMap(jsonDecode(await configFile.readAsString()));
    if (config.containsKey('programFormat') &&
        config['programFormat'] != 'evc-v81') {
      throw const PatchException(
        'COMPILE',
        'The EVC compiler only supports evc-v81',
      );
    }
    final sources = <String, Map<String, String>>{};
    for (final package in objectMap(config['sources']).entries) {
      if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(package.key)) {
        throw const PatchException('COMPILE', 'Invalid source package name');
      }
      final files = <String, String>{};
      for (final file in objectMap(package.value).entries) {
        validatePatchPath(file.key);
        if (file.value is! String) {
          throw const PatchException('COMPILE', 'Expected source file path');
        }
        files[file.key] = await File.fromUri(
          configFile.uri.resolve(file.value as String),
        ).readAsString();
      }
      sources[package.key] = files;
    }
    if (sources.isEmpty) {
      throw const PatchException('COMPILE', 'No patch sources');
    }
    final bytes = compilePatchSources(sources);
    final output = File.fromUri(
      configFile.uri.resolve(requiredString(config, 'program')),
    );
    // A successful compile is the only operation that replaces the output.
    await output.parent.create(recursive: true);
    final temp = File('${output.path}.next');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(output.path);
  });
}
