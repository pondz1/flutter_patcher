import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('interpreted Container forwards explicit anti-aliasing', () {
    final compiler = Compiler()..addPlugin(flutterEvalPlugin);
    final program = compiler.compile({
      'patch': {
        'main.dart': '''
import 'package:flutter/widgets.dart';
Widget main() => Container(isAntiAlias: false);
''',
      },
    });
    final runtime = Runtime.ofProgram(program)..addPlugin(flutterEvalPlugin);
    final result = runtime.executeLib('package:patch/main.dart', 'main');
    final widget = (result as $Value).$value as Container;
    expect(widget.isAntiAlias, isFalse);
  });
}
