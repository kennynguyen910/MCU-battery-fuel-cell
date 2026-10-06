// Explicit entry for the temporary device-input dashboard. This screen publishes
// frames but is intentionally unable to save measurements directly.
import 'package:flutter/material.dart';
import 'screens.dart';

void main() => runApp(const CapstoneApp(role: AppRole.input));
