import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'models.dart';

/// Use below MaterialApp's builder or pass explicitly to AssetImage/loaders.
/// Direct rootBundle calls are intentionally not intercepted.
class PatchAssetBundle extends CachingAssetBundle {
  final PatchPackage? package;
  final AssetBundle fallback;
  PatchAssetBundle({required this.package, required this.fallback});
  @override
  Future<ByteData> load(String key) async {
    if (package == null) return fallback.load(key);
    if (key == 'AssetManifest.bin') return _manifest();
    final bytes = package!.asset(key);
    return bytes == null ? fallback.load(key) : ByteData.sublistView(bytes);
  }

  Future<ByteData> _manifest() async {
    const codec = StandardMessageCodec();
    final original = codec.decodeMessage(
      await fallback.load('AssetManifest.bin'),
    );
    if (original is! Map) {
      throw const PatchException(
        'ASSET_MANIFEST',
        'Bundled asset manifest is not a map',
      );
    }
    final map = Map<Object?, Object?>.from(original);
    for (final key in package!.assetPaths.keys) {
      final match = RegExp(
        r'^(.*?)([0-9]+(?:\.[0-9]+)?)x/([^/]+)$',
      ).firstMatch(key);
      final base = match == null ? key : '${match[1]}${match[3]}';
      final variants = List<Object?>.from(map[base] as List? ?? []);
      final value = <String, Object>{
        'asset': key,
        if (match != null) 'dpr': double.parse(match[2]!),
      };
      final index = variants.indexWhere((v) => v is Map && v['asset'] == key);
      if (index < 0) {
        variants.add(value);
      } else {
        variants[index] = value;
      }
      map[base] = variants;
    }
    return codec.encodeMessage(map)!;
  }

  @override
  Future<ui.ImmutableBuffer> loadBuffer(String key) async {
    final data = await load(key);
    return ui.ImmutableBuffer.fromUint8List(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }
}
