import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_scope.dart';
import 'core/format.dart';
import 'core/settings/app_settings.dart';
import 'core/theme/app_theme.dart';
import 'data/doc_entry.dart';
import 'data/file_library.dart';
import 'features/files/file_actions.dart';
import 'features/language/language_page.dart';
import 'features/onboarding/onboarding_page.dart';
import 'features/shell/main_shell.dart';
import 'features/splash/splash_page.dart';
import 'features/welcome/welcome_back_page.dart';
import 'l10n/s.dart';
import 'services/ad_service.dart';
import 'services/billing_service.dart';
import 'services/platform_bridge.dart';
import 'widgets/chrome.dart';

class AllDocApp extends StatelessWidget {
  const AllDocApp({
    super.key,
    required this.settings,
    required this.library,
    required this.ads,
    required this.billing,
  });

  final AppSettings settings;
  final FileLibrary library;
  final AdService ads;
  final BillingService billing;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      settings: settings,
      library: library,
      ads: ads,
      billing: billing,
      child: const _ThemedApp(),
    );
  }
}

class _ThemedApp extends StatelessWidget {
  const _ThemedApp();

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    return MaterialApp(
      title: 'All Document Reader',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: settings.themeMode,
      themeAnimationDuration: Duration.zero,
      navigatorObservers: [shellRouteObserver],
      locale: settings.locale,
      supportedLocales: [for (final lang in languages) lang.locale],
      localizationsDelegates: const [
        SDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        final bg = Theme.of(context).scaffoldBackgroundColor;
        SystemChrome.setSystemUIOverlayStyle(
          SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
            statusBarBrightness: dark ? Brightness.dark : Brightness.light,
            systemNavigationBarColor: bg,
            systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          ),
        );
        return ColoredBox(
          color: bg,
          child: _HoldTopInset(ads: AppScope.of(context).ads, child: child ?? const SizedBox.shrink()),
        );
      },
      home: const RootGate(),
    );
  }
}

/// While a full-screen ad (App Open / interstitial) is open, the system hides the status bar and
/// the app's top inset drops to 0 for a moment: every header (All files, Tools, Settings…) would
/// jump up into the status-bar strip, which the ad leaves see-through, and show above the ad.
/// During an ad (and the 2 s after it, see AdService.fullScreenActive) the last real status-bar
/// height is kept, so the headers stay where they are, behind the ad. Screens that hide the
/// status bar on purpose (reader full screen) are not affected: no ad is open then.
class _HoldTopInset extends StatefulWidget {
  const _HoldTopInset({required this.ads, required this.child});

  final AdService ads;
  final Widget child;

  @override
  State<_HoldTopInset> createState() => _HoldTopInsetState();
}

class _HoldTopInsetState extends State<_HoldTopInset> {
  double _lastPadding = 0;
  double _lastViewPadding = 0;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final top = media.padding.top;
    final viewTop = media.viewPadding.top;
    if (top > 0) _lastPadding = top;
    if (viewTop > 0) _lastViewPadding = viewTop;
    final hold = top == 0 && _lastPadding > 0 && widget.ads.fullScreenActive;
    // always the same MediaQuery widget here, so the screens below keep their state either way
    return MediaQuery(
      data: hold
          ? media.copyWith(
              padding: media.padding.copyWith(top: _lastPadding),
              viewPadding: media.viewPadding.copyWith(top: viewTop > 0 ? viewTop : _lastViewPadding),
            )
          : media,
      child: widget.child,
    );
  }
}

enum _Stage { boot, splash, launchFile, language, onboarding, shell }

class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> with WidgetsBindingObserver {
  /// "boot" only until it is known whether a file started the app (no splash / ad flash then).
  _Stage _stage = Platform.environment.containsKey('FLUTTER_TEST') ? _Stage.splash : _Stage.boot;
  bool _welcome = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final scope = AppScope.of(context);
      // only the app's own index here: the device scan (and the storage-access question) start
      // from the All files tab, like the Android app
      unawaited(scope.library.scan());
      scope.ads.bootstrap();
      scope.billing.start();
      PlatformBridge.listen(_acceptIncoming);
      _boot();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    // "Default" language: follow the phone's language
    AppScope.of(context).settings.refreshSystemLanguage();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final guard = AppScope.of(context).guard;
    final settings = AppScope.of(context).settings;
    final ads = AppScope.of(context).ads;
    // really in the background only when paused / hidden; "inactive" is also the iOS
    // Notification Center or the app switcher peek, which is not leaving the app
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      guard.pausedAt ??= DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final paused = guard.pausedAt;
    guard.pausedAt = null;
    if (settings.suppressNextResume) {
      settings.suppressNextResume = false;
      return;
    }
    // back from a full-screen ad (it runs in its own screen): not a return to the app
    if (ads.fullScreenActive) return;
    if (_stage != _Stage.shell || _welcome || paused == null) return;
    if (DateTime.now().difference(paused) < const Duration(seconds: 3)) return;
    _showWelcome();
  }

  Future<void> _showWelcome() async {
    _welcome = true;
    await Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, _, _) => const WelcomeBackPage(),
      ),
    );
    _welcome = false;
    if (!mounted) return;
    await AppScope.of(context).ads.showAppOpen(wait: const Duration(seconds: 4));
  }

  void _afterSplash() {
    final settings = AppScope.of(context).settings;
    setState(() {
      if (!settings.languageChosen) {
        _stage = _Stage.language;
      } else if (!settings.onboardingDone) {
        _stage = _Stage.onboarding;
      } else {
        _stage = _Stage.shell;
      }
    });
  }

  /// Cold start: a file from another app or a home-screen shortcut skips the normal splash,
  /// the App Open ad and the language / onboarding screens (like the Android app's
  /// OpenDocumentActivity / OpenFileActivity).
  Future<void> _boot() async {
    final launch = _stage == _Stage.boot ? await PlatformBridge.takePendingIncoming() : null;
    await PlatformBridge.pullPendingAction();
    unawaited(_loadStorage());
    if (!mounted) return;
    if (launch == null) {
      if (_stage == _Stage.boot) setState(() => _stage = _Stage.splash);
      return;
    }
    await _openLaunchFile(launch);
  }

  Future<void> _loadStorage() async {
    final stats = await PlatformBridge.storage();
    if (!mounted || stats == null) return;
    AppScope.of(context).library.setStorage(stats.total, stats.free);
  }

  /// "Open with" / share: the splash for at least 1.2 s while the file is found, then the reader.
  /// A shortcut opens the reader at once. Back from the reader closes the app (Android).
  Future<void> _openLaunchFile(IncomingFile file) async {
    AppScope.of(context).settings.suppressNextResume = true;
    if (!file.shortcut) setState(() => _stage = _Stage.launchFile);
    final started = DateTime.now();
    final entry = await _resolve(file);
    if (!file.shortcut) {
      final left = const Duration(milliseconds: 1200) - DateTime.now().difference(started);
      if (left > Duration.zero) await Future<void>.delayed(left);
    }
    if (!mounted) return;
    if (entry != null) await openEntry(context, entry);
    if (!mounted) return;
    if (Platform.isAndroid) {
      // started for this file: back goes back to the app (or home screen) that opened it
      await SystemNavigator.pop();
      return;
    }
    // iOS apps cannot close themselves: carry on into the app
    _afterSplash();
  }

  /// A file that came in while the app runs (Open with / share / shortcut): the reader on top.
  Future<void> _acceptIncoming(IncomingFile file) async {
    if (_stage == _Stage.boot || _stage == _Stage.launchFile) return;
    final scope = AppScope.of(context);
    scope.settings.suppressNextResume = true;
    final entry = await _resolve(file);
    if (entry == null || !mounted) return;
    if (_stage == _Stage.shell) Navigator.of(context).popUntil((route) => route.isFirst);
    await openEntry(context, entry);
  }

  /// The library entry for an incoming file. A real file (shortcut, file:// or a content uri
  /// that maps to a readable path) is used in place; anything else (Drive, mail attachments…)
  /// is copied into Documents/AllDocumentReader/import (iOS: the app's library) — a copy with
  /// the same name and size is reused, a name without extension gets one from the MIME type.
  Future<DocEntry?> _resolve(IncomingFile file) async {
    final s = S.of(context);
    final library = AppScope.of(context).library;
    void toast(String key) {
      if (mounted) showToast(context, s.t(key));
    }

    await library.ensureReady();
    final uri = file.uri;
    if (file.shortcut || uri.startsWith('/') || uri.startsWith('file:')) {
      final path = localPath(uri);
      if (!File(path).existsSync()) {
        toast('incomingNotFound');
        return null;
      }
      return library.byPath(path) ?? await library.addFile(path, saved: false);
    }
    final info = await PlatformBridge.resolveIncoming(uri);
    final real = info?.path;
    if (real != null && File(real).existsSync()) {
      return library.byPath(real) ?? await library.addFile(real, saved: false);
    }
    var name = info?.name ?? '';
    if (name.isEmpty) name = await PlatformBridge.displayName(uri) ?? '';
    if (name.isEmpty || name == 'document') name = 'Imported_${DateTime.now().millisecondsSinceEpoch}';
    name = safeFileName(name);
    if (p.extension(name).isEmpty) {
      final ext = extensionForMime(info?.mime);
      if (ext.isNotEmpty) name = '$name.$ext';
    }
    File? temp;
    try {
      final dir = await getTemporaryDirectory();
      temp = File(p.join(dir.path, 'incoming_${DateTime.now().microsecondsSinceEpoch}'));
      await PlatformBridge.copyUri(uri, temp.path);
      final entry = await library.importPath(temp.path, name: name);
      if (entry == null) toast('incomingImportFailed');
      return entry;
    } catch (error) {
      debugPrint('incoming copy: $error');
      toast('incomingImportFailed');
      return null;
    } finally {
      try {
        if (temp != null && await temp.exists()) await temp.delete();
      } catch (_) {
        // the system cleans the temp folder
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_stage == _Stage.boot) return const _SplashLook(showProgress: false);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      child: switch (_stage) {
        _Stage.boot || _Stage.launchFile => const _SplashLook(key: ValueKey('launchFile')),
        _Stage.splash => SplashPage(key: const ValueKey('splash'), onFinished: _afterSplash),
        _Stage.language => LanguagePage(key: const ValueKey('language'), firstLaunch: true, onDone: () => setState(() => _stage = _Stage.onboarding)),
        _Stage.onboarding => OnboardingPage(key: const ValueKey('onboarding'), onDone: () => setState(() => _stage = _Stage.shell)),
        _Stage.shell => const MainShell(key: ValueKey('shell')),
      },
    );
  }
}

/// The splash screen's look without its timer and ad: while the app finds out how it was
/// started, and while an incoming file is prepared (the Android app's OpenDocumentActivity).
class _SplashLook extends StatelessWidget {
  const _SplashLook({super.key, this.showProgress = true});

  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF17191E) : Colors.white;
    if (!showProgress) return ColoredBox(color: surface, child: const SizedBox.expand());
    // the same look as the splash screen (native activity_splash.xml)
    return const SplashView(animateIn: true);
  }
}
