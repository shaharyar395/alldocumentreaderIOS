import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../app_scope.dart';
import '../l10n/s.dart';
import '../native/native_colors.dart';
import '../native/native_drawables.dart';
import '../native/native_icon.dart';
import 'chrome.dart';

/// "Thank you for your support!" (Settings → Explore more apps, and sometimes when leaving the
/// app with Back), like the Android app: rows of Google native ads, 3 per page, a pager that turns
/// by itself every 3.5 s and page dots. A spinner shows while the ads load; nothing for Premium.
Future<void> showExploreSheet(BuildContext context) async {
  final ads = AppScope.of(context).ads;
  await showAppSheet<void>(context, builder: (_) => const _ExploreSheet());
  // each native ad is shown once; fresh ones load for the next time (after the sheet's closing
  // animation, while its ad views are still on screen)
  unawaited(Future<void>.delayed(const Duration(milliseconds: 700), ads.releaseNativeAds));
}

/// Back on the home screen: show the sheet before the app closes? Every 3rd time the user leaves
/// with Back, when native ads are ready (never for Premium) — like ExploreAppsSheet.shouldShowOnExit.
Future<bool> shouldShowExploreOnExit(BuildContext context) async {
  final scope = AppScope.of(context);
  if (scope.settings.premium || !scope.ads.hasNativeAds) return false;
  final count = await scope.settings.countExit();
  return count % 3 == 0;
}

class _ExploreSheet extends StatefulWidget {
  const _ExploreSheet();

  @override
  State<_ExploreSheet> createState() => _ExploreSheetState();
}

class _ExploreSheetState extends State<_ExploreSheet> {
  static const _perPage = 3;
  static const _rowHeight = 96.0;

  final _pager = PageController();
  List<NativeAd>? _ads;
  int _page = 0;
  Timer? _turn;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  Future<void> _load() async {
    final ads = AppScope.of(context).ads;
    final list = await ads.waitNativeAds();
    if (!mounted) return;
    setState(() => _ads = list);
    final pages = (list.length / _perPage).ceil();
    if (pages > 1) {
      _turn = Timer.periodic(const Duration(milliseconds: 3500), (_) {
        if (!mounted || !_pager.hasClients) return;
        final next = (_page + 1) % pages;
        _pager.animateToPage(next, duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
      });
    }
  }

  @override
  void dispose() {
    _turn?.cancel();
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final ads = _ads;
    final pages = <List<NativeAd>>[];
    if (ads != null) {
      for (var i = 0; i < ads.length; i += _perPage) {
        pages.add(ads.sublist(i, i + _perPage > ads.length ? ads.length : i + _perPage));
      }
    }
    // sheet_explore_apps.xml
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NativeIcon(ND.icGiftBox, size: 72),
              const SizedBox(height: 8),
              Text(s.t('thanksSupport'), textAlign: TextAlign.center, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: c.textPrimary)),
              const SizedBox(height: 4),
              Text(s.t('dontMissApps'), textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: c.textSecondary)),
              const SizedBox(height: 16),
              SizedBox(
                height: _perPage * (_rowHeight + 8),
                child: ads == null
                    ? Center(child: SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3, color: c.primary)))
                    : pages.isEmpty
                        ? Center(
                            child: Text(s.t('exploreNothing'), textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: c.textSecondary)),
                          )
                        : PageView.builder(
                            controller: _pager,
                            itemCount: pages.length,
                            onPageChanged: (value) => setState(() => _page = value),
                            itemBuilder: (context, index) => _AdPage(ads: pages[index], rowHeight: _rowHeight),
                          ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 10,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (pages.length > 1)
                      for (var i = 0; i < pages.length; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: i == _page ? 14 : 6,
                          height: 6,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            color: i == _page ? c.primary : c.dotOff,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                  ],
                ),
              ),
            ],
          ),
        ),
        PositionedDirectional(
          top: 6,
          end: 6,
          child: SizedBox(
            width: 40,
            height: 40,
            child: IconButton(
              padding: const EdgeInsets.all(11),
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
              tooltip: s.t('cancel'),
              onPressed: () => Navigator.pop(context),
              icon: NativeIcon(ND.icClose, size: 18, tint: c.textHint),
            ),
          ),
        ),
      ],
    );
  }
}

/// One page of ad rows; kept alive so the ads are not rebuilt while the pager turns.
class _AdPage extends StatefulWidget {
  const _AdPage({required this.ads, required this.rowHeight});

  final List<NativeAd> ads;
  final double rowHeight;

  @override
  State<_AdPage> createState() => _AdPageState();
}

class _AdPageState extends State<_AdPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        for (final ad in widget.ads)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SizedBox(
              height: widget.rowHeight,
              width: double.infinity,
              child: AdWidget(ad: ad),
            ),
          ),
      ],
    );
  }
}
