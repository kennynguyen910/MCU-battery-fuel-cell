// Default application entry: browsers show history while native platforms show
// the collector. Explicit preview entries below avoid guessing during demos.
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'screens.dart';

// kIsWeb is a compile-time platform constant, not a screen-size heuristic.
void main() => runApp(CapstoneApp(role: kIsWeb ? AppRole.web : AppRole.mobile));
