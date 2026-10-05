# usb_serial 0.5.2 build compatibility patch

Source: the published `usb_serial` 0.5.2 package, https://github.com/altera2015/usbserial.
The BSD-3-Clause LICENSE is retained. Dart and Java sources are unchanged.

Build-only changes: use the host Android plugin rather than AGP 4.1, replace
removed `jcenter()` with Maven Central, set the existing package namespace in
Gradle and remove the manifest package attribute, compile against SDK 36, and
use the current lint DSL. The native UsbSerial library remains pinned to 6.1.0.
No USB protocol, notification rate or acquisition behavior changes.

This local path dependency makes these changes reproducible after a fresh pub
cache. Remove the local patch when a tested upstream release supports this
project's build tools. See https://docs.gradle.org/current/userguide/upgrading_major_version_9.html.
