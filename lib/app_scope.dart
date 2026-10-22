import 'package:flutter/material.dart';

import 'core/settings/app_settings.dart';
import 'data/file_library.dart';
import 'services/ad_service.dart';
import 'services/billing_service.dart';

class ResumeGuard {
  DateTime? pausedAt;
  int _token = 0;

  void arm(AppSettings settings) {
    settings.suppressNextResume = true;
    final token = ++_token;
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (token == _token && pausedAt == null) {
        settings.suppressNextResume = false;
      }
    });
  }
}

class AppScope extends StatefulWidget {
  const AppScope({
    super.key,
    required this.settings,
    required this.library,
    required this.ads,
    required this.billing,
    required this.child,
  });

  final AppSettings settings;
  final FileLibrary library;
  final AdService ads;
  final BillingService billing;
  final Widget child;

  static AppScopeData of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScopeData>();
    assert(scope != null, 'AppScope missing');
    return scope!;
  }

  @override
  State<AppScope> createState() => _AppScopeState();
}

class _AppScopeState extends State<AppScope> {
  final guard = ResumeGuard();

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_rebuild);
    widget.library.addListener(_rebuild);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_rebuild);
    widget.library.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return AppScopeData(
      settings: widget.settings,
      library: widget.library,
      ads: widget.ads,
      billing: widget.billing,
      guard: guard,
      child: widget.child,
    );
  }
}

class AppScopeData extends InheritedWidget {
  const AppScopeData({
    super.key,
    required this.settings,
    required this.library,
    required this.ads,
    required this.billing,
    required this.guard,
    required super.child,
  });

  final AppSettings settings;
  final FileLibrary library;
  final AdService ads;
  final BillingService billing;
  final ResumeGuard guard;

  @override
  bool updateShouldNotify(AppScopeData oldWidget) => true;
}
