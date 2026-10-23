import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:abelnotes/features/pages_tray/application/pages_tray_provider.dart';
import 'package:abelnotes/features/pages_tray/domain/pages_tray.dart';
import 'package:abelnotes/l10n/app_localizations.dart';
import 'package:abelnotes/shared/utils/chapter_title.dart';
import 'package:abelnotes/ui/primitives/hw_glass.dart';
import 'package:abelnotes/ui/theme/hw_icons.dart';
import 'package:abelnotes/ui/theme/hw_theme.dart';

/// Chapter dot colors, as in the page manager chips.
const List<Color> kChapterDots = [
  HwTheme.cover1,
  HwTheme.cover5,
  HwTheme.cover4,
  HwTheme.cover6,
  HwTheme.cover3,
];

String trayCountLine(AppLocalizations l, PagesTray t) =>
    t.isMove ? l.pgtTrayMoving(t.count) : l.pgtTrayCopied(t.count);

String trayFromLine(AppLocalizations l, PagesTray t) {
  if (t.sourceChapterTitle != null) {
    return l.pgtFromChapter(
        t.sourceTitle, chapterDisplayTitle(l, t.sourceChapterTitle!));
  }
  if (t.mixedChapters) return l.pgtFromSeveral(t.sourceTitle);
  return l.pgtFrom(t.sourceTitle);
}

String trayWhereText(AppLocalizations l, TrayWhere w) => switch (w.kind) {
      TrayWhereKind.start => l.pgtWhereStart,
      TrayWhereKind.afterPage => l.pgtWhereAfter(w.page),
      TrayWhereKind.end => l.pgtWhereEnd,
      TrayWhereKind.chapterEnd =>
        l.pgtWhereChapterEnd(chapterDisplayTitle(l, w.chapterTitle ?? '')),
    };

String trayToastText(AppLocalizations l, TrayToast t) {
  final nb = t.notebookTitle ?? '';
  final where = t.where == null ? '' : trayWhereText(l, t.where!);
  return switch (t.event) {
    TrayEvent.copied => t.skipped > 0
        ? l.pgtToastCopiedSkipped(t.count, t.skipped)
        : l.pgtToastCopied(t.count),
    TrayEvent.moveReady => t.skipped > 0
        ? l.pgtToastMoveReadySkipped(t.count, t.skipped)
        : l.pgtToastMoveReady(t.count),
    TrayEvent.moveCancelled => l.pgtToastMoveCancelled(t.count, nb),
    TrayEvent.trayCleared => l.pgtToastTrayCleared,
    TrayEvent.pasted => l.pgtToastPasted(t.count, nb, where),
    TrayEvent.moved => l.pgtToastMoved(t.count, nb, where),
    TrayEvent.duplicated => l.pgtToastDuplicated(t.count),
    TrayEvent.undone => l.pgtToastUndone,
    TrayEvent.tooMany => l.pgtToastTooMany(kTrayPageCap),
    TrayEvent.nothingToTake => l.pgtToastNothing,
    TrayEvent.trayNotSaved => l.pgtToastTrayNotSaved,
    TrayEvent.pastePagesGone => l.pgtToastPagesGone,
    TrayEvent.pasteTrayDamaged => l.pgtToastTrayDamaged,
    TrayEvent.pasteDestFailed => l.pgtToastDestFailed,
    TrayEvent.pasteDestUnavailable => l.pgtToastDestUnavailable,
    TrayEvent.moveSourceFailed => l.pgtToastSourceFailed(nb),
    TrayEvent.moveResumed => l.pgtToastMoveResumed(t.count),
    TrayEvent.undoFailed => l.pgtToastUndoFailed,
  };
}

/// The tray's pages fanned out like a hand of cards, with the count.
class TrayFan extends StatelessWidget {
  final PagesTray tray;
  final double scale;
  const TrayFan({super.key, required this.tray, this.scale = 1});

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    final n = tray.count.clamp(1, 3);
    const angles = [-11.0, 1.0, 12.0];
    const shifts = [-5.0, 0.0, 5.0];
    Widget card(int i) {
      final a = n == 1 ? 0.0 : angles[i] * 3.14159 / 180;
      final dx = n == 1 ? 0.0 : shifts[i];
      final thumb = i < tray.thumbs.length ? tray.thumbs[i] : null;
      return Positioned(
        left: 9,
        top: 5,
        width: 29,
        height: 41,
        child: Transform.translate(
          offset: Offset(dx, 0),
          child: Transform.rotate(
            angle: a,
            alignment: const Alignment(0, 0.9),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: p.ink0.withValues(alpha: 0.10)),
                boxShadow: [
                  BoxShadow(
                      color: p.ink0.withValues(alpha: 0.16),
                      blurRadius: 6,
                      offset: const Offset(0, 2)),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2.5),
                child: thumb == null
                    ? const SizedBox.expand()
                    : Image.memory(Uint8List.fromList(thumb),
                        fit: BoxFit.cover, gaplessPlayback: true),
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: 46 * scale,
      height: 50 * scale,
      child: FittedBox(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 46,
          height: 50,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 0; i < n; i++) card(i),
              Positioned(
                right: -3,
                bottom: -3,
                child: Container(
                  constraints:
                      const BoxConstraints(minWidth: 20, minHeight: 20),
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: p.accent,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: p.paper0, width: 2),
                  ),
                  child: Text('${tray.count}',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: p.onAccent,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fan plus "N pages · moving" and where they came from.
class TrayInfo extends StatelessWidget {
  final PagesTray tray;
  final double fanScale;
  const TrayInfo({super.key, required this.tray, this.fanScale = 1});

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    final l = AppLocalizations.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 420;
    final note =
        tray.sourceDeleted ? l.pgtSourceDeleted(tray.sourceTitle) : null;
    return Row(
      children: [
        TrayFan(tray: tray, scale: fanScale),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Flexible(
                  child: Text(trayCountLine(l, tray),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: p.ink0)),
                ),
                if (tray.saved) ...[
                  const SizedBox(width: 7),
                  Container(
                    padding: EdgeInsets.fromLTRB(4, 1, narrow ? 4 : 6, 1),
                    decoration: BoxDecoration(
                      color: HwTheme.syncOk.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const HwIcon('saved', size: 13, color: HwTheme.syncOk),
                      if (!narrow) ...[
                        const SizedBox(width: 3),
                        Text(l.pgtSavedShort,
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: HwTheme.syncOk)),
                      ],
                    ]),
                  ),
                ],
              ]),
              const SizedBox(height: 2),
              Text(note ?? trayFromLine(l, tray),
                  maxLines: note == null ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5,
                      height: 1.25,
                      color: note == null ? p.ink2 : p.ink0,
                      fontWeight:
                          note == null ? FontWeight.w400 : FontWeight.w500)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Round button with a glass-line fill (the tray's cancel / clear).
class TrayRoundButton extends StatelessWidget {
  final String icon;
  final String tooltip;
  final VoidCallback onTap;
  const TrayRoundButton(
      {super.key,
      required this.icon,
      required this.tooltip,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 34,
            height: 34,
            decoration:
                BoxDecoration(color: p.glassLine, shape: BoxShape.circle),
            child: Center(child: HwIcon(icon, size: 16, color: p.ink2)),
          ),
        ),
      ),
    );
  }
}

/// The accent action of the tray (Move here / Paste here).
class TrayPrimaryButton extends StatelessWidget {
  final String icon;
  final String label;
  final VoidCallback? onTap;
  const TrayPrimaryButton(
      {super.key, required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: HwPressable(
        enabled: onTap != null,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Opacity(
            opacity: onTap == null ? 0.5 : 1,
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: p.accent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                HwIcon(icon, size: 16, color: p.onAccent),
                const SizedBox(width: 7),
                Text(label,
                    style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: p.onAccent)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Message with its actions, at the bottom of the screen.
class TrayToastView extends StatefulWidget {
  final TrayToast toast;
  final VoidCallback onUndo;
  final VoidCallback onShow;
  final VoidCallback onClose;
  final ValueChanged<bool>? onHover;
  const TrayToastView({
    super.key,
    required this.toast,
    required this.onUndo,
    required this.onShow,
    required this.onClose,
    this.onHover,
  });

  @override
  State<TrayToastView> createState() => _TrayToastViewState();
}

class _TrayToastViewState extends State<TrayToastView> {
  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    final l = AppLocalizations.of(context);
    final t = widget.toast;
    Widget action(String label, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(left: 8),
          child: GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: p.accentSoft, borderRadius: BorderRadius.circular(15)),
              child: Text(label,
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                      color: p.accentDeep)),
            ),
          ),
        );
    return MouseRegion(
      onEnter: (_) => widget.onHover?.call(true),
      onExit: (_) => widget.onHover?.call(false),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: HwGlass(
          strong: true,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 10, 12),
            child: Row(children: [
              Expanded(
                child: Text(trayToastText(l, t),
                    style: TextStyle(
                        fontSize: 14,
                        height: 1.3,
                        fontWeight: FontWeight.w500,
                        color: p.ink0)),
              ),
              if (t.canUndo) action(l.pgtUndo, widget.onUndo),
              if (t.showNotebookId != null) action(l.pgtShow, widget.onShow),
              // No countdown bar: the toast closes on the next action or after a while.
              if (t.canUndo)
                GestureDetector(
                  onTap: widget.onClose,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
                    child: HwIcon('x', size: 16, color: p.ink2),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
