import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../app_scope.dart';
import '../l10n/s.dart';
import '../native/native_colors.dart';
import '../services/ad_remote_config.dart';
import '../services/ad_service.dart';
import '../services/ios_analytics.dart';
import '../services/ios_growth.dart';

class BannerSlot extends StatefulWidget {
  const BannerSlot({super.key, this.reserveSpace = false, this.unit = 1});

  /// Keeps the banner's place with "Loading ad…" until the ad arrives (Language screen); the
  /// space goes away only if no ad comes. Never shown for Premium.
  final bool reserveSpace;

  /// 1 is the home banner. 2 is the banner on reader, lists, and tool screens.
  final int unit;

  @override
  State<BannerSlot> createState() => _BannerSlotState();
}

class _BannerSlotState extends State<BannerSlot> {
  BannerAd? _ad;
  bool _ready = false;
  bool _failed = false;
  int? _width;
  int _ticket = 0;

  @override
  void initState() {
    super.initState();
    AdRemoteConfig.changes.addListener(_onRemoteConfig);
  }

  /// Remote Config `enable_ads` / `banner_ads` / `enable_test_ads` changed (AdBar.refreshPolicy).
  void _onRemoteConfig() {
    if (!mounted) return;
    final width = _width ?? MediaQuery.sizeOf(context).width.truncate();
    setState(() {
      _drop();
      _failed = false;
    });
    _load(width);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final premium = AppScope.of(context).settings.premium;
    if (premium || Platform.environment.containsKey('FLUTTER_TEST')) {
      _drop();
      return;
    }
    final width = MediaQuery.sizeOf(context).width.truncate();
    if (_ad == null || _width != width) {
      _width = width;
      _load(width);
    }
  }

  Future<void> _load(int width) async {
    final ticket = ++_ticket;
    _drop();
    final ads = AppScope.of(context).ads;
    var waited = false;
    if (!ads.ready && !ads.settings.premium) {
      // first start: the ads SDK is still starting (consent first) — load as soon as it is up,
      // instead of staying empty until something else changes
      await ads.started;
      waited = true;
      if (!mounted || ticket != _ticket || _ad != null) return;
    }
    if (!ads.canShow || !AdRemoteConfig.bannerAds) {
      // (no setState while still inside didChangeDependencies: the coming build sees it)
      _failed = true;
      if (waited && mounted && ticket == _ticket) setState(() {});
      return;
    }
    final size = await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width);
    if (!mounted || ticket != _ticket) return;
    if (size == null) {
      setState(() => _failed = true);
      return;
    }
    final ad = BannerAd(
      adUnitId: AdUnits.bannerFor(widget.unit),
      size: size,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdImpression: (_) {
          IosGrowth.adImpression(format: 'banner');
          IosAnalytics.adShown('banner');
        },
        onPaidEvent: (ad, micros, precision, currency) {
          IosGrowth.adRevenue(micros / 1000000.0, currency);
        },
        onAdLoaded: (ad) {
          if (!mounted || ticket != _ticket) return;
          setState(() {
            _ready = true;
            _failed = false;
          });
        },
        onAdFailedToLoad: (failed, error) {
          debugPrint('banner: ${error.message}');
          final current = identical(_ad, failed);
          if (current) _ad = null;
          final switched = mounted && AppScope.of(context).ads.noteLoadError(error);
          if (current) failed.dispose();
          if (!mounted || !current || ticket != _ticket || switched) return;
          setState(() {
            _ready = false;
            _failed = true;
          });
        },
      ),
    );
    _ad = ad;
    await ad.load();
  }

  void _drop() {
    _ad?.dispose();
    _ad = null;
    _ready = false;
  }

  @override
  void dispose() {
    AdRemoteConfig.changes.removeListener(_onRemoteConfig);
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    final premium = AppScope.of(context).settings.premium;
    if (!_ready || ad == null || premium) {
      if (widget.reserveSpace && !premium && !_failed && !Platform.environment.containsKey('FLUTTER_TEST')) {
        // AdBar.reserveSpace: the banner's height on the surface colour with "Loading ad…"
        // (12 sp text_secondary) in the middle
        final c = NC.of(context);
        return SizedBox(
          height: 56,
          width: double.infinity,
          child: ColoredBox(
            color: c.surface,
            child: Center(
              child: Text(S.of(context).t('adLoading'), style: TextStyle(color: c.textSecondary, fontSize: 12)),
            ),
          ),
        );
      }
      return const SizedBox.shrink();
    }
    // AdBar: full width, @color/surface, the anchored adaptive banner centred
    return ColoredBox(
      color: NC.of(context).surface,
      child: SizedBox(
        width: double.infinity,
        height: ad.size.height.toDouble(),
        child: Center(
          child: SizedBox(
            width: ad.size.width.toDouble(),
            height: ad.size.height.toDouble(),
            child: AdWidget(ad: ad),
          ),
        ),
      ),
    );
  }
}
