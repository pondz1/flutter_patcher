import 'package:flutter/widgets.dart';

String title(String name) => 'Hello, $name (patched)';

Widget view() => Column(
  children: [
    Text('This widget came from a signed patch.'),
    Image.asset('images/patch_demo.png', width: 160),
  ],
);
