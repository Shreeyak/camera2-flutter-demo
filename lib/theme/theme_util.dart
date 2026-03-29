// lib/theme/theme_util.dart
//
// Helper to merge two Google Fonts into a MaterialTheme-compatible TextTheme.
// Copied from the Material Theme Builder export (util.dart).
//
// Usage:
//   final textTheme = createTextTheme('Roboto', 'Noto Sans');
//   final theme = MaterialTheme(textTheme);

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// No BuildContext needed — the base scale is the M3 default, which is what
// Theme.of(context).textTheme returns at the app root before any MaterialApp
// ancestor exists anyway.
TextTheme createTextTheme(String bodyFontString, String displayFontString) {
  const TextTheme baseTextTheme = TextTheme();
  TextTheme bodyTextTheme = GoogleFonts.getTextTheme(
    bodyFontString,
    baseTextTheme,
  );
  TextTheme displayTextTheme = GoogleFonts.getTextTheme(
    displayFontString,
    baseTextTheme,
  );
  TextTheme textTheme = displayTextTheme.copyWith(
    bodyLarge: bodyTextTheme.bodyLarge,
    bodyMedium: bodyTextTheme.bodyMedium,
    bodySmall: bodyTextTheme.bodySmall,
    labelLarge: bodyTextTheme.labelLarge,
    labelMedium: bodyTextTheme.labelMedium,
    labelSmall: bodyTextTheme.labelSmall,
  );
  return textTheme;
}
