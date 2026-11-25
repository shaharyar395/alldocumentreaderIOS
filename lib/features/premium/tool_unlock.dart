import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_scope.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../services/ios_analytics.dart';
import '../../widgets/chrome.dart';
import 'premium_page.dart';

/// Merge, split, scan, create PDF, and crowned templates.
/// Premium opens the tool. Otherwise one rewarded ad unlocks that tool until local midnight.
enum UnlockTool {
  merge('merge'),
  split('split'),
  scan('scan'),
  createPdf('create_pdf'),
  templates('templates');

  const UnlockTool(this.key);
  final String key;

  NDrawable get icon => switch (this) {
        UnlockTool.merge => ND.dsToolsIcMerge,
        UnlockTool.split => ND.dsToolsIcSplit,
        UnlockTool.scan => ND.dsToolsIcScan,
        UnlockTool.createPdf => ND.dsToolsIcCreatePdf,
        UnlockTool.templates => ND.dsToolsIcTemplates,
      };

  String title(S s) => switch (this) {
        UnlockTool.merge => s.t('unlockMergeTitle'),
        UnlockTool.split => s.t('unlockSplitTitle'),
        UnlockTool.scan => s.t('unlockScanTitle'),
        UnlockTool.createPdf => s.t('unlockCreateTitle'),
        UnlockTool.templates => s.t('unlockTemplateTitle'),
      };

  String body(S s) => switch (this) {
        UnlockTool.merge => s.t('unlockMergeBody'),
        UnlockTool.split => s.t('unlockSplitBody'),
        UnlockTool.scan => s.t('unlockScanBody'),
        UnlockTool.createPdf => s.t('unlockCreateBody'),
        UnlockTool.templates => s.t('unlockTemplateBody'),
      };

  List<String> benefits(S s) => switch (this) {
        UnlockTool.merge => [s.t('unlockMergeB1'), s.t('unlockMergeB2'), s.t('unlockMergeB3')],
        UnlockTool.split => [s.t('unlockSplitB1'), s.t('unlockSplitB2'), s.t('unlockSplitB3')],
        UnlockTool.scan => [s.t('unlockScanB1'), s.t('unlockScanB2'), s.t('unlockScanB3')],
        UnlockTool.createPdf => [s.t('unlockCreateB1'), s.t('unlockCreateB2'), s.t('unlockCreateB3')],
        UnlockTool.templates => [s.t('unlockTemplateB1'), s.t('unlockTemplateB2'), s.t('unlockTemplateB3')],
      };
}

const _crownedTemplates = {
  'resume_dark',
  'resume_blue',
  'letter_fax',
  'letter_proposal',
  'briefing_weekly',
  'poster_webinar',
  'poster_poster_bf',
  'poster_christmas',
};

bool isCrownedTemplate(String id) => _crownedTemplates.contains(id);

/// True when Premium or this tool's rewarded unlock is still inside the local day.
Future<bool> toolUnlocked(UnlockTool tool, {required bool premium}) async {
  if (premium) return true;
  final prefs = await SharedPreferences.getInstance();
  final until = prefs.getInt('tool_unlock_${tool.key}') ?? 0;
  return until > DateTime.now().millisecondsSinceEpoch;
}

Future<void> _grant(UnlockTool tool) async {
  final now = DateTime.now();
  final midnight = DateTime(now.year, now.month, now.day + 1);
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt('tool_unlock_${tool.key}', midnight.millisecondsSinceEpoch);
}

/// Runs [action] now when the tool is open, or after the sheet unlocks it.
Future<void> runUnlocked(BuildContext context, UnlockTool tool, Future<void> Function() action) async {
  final premium = AppScope.of(context).settings.premium;
  if (await toolUnlocked(tool, premium: premium)) {
    if (context.mounted) await action();
    return;
  }
  if (!context.mounted) return;
  final opened = await showToolUnlockSheet(context, tool);
  if (opened && context.mounted) await action();
}

Future<bool> showToolUnlockSheet(BuildContext context, UnlockTool tool) {
  final nc = NC.of(context);
  IosAnalytics.log('unlock_sheet_shown', {'tool': tool.key});
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    enableDrag: false,
    backgroundColor: nc.surface,
    builder: (_) => _UnlockSheet(tool: tool),
  ).then((opened) => opened ?? false);
}

class _UnlockSheet extends StatefulWidget {
  const _UnlockSheet({required this.tool});

  final UnlockTool tool;

  @override
  State<_UnlockSheet> createState() => _UnlockSheetState();
}

class _UnlockSheetState extends State<_UnlockSheet> {
  var _watching = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppScope.of(context).ads.preloadRewarded();
    });
  }

  Future<void> _watch() async {
    if (_watching) return;
    setState(() => _watching = true);
    IosAnalytics.log('unlock_watch_tapped', {'tool': widget.tool.key});
    final earned = await AppScope.of(context).ads.showRewarded();
    if (!mounted) return;
    if (!earned) {
      setState(() => _watching = false);
      showToast(context, S.of(context).t('unlockAdUnavailable'));
      return;
    }
    await _grant(widget.tool);
    IosAnalytics.log('unlock_rewarded', {'tool': widget.tool.key});
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  void _premium() {
    IosAnalytics.log('unlock_premium_tapped', {'tool': widget.tool.key});
    final navigator = Navigator.of(context);
    navigator.pop(false);
    navigator.push(MaterialPageRoute(builder: (_) => const PremiumPage()));
  }

  void _notNow() {
    IosAnalytics.log('unlock_not_now', {'tool': widget.tool.key});
    Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    final tool = widget.tool;
    return Padding(
      padding: EdgeInsets.fromLTRB(22, 10, 22, 22 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            margin: const EdgeInsets.only(top: 22),
            decoration: BoxDecoration(color: nc.primary, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: NativeIcon(tool.icon, size: 28, tint: nc.onPrimary),
          ),
          const SizedBox(height: 18),
          Text(tool.title(s), textAlign: TextAlign.center, style: TextStyle(color: nc.textPrimary, fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(tool.body(s), textAlign: TextAlign.center, style: TextStyle(color: nc.textSecondary, fontSize: 14, height: 1.3)),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: nc.primaryLight, borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                for (var i = 0; i < tool.benefits(s).length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.check_rounded, size: 18, color: nc.primary),
                      const SizedBox(width: 10),
                      Expanded(child: Text(tool.benefits(s)[i], style: TextStyle(color: nc.textPrimary, fontSize: 14))),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: nc.primary, foregroundColor: nc.onPrimary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              onPressed: _watching ? null : _watch,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  NativeIcon(ND.icPlayTriangle, size: 18, tint: nc.onPrimary),
                  const SizedBox(width: 8),
                  Text(s.t('unlockWatch'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: nc.textPrimary,
                side: BorderSide(color: nc.crown, width: 1.5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _premium,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  NativeIcon(ND.icCrown, size: 18, tint: nc.crown),
                  const SizedBox(width: 8),
                  Flexible(child: Text(s.t('unlockPremiumBtn'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _notNow,
            child: Text(s.t('unlockNotNow'), style: TextStyle(color: nc.primary, fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
