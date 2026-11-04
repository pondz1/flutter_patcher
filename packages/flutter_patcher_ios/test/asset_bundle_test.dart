import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher_ios/src/asset_bundle.dart';
import 'package:flutter_patcher_ios/src/package_codec.dart';
import 'fixtures.dart';

class BundledAssets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key == 'AssetManifest.bin') {
      return const StandardMessageCodec().encodeMessage({
        'images/existing.png': [
          {'asset': 'images/existing.png'},
        ],
      })!;
    }
    return ByteData.sublistView(Uint8List.fromList(utf8.encode('bundled')));
  }
}

void main() {
  test(
    'overlay and loadBuffer return patch bytes, other keys fall back',
    () async {
      final p = await fixture();
      final package = await PatchPackageCodec(
        host: testHost,
        trustedKeys: {'test': await publicKey()},
      ).verify(p.bytes, p.envelope);
      final bundle = PatchAssetBundle(
        package: package,
        fallback: BundledAssets(),
      );
      expect(await bundle.loadString('images/logo.txt'), 'patched');
      expect(await bundle.loadString('unchanged'), 'bundled');
      final ui.ImmutableBuffer buffer = await bundle.loadBuffer(
        'images/logo.txt',
      );
      expect(buffer.length, 7);
      buffer.dispose();
    },
  );
  test(
    'manifest keeps bundled keys and registers new image variants',
    () async {
      final p = await fixture(
        assets: {
          'images/new.png': [1],
          'images/2.0x/new.png': [2],
        },
      );
      final package = await PatchPackageCodec(
        host: testHost,
        trustedKeys: {'test': await publicKey()},
      ).verify(p.bytes, p.envelope);
      final bundle = PatchAssetBundle(
        package: package,
        fallback: BundledAssets(),
      );
      final map =
          const StandardMessageCodec().decodeMessage(
                await bundle.load('AssetManifest.bin'),
              )
              as Map;
      expect(map['images/existing.png'], [
        {'asset': 'images/existing.png'},
      ]);
      expect(
        map['images/new.png'],
        containsAll([
          {'asset': 'images/new.png'},
          {'asset': 'images/2.0x/new.png', 'dpr': 2.0},
        ]),
      );
    },
  );
}
