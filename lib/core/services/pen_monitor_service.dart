// ═══════════════════════════════════════════════════════════════
//  pen_monitor_service.dart
//
//  Linux-only: maps a graphics-tablet / stylus to a single monitor by
//  applying an xinput "Coordinate Transformation Matrix", so the pen's
//  active area covers exactly one screen instead of being stretched
//  across the whole multi-monitor desktop.
//
//  This is the in-app port of the standalone `pennina.sh` script: same
//  xrandr geometry parsing + matrix math, but driven from the editor UI
//  with a monitor picker (no terminal needed) and reversible from the
//  same menu.
// ═══════════════════════════════════════════════════════════════

import 'package:abelnotes/core/platform/io.dart';
import 'dart:math' as math;

/// A connected, positioned monitor as reported by `xrandr --query`.
class PenMonitorInfo {
  final String name;
  final int x;
  final int y;
  final int width;
  final int height;

  const PenMonitorInfo({
    required this.name,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  String get geometry => '$width×$height @ ($x, $y)';
}

enum PenMonitorError { toolMissing, toolFailed, noMonitor, noPen, badGeometry }

class PenMonitorException implements Exception {
  final PenMonitorError error;
  final String? tool;
  final String? detail;
  PenMonitorException(this.error, {this.tool, this.detail});
  @override
  String toString() => 'PenMonitorException: ${error.name} $tool $detail';
}

class PenMonitorService {
  /// Whether to offer the pen-to-monitor feature at all. It relies on X11
  /// tooling (xrandr / xinput), so it is gated on a real X11 session: on
  /// Wayland the tablet→output mapping is a compositor privilege with no
  /// portable API and xinput cannot reach the device, so offering it there
  /// only produces a cryptic "xrandr not found". Hidden on Wayland, macOS
  /// and Windows; visible (and working) on an Xorg session.
  static bool get isSupported => isX11;

  /// True only on a genuine X11 (Xorg) session, where xinput controls the
  /// input devices. False on Wayland — including via Xwayland, where mapping
  /// the pen through the X server does not affect the real Wayland device —
  /// and on non-Linux platforms.
  static bool get isX11 {
    if (!Platform.isLinux) return false;
    final env = Platform.environment;
    switch (env['XDG_SESSION_TYPE']?.toLowerCase()) {
      case 'x11':
        return true;
      case 'wayland':
        return false;
    }
    // XDG_SESSION_TYPE unset on some setups: infer from the sockets — an X
    // DISPLAY present with no Wayland socket means a plain Xorg session.
    final hasWayland = (env['WAYLAND_DISPLAY'] ?? '').isNotEmpty;
    final hasDisplay = (env['DISPLAY'] ?? '').isNotEmpty;
    return hasDisplay && !hasWayland;
  }

  // e.g. "HDMI-1 connected primary 1920x1080+0+0 (normal ...) 509mm x 286mm"
  //      "DP-2 connected 2560x1440+1920+0 ..."
  static final RegExp _connectedLine =
      RegExp(r'^(\S+) connected.*?(\d+)x(\d+)\+(-?\d+)\+(-?\d+)');

  // Name fallback for pens that show no pressure axis until in range.
  static final RegExp _penName =
      RegExp(r'stylus|pen|wacom', caseSensitive: false);

  // "⎜   ↳ GAOMON Gaomon Tablet Pad   id=7   [slave  pointer  (2)]"
  static final RegExp _slavePointerLine =
      RegExp(r'↳\s*(.+?)\s+id=(\d+)\s+\[slave\s+pointer');

  static final RegExp _pressureAxis = RegExp(r'Label:\s*Abs Pressure');

  /// Slave pointer devices from `xinput list`, virtual XTEST ones excluded.
  static List<({int id, String name})> parseSlavePointers(String xinputList) {
    final out = <({int id, String name})>[];
    for (final line in xinputList.split('\n')) {
      final m = _slavePointerLine.firstMatch(line);
      if (m == null) continue;
      final name = m.group(1)!.trim();
      if (name.contains('XTEST')) continue;
      out.add((id: int.parse(m.group(2)!), name: name));
    }
    return out;
  }

  /// Whether `xinput list --long <id>` reports a pressure valuator.
  static bool hasPressureAxis(String xinputLong) =>
      _pressureAxis.hasMatch(xinputLong);

  /// Active monitors (connected + positioned). Throws [PenMonitorException]
  /// if xrandr is missing or returns nothing usable.
  Future<List<PenMonitorInfo>> listMonitors() async {
    final ProcessResult res;
    try {
      res = await Process.run('xrandr', const ['--query']);
    } on ProcessException catch (e) {
      throw PenMonitorException(PenMonitorError.toolMissing,
          tool: 'xrandr', detail: e.message);
    }
    if (res.exitCode != 0) {
      throw PenMonitorException(PenMonitorError.toolFailed,
          tool: 'xrandr', detail: '${res.stderr}');
    }
    final out = '${res.stdout}';
    final monitors = <PenMonitorInfo>[];
    for (final line in out.split('\n')) {
      final m = _connectedLine.firstMatch(line);
      if (m == null) continue;
      monitors.add(PenMonitorInfo(
        name: m.group(1)!,
        width: int.parse(m.group(2)!),
        height: int.parse(m.group(3)!),
        x: int.parse(m.group(4)!),
        y: int.parse(m.group(5)!),
      ));
    }
    if (monitors.isEmpty) {
      throw PenMonitorException(PenMonitorError.noMonitor);
    }
    return monitors;
  }

  /// Ids of the pointer devices that are pens: those with a pressure axis,
  /// else those named like one. By id, not name: tablets often register a
  /// keyboard device with the pen's name, which rejects the matrix
  /// (BadMatch), and a name shared by two devices is refused as ambiguous.
  Future<List<int>> findPenDevices() async {
    final list = await _xinput(const ['list']);
    if (list == null) return const [];
    final pointers = parseSlavePointers(list);
    final pens = <int>[];
    for (final p in pointers) {
      final long = await _xinput(['list', '--long', '${p.id}']);
      if (long != null && hasPressureAxis(long)) pens.add(p.id);
    }
    if (pens.isEmpty) {
      pens.addAll(
          pointers.where((p) => _penName.hasMatch(p.name)).map((p) => p.id));
    }
    return pens;
  }

  /// stdout of `xinput args`, or null when it exits non-zero.
  Future<String?> _xinput(List<String> args) async {
    final ProcessResult res;
    try {
      res = await Process.run('xinput', args);
    } on ProcessException catch (e) {
      throw PenMonitorException(PenMonitorError.toolMissing,
          tool: 'xinput', detail: e.message);
    }
    return res.exitCode == 0 ? '${res.stdout}' : null;
  }

  /// Constrain the pen to [monitor]. [allMonitors] is the full set returned
  /// by [listMonitors] (needed to size the transform against the whole
  /// desktop). Mirrors the matrix pennina.sh builds:
  ///
  ///   [ w/W   0    x/W ]
  ///   [  0   h/H   y/H ]
  ///   [  0    0     1  ]
  ///
  /// where (w,h,x,y) is the monitor and (W,H) the total desktop extent.
  Future<void> mapPenToMonitor(
    PenMonitorInfo monitor,
    List<PenMonitorInfo> allMonitors,
  ) async {
    final pens = await findPenDevices();
    if (pens.isEmpty) {
      throw PenMonitorException(PenMonitorError.noPen);
    }

    var totalW = 0;
    var totalH = 0;
    for (final m in allMonitors) {
      totalW = math.max(totalW, m.x + m.width);
      totalH = math.max(totalH, m.y + m.height);
    }
    if (totalW <= 0 || totalH <= 0) {
      throw PenMonitorException(PenMonitorError.badGeometry);
    }

    final matrix = <double>[
      monitor.width / totalW, 0, monitor.x / totalW, //
      0, monitor.height / totalH, monitor.y / totalH, //
      0, 0, 1,
    ].map((v) => v.toStringAsFixed(6)).toList();

    for (final id in pens) {
      await _setMatrix(id, matrix);
    }
  }

  /// Reset the pen to span the entire desktop again (identity matrix).
  Future<void> resetPen() async {
    final pens = await findPenDevices();
    if (pens.isEmpty) {
      throw PenMonitorException(PenMonitorError.noPen);
    }
    for (final id in pens) {
      await _setMatrix(id, const ['1', '0', '0', '0', '1', '0', '0', '0', '1']);
    }
  }

  Future<void> _setMatrix(int id, List<String> matrix) async {
    final ProcessResult res;
    try {
      res = await Process.run('xinput', [
        'set-prop',
        '$id',
        'Coordinate Transformation Matrix',
        ...matrix,
      ]);
    } on ProcessException catch (e) {
      throw PenMonitorException(PenMonitorError.toolMissing,
          tool: 'xinput', detail: e.message);
    }
    if (res.exitCode != 0) {
      throw PenMonitorException(PenMonitorError.toolFailed,
          tool: 'xinput', detail: '${res.stderr}');
    }
  }
}
