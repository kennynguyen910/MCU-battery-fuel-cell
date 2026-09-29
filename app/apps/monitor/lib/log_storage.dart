// Select storage at compile time: real app-document file on Android/iOS,
// browser-local storage for the browser preview of the same collector.
export 'log_storage_io.dart'
    if (dart.library.js_interop) 'log_storage_web.dart';
