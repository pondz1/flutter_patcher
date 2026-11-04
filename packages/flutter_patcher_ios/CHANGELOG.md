# 0.1.0

Experimental optional companion for prepared iOS Dart entrypoints and Flutter
asset overlays, with signed self-hosted packages and cold-start selection.
Includes headless compiler, signed ZIP packer, persistent rollback, and tests.
Verified on Flutter 3.47.1 / Dart 3.13.1 in automated host tests.
Unsigned iOS release smoke build passed with `--no-tree-shake-icons`, which is
required for release builds including the dynamic icon bridge.
Physical iPhone release patch/rollback verification is still outstanding.
Host application and server integration are not included.
