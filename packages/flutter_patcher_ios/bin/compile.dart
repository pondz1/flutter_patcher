import 'dart:io';
import 'package:args/args.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('config')
    ..addFlag('help', negatable: false);
  try {
    final args = parser.parse(arguments);
    if (args['help'] as bool) {
      stdout.writeln(parser.usage);
      return;
    }
    final path = args['config'] as String?;
    if (path == null || args.rest.isNotEmpty) {
      throw const FormatException('--config is required');
    }
    final config = File(path).absolute;
    final root = File.fromUri(Platform.script).parent.parent;
    final process = await Process.start(
      'flutter',
      [
        'test',
        '--no-pub',
        '--no-test-assets',
        '${root.path}/tool/compile_patch.dart',
        '--reporter',
        'expanded',
        '--dart-define=PATCH_CONFIG=${config.path}',
      ],
      workingDirectory: root.path,
      mode: ProcessStartMode.inheritStdio,
    );
    exitCode = await process.exitCode;
  } catch (e) {
    stderr.writeln('compile failed: $e');
    exitCode = 64;
  }
}
