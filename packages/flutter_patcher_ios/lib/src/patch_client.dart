import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'models.dart';
import 'patch_store.dart';

class PatchClient {
  final PatchStore store;
  final Duration timeout;
  final bool allowLocalHttp;
  final int maxEnvelopeBytes;
  PatchClient(
    this.store, {
    this.timeout = const Duration(seconds: 30),
    this.allowLocalHttp = false,
    this.maxEnvelopeBytes = 64 * 1024,
  });

  /// GET `{hasUpdate: false}` or `{hasUpdate: true, patch: envelopeJson}`.
  /// Headers for checking and downloading are separate to avoid credential leaks.
  Future<bool> checkAndInstall(
    Uri checkUrl, {
    Map<String, String> headers = const {},
    Map<String, String> downloadHeaders = const {},
  }) async {
    try {
      final json = objectMap(
        jsonDecode(
          utf8.decode(await _get(checkUrl, maxEnvelopeBytes, headers)),
        ),
      );
      if (json['hasUpdate'] == false) return false;
      if (json['hasUpdate'] != true) {
        throw const PatchException('PROTOCOL', 'Expected hasUpdate boolean');
      }
      final envelope = PatchEnvelope.fromJson(objectMap(json['patch']));
      if (envelope.size <= 0 ||
          envelope.size > store.codec.limits.maxZipBytes) {
        throw const PatchException('LIMIT', 'Patch exceeds download limit');
      }
      final bytes = await _get(
        envelope.downloadUrl,
        envelope.size,
        downloadHeaders,
      );
      await store.install(bytes, envelope);
      return true;
    } on PatchException {
      rethrow;
    } catch (e) {
      throw PatchException('NETWORK', 'Patch update failed: $e');
    }
  }

  void _checkUrl(Uri uri) {
    final loopback = {
      '127.0.0.1',
      'localhost',
      '::1',
      '[::1]',
    }.contains(uri.host);
    if (uri.userInfo.isNotEmpty ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' &&
            !(allowLocalHttp && uri.scheme == 'http' && loopback))) {
      throw const PatchException(
        'URL',
        'HTTPS required (loopback HTTP is opt-in for tests)',
      );
    }
  }

  Future<Uint8List> _get(
    Uri url,
    int limit,
    Map<String, String> headers,
  ) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await (() async {
        var uri = url;
        var forwarded = Map<String, String>.from(headers);
        for (var redirects = 0; redirects <= 3; redirects++) {
          _checkUrl(uri);
          final request = await client.getUrl(uri);
          request.followRedirects = false;
          forwarded.forEach(request.headers.set);
          final response = await request.close();
          if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            if (location == null) {
              throw const PatchException(
                'NETWORK',
                'Redirect without location',
              );
            }
            final next = uri.resolve(location);
            if (next.origin != uri.origin) forwarded = {};
            uri = next;
            continue;
          }
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw PatchException('NETWORK', 'HTTP ${response.statusCode}');
          }
          if (response.contentLength > limit) {
            throw const PatchException('LIMIT', 'Response too large');
          }
          final bytes = BytesBuilder(copy: false);
          var count = 0;
          await for (final chunk in response) {
            count += chunk.length;
            if (count > limit) {
              throw const PatchException('LIMIT', 'Stream exceeds size limit');
            }
            bytes.add(chunk);
          }
          return bytes.takeBytes();
        }
        throw const PatchException('NETWORK', 'Too many redirects');
      })().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }
}
