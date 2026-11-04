# Plugin-only iOS verification

Environment: Flutter 3.47.1, Dart 3.13.1, Xcode 27.1 on the development Mac.

Scope: the optional `packages/flutter_patcher_ios` companion and its tools.
No host application or backend integration was performed.

## Automated checks

| Check | Result |
| --- | --- |
| Companion `flutter test --no-pub --concurrency 1` | 52 passed |
| Existing root Android package Dart/CLI suite | 27 passed |
| Vendored Flutter bridge upstream/compatibility suite | 17 passed |
| Companion Dart analyzer | No issues |
| Root Dart analyzer | No issues |
| `git diff --cached --check` | Passed |
| Headless compile CLI on example sources | Passed |
| Signed pack CLI output installed and executed by real runtime | Passed in companion suite |
| Git dependency resolution with nested vendored bridge | Passed against the local feature branch |

The 96 tests cover signature/hash/host/runtime checks, package limits and paths,
immutable generation selection, offline reopening, interrupted starts, rollback,
asset manifests and buffers, rendered patched images/widgets, invocation argument
boxing and native JSON results, HTTP delivery, and preserved error handlers.

Independent API review found argument boxing and nested collection-return issues.
These were reproduced with tests, fixed, and approved on scoped re-review.

## iOS release build

An ignored temporary app at `temp/ios_smoke` imports and references the runtime,
store, client, asset guard, and prepared widget invocation. No app was installed.

The ordinary unsigned release command reached asset bundling but failed because
the interpreter constructs IconData dynamically. Host release builds must use
`--no-tree-shake-icons`, now documented in the companion README.

The corrected verification command passed:

```sh
flutter build ios --release --no-codesign --no-pub --no-tree-shake-icons
```

Result: `build/ios/iphoneos/Runner.app`, 21.2 MB. Xcode completed successfully
in 306.8 seconds. This is an unsigned release build for the generic iOS device
target, not a simulator test or an installed/signed device application.

Physical iPhone release execution, downloaded-patch activation, and device
rollback remain unverified. Automated tests and an unsigned build are separate
from those device acceptance checks.

## Distribution

Implementation commit: `7b63141` on local branch
`feat/ios-interpreted-patches`. Nothing has been pushed, published, or deployed.
Git resolution was tested using a local repository URL, including the nested
`vendor/flutter_eval` dependency. The README's remote branch example becomes
usable on other machines only after that branch is pushed.
