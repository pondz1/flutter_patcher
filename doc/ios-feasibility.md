# iOS code and asset OTA: feasibility and proposed scope

Status: historical research; plugin-only implementation is being verified in
`packages/flutter_patcher_ios`. The user has confirmed both Dart
code and assets for Flutter host apps, using a self-hosted server with no hosted
code-push subscription and subsequently approved the prepared-entrypoint design,
with host-app integration deferred.

## Existing implementation

At fork revision `f98a977`, `pubspec.yaml` registers Android only.
`FlutterPatcher` guards all entrypoints with `Platform.isAndroid`. The Android
loader replaces the AOT library and redirects the Flutter asset bundle before
engine startup. `bin/pack.dart` extracts an Android `libapp.so` from an APK and
always includes that library in a schema-2 ZIP. None of these paths provides an
iOS runtime.

Removing the platform guard or adding an iOS registration alone would not make
Dart code patches executable on iPhones. An IPA packer that extracts a replacement
`App.framework` is not a demonstrated solution either.

## Runtime alternatives

| Approach | Dart patch scope | Host-app changes | Self-hosting implications |
| --- | --- | --- | --- |
| Embedded `dart_eval` / `flutter_eval` | Functions and widget subtrees deliberately routed through the interpreter; supported language features and bindings only | Ship the interpreter, register patch entrypoints, and bridge host APIs | Bytecode and assets can be delivered from our server |
| Custom Flutter/Dart compiler and runtime | Goal: patch application Dart code without manually wrapping each patchable function | Build and ship a custom SDK/runtime in the base app | Requires a compiler/runtime project as well as patch distribution |
| Hosted Shorebird for code plus our asset delivery | Code updates supported by Shorebird's runtime | Build the base app and patches with Shorebird | Code delivery uses a separate service; not a fully self-hosted replacement |

The embedded-interpreter approach is the recommended first implementation if
explicit patch entrypoints and incomplete Dart/Flutter coverage are acceptable.
It must not be described as arbitrary replacement of an existing AOT app.

Shorebird documents a custom interpreter, compiler changes, and linking to reuse
the signed base program on iOS. Its architecture page also identifies its Dart
SDK fork as private. Its public updater alone therefore does not supply the
complete compiler/runtime needed to reproduce its iOS implementation.

## Proposed embedded-interpreter design

This is conditional on accepting the entrypoint and language restrictions above.

- Keep the current Android AOT path. Introduce a distinct, versioned iOS package
  format containing compiled interpreter bytecode, asset overlays, and metadata.
  Do not send iOS packages through the existing Android schema-2 reader.
- Compile on the developer machine or CI using an exactly matched runtime and
  binding version. Reject unsupported code while building a patch, before it is
  published. Package already compiled bytecode; do not compile source on-device.
- Include platform, host release identity, runtime format version, binding/API
  version, and hashes in the package contract. An iOS build number can be a
  string and must not silently pass through the Android integer-only contract.
- Authenticate each iOS package with an Ed25519 signature over a defined SHA-256
  digest. Validate paths, duplicate ZIP entries, extraction size, and all file
  digests before installing. Preserve the existing Android protocol separately.
- Stage and commit code and assets as one generation. Keep the running generation
  immutable; select the new generation on the next process start. Reject
  incompatible releases, runtime versions, and binding versions before execution.
- Expose explicit patchable widget/function entrypoints and a patched asset
  bundle. Fall back to the shipped implementation when no compatible patch is
  selected. A `DefaultAssetBundle` override does not redirect direct calls to
  `rootBundle`; document a patched bundle accessor for those callers. Do not claim
  transparent interception of every existing asset lookup.
- Persist boot attempts before entering patched code. Distinguish detected Dart
  startup errors from interrupted launches; iOS process termination alone does
  not prove a crash. Use a bounded retry policy and report the actual reason for
  fallback. Keep diagnostics and a bad-patch blacklist.

## Acceptance criteria before claiming iOS support

1. A release build on a physical iPhone loads an updated widget and updated Dart
   function result from interpreter bytecode, without reinstalling the base app.
2. The same installed patch changes an image and JSON asset on cold start.
3. The selected code and assets always belong to the same package generation.
4. Invalid signatures, corrupt payloads, unsafe archives, incompatible host or
   runtime versions, and missing bindings fail without replacing the working
   generation.
5. Manual rollback and startup-failure recovery restore bundled behavior after
   restart; offline launch continues to work.
6. Interrupted installation recovers without a mixed or partially installed
   generation. Existing Android package and CLI tests remain passing.

Simulator and widget tests support development, but do not establish physical
iPhone release compatibility. Successful execution also does not guarantee
App Store acceptance of every update or use case.

## Host integration boundary

Host applications must prepare explicit function/widget entrypoints and
provide supported bindings for their own models and APIs. A standalone
widget demonstration does not establish compatibility with an existing
application. Full-app updates and patch generations need distinct
contracts; native SDK changes still require a full release.

Application and backend integration are outside this plugin-only scope.

## Compatibility check on the installed SDK

Compatibility was investigated using the installed development SDK.
`flutter --version` reports Flutter `3.47.1`, Dart `3.13.1`. An isolated upstream
`flutter_eval` checkout at `73d7f43ac741093475f594bad58c4b371e4e0d84`
(package `0.8.2`) resolved its dependencies with published `dart_eval 0.8.5`.
Its checked-in `.fvmrc` names Flutter `3.35.2`.

Running the existing upstream test with:

```sh
flutter test test/flutter_eval_test.dart --plain-name 'Can extend StatelessWidget' --reporter expanded
```

failed before test execution: `$Container implements Container` is missing
`Container.isAntiAlias`, present in the installed Flutter SDK. This is a
reproduced compiler compatibility failure, not evidence that code push works.
The candidate runtime must be adapted and retested before app integration.
That failure was the baseline. The companion now contains a licensed vendored
Flutter bridge with a Container.isAntiAlias compatibility adaptation and an
additional behavior test. Its 17 upstream/compatibility tests have passed on the
installed SDK. App/backend integration and physical iPhone verification remain
outside the completed evidence.

## Sources

- [Shorebird system architecture](https://docs.shorebird.dev/code-push/system-architecture/)
- [Shorebird FAQ: self-hosting](https://docs.shorebird.dev/code-push/faq/#can-you-self-host-shorebird)
- [flutter_eval: integration and supported-feature caveats](https://github.com/ethanblake4/flutter_eval)
- [dart_eval: interpreter and language support](https://github.com/ethanblake4/dart_eval)
- [Flutter DefaultAssetBundle](https://api.flutter.dev/flutter/widgets/DefaultAssetBundle-class.html)
- [Flutter rootBundle](https://api.flutter.dev/flutter/services/rootBundle.html)
- [Flutter iOS project initialization](https://github.com/flutter/flutter/blob/master/engine/src/flutter/shell/platform/darwin/ios/framework/Source/FlutterDartProject.mm)

Sources reviewed on 2026-11-04. Dependency versions and compatibility must be
verified against the actual selected Flutter SDK during implementation.
