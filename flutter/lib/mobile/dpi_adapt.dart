import 'dart:math' as math;

import 'package:flutter/widgets.dart';

// Overall UI scaling: follow the system font size, bounded so very large
// accessibility settings do not break fixed-height rows in this fork's UI.
TextScaler adaptiveTextScaler(BuildContext context) {
  final system = MediaQuery.textScalerOf(context).scale(14) / 14;
  return TextScaler.linear(system.clamp(0.85, 1.3).toDouble());
}

// Remote picture adaptation: pick the closest 16:9 host resolution from the
// phone's physical short side, so a phone-sized screen does not stream a
// 2560-wide desktop (or a tiny 720p one on a high-DPI phone).
String? adaptiveDisplayMode(BuildContext context) {
  final media = MediaQuery.maybeOf(context);
  if (media == null) return null;
  final shortSide =
      math.min(media.size.width, media.size.height) * media.devicePixelRatio;
  if (!shortSide.isFinite || shortSide <= 0) return null;
  if (shortSide <= 800) return '1280x720';
  if (shortSide <= 960) return '1536x864';
  if (shortSide <= 1200) return '1920x1080';
  return '2560x1440';
}