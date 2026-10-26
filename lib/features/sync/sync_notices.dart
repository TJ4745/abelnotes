import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:abelnotes/core/platform/storage_health.dart'
    if (dart.library.js_interop) 'package:abelnotes/core/platform/storage_health_web.dart';
import 'package:abelnotes/core/providers/app_settings_provider.dart';
import 'package:abelnotes/core/providers/auth_provider.dart';
import 'package:abelnotes/core/providers/notebook_provider.dart';
import 'package:abelnotes/core/providers/remote_store_provider.dart';
import 'package:abelnotes/core/services/remote_store.dart';
import 'package:abelnotes/core/services/sync_service.dart';
import 'package:abelnotes/features/auth/login_screen.dart';
import 'package:abelnotes/features/sync/drive_connect.dart';
import 'package:abelnotes/l10n/app_localizations.dart';
import 'package:abelnotes/ui/primitives/hw_button.dart';
import 'package:abelnotes/ui/theme/hw_icons.dart';
import 'package:abelnotes/ui/theme/hw_theme.dart';

/// Lets the re-login banner open a route from above the Navigator.
final syncNavigatorKey = GlobalKey<NavigatorState>();

/// User-facing text for an error raised by a sync operation; anything not
/// recognised falls back to its technical description.
String syncErrorText(AppLocalizations l10n, Object e) {
  if (e is NoRemoteException) return l10n.qsNoServerConnected;
  if (e is RemoteStoreException && e.statusCode == 401) {
    return l10n.qsLoginWrongCredentials;
  }
  if (e is RemoteStoreException && e.statusCode == 429) {
    return l10n.qsLoginThrottled;
  }
  return e.toString();
}

/// Library footer action: pull what the server has and push what waits.
class SyncRefreshButton extends ConsumerWidget {
  const SyncRefreshButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(remoteStoreProvider) == null) return const SizedBox.shrink();
    final p = HwThemeScope.of(context);
    final notifier = ref.read(notebookListProvider.notifier);
    return ValueListenableBuilder<bool>(
      valueListenable: notifier.isSyncing,
      builder: (_, syncing, __) => HwButton.icon(
        icon: HwIcon('rotate', size: 16, color: syncing ? p.ink3 : p.ink1),
        tooltip: AppLocalizations.of(context).qsRefreshTooltip,
        onPressed: syncing ? null : () => notifier.syncNow(),
      ),
    );
  }
}

/// Lists notebooks another device deleted while this one kept its edits.
class DeletedElsewhereNotice extends ConsumerWidget {
  const DeletedElsewhereNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(notebookListProvider.notifier);
    final p = HwThemeScope.of(context);
    final l10n = AppLocalizations.of(context);
    return ValueListenableBuilder<Set<String>>(
      valueListenable: notifier.deletedElsewhere,
      builder: (_, ids, __) {
        if (ids.isEmpty) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          color: p.paper2,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 10),
          child: Row(
            children: [
              HwIcon('cloud-off', size: 14, color: p.ink3),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.qsDeletedElsewhere(ids.length),
                        style: TextStyle(fontSize: 13, color: p.ink1)),
                    Text(l10n.qsDeletedElsewhereHint,
                        style: TextStyle(fontSize: 11, color: p.ink3)),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => notifier.dismissDeletedElsewhere(),
                child: Text(l10n.rcbDismiss,
                    style: TextStyle(fontSize: 12, color: p.ink2)),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Wraps the whole app: while the server rejects the saved credentials, or
/// Drive has no token left, a banner offers to sign in again, on every screen
/// including the editor.
class ReauthBannerHost extends ConsumerWidget {
  final Widget child;
  const ReauthBannerHost({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show = ref.watch(needsReauthProvider);
    final creds = ref.watch(credentialsProvider);
    final onDrive = useNativeGoogleSignIn &&
        ref.watch(appSettingsProvider.select((s) => s.syncBackend)) ==
            SyncBackend.drive;
    final l10n = AppLocalizations.of(context);
    // The banner slot is always there so the Navigator below keeps its place
    // in the tree (and its routes) when the banner comes and goes.
    return Column(
      children: [
        ValueListenableBuilder<String?>(
          valueListenable: browserStorageError,
          builder: (context, error, _) => error == null
              ? const SizedBox.shrink()
              : _ReauthBanner(text: l10n.qsBrowserStorageFull),
        ),
        if (onDrive)
          ValueListenableBuilder<bool>(
            valueListenable: ref.watch(nativeGoogleAuthProvider).needsSignIn,
            builder: (context, needs, _) => !needs
                ? const SizedBox.shrink()
                : _ReauthBanner(
                    text: l10n.qsDriveReauthBanner,
                    action: l10n.qsReauthAction,
                    // The dialog and the popup need the Navigator's context.
                    onPressed: () {
                      final nav = syncNavigatorKey.currentContext;
                      if (nav != null) connectDrive(nav, ref);
                    },
                  ),
          )
        else if (show && creds != null)
          _ReauthBanner(
            text: l10n.qsReauthBanner,
            action: l10n.qsReauthAction,
            onPressed: () => syncNavigatorKey.currentState?.push(
                MaterialPageRoute(builder: (_) => LoginScreen(reauth: creds))),
          )
        else
          const SizedBox.shrink(),
        Expanded(child: child),
      ],
    );
  }
}

class _ReauthBanner extends StatelessWidget {
  final String text;
  final String? action;
  final VoidCallback? onPressed;
  const _ReauthBanner({required this.text, this.action, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Material(
      color: Color.alphaBlend(
          HwTheme.syncConflict.withValues(alpha: 0.14), p.paper1),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              const HwIcon('cloud-off', size: 16, color: HwTheme.syncConflict),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text, style: TextStyle(fontSize: 13, color: p.ink0)),
              ),
              if (action != null) ...[
                const SizedBox(width: 8),
                HwButton(
                  label: action!,
                  style: HwButtonStyle.primary,
                  onPressed: onPressed,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
