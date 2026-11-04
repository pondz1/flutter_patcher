# Vendored flutter_eval

Source: https://github.com/ethanblake4/flutter_eval

Revision: `73d7f43ac741093475f594bad58c4b371e4e0d84` (0.8.2).
Original BSD-3-Clause license and copyright are preserved in LICENSE.
Only lib/ and upstream tests are included. dart_eval is pinned to published
0.8.5 to keep compiler and runtime bytecode compatible.

Local adaptation: Container.isAntiAlias declaration, constructor forwarding,
and getter for Flutter 3.47.1. The additional compatibility test covers false
as well as default true.

The companion uses verified local programs through its own runtime adapter.
It does not use upstream HotSwapLoader or RuntimeWidget URL downloading paths.

Whitespace-only cleanup removes upstream trailing spaces in colors.dart,
widgets.dart, widgets/framework.dart, and upstream tests; behavior is unchanged.
