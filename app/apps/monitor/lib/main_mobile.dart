// Explicit collector entry used for Android builds and the browser collector
// preview. Both execute the same widget and API logic.
import 'package:flutter/material.dart';
import 'screens.dart';

void main() => runApp(const CapstoneApp(role: AppRole.mobile));
