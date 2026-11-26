import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../services/app_analytics.dart';
import '../../widgets/chrome.dart';
import '../editor/editor_flow.dart';
import '../files/directories_page.dart';
import '../files/storage_access.dart';
import '../home/create_sheet.dart';
import '../premium/premium_page.dart';
import '../search/search_page.dart';
import '../settings/feedback_page.dart';

/// Tools tab, like the Android ToolsFragment ("Plum deck" 1.0.35+): "Tools" with crown and search
/// in round buttons; the "Scan to PDF" hero card; "Convert & Create" as a 4-column grid of
/// outlined circles (ring and glyph in the tool's type colour); "Edit & Manage" and "Others" as
/// white card lists (soft disc + glyph, label, chevron); then the "Don't have the feature you
/// want? Tell us" card. Everything rises / pops in once. On Android every tool except Recycle bin
/// needs file access first; iOS needs none (ensureAccess / needsAccessGate).
class ToolsTab extends StatefulWidget {
  const ToolsTab({super.key});

  @override
  State<ToolsTab> createState() => _ToolsTabState();
}

class _ToolsTabState extends State<ToolsTab> with SingleTickerProviderStateMixin {
  /// Entrance: hero fans in, circles pop (80 ms + 40 ms each), rows rise (160 ms + 40 ms each).
  late final AnimationController _enter = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..forward();

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  /// 0..1 progress of an item that starts after [delayMs] and lasts [ms].
  Animation<double> _part(int delayMs, int ms, Curve curve) {
    const total = 1100.0;
    final start = (delayMs / total).clamp(0.0, 1.0);
    final end = ((delayMs + ms) / total).clamp(start, 1.0);
    return CurvedAnimation(parent: _enter, curve: Interval(start, end, curve: curve));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    // native ToolsFragment.sections(): same order, ds_tools_ic_* glyphs, analytics names
    final hero = _Tool(ND.dsToolsIcScan, s.t('scanToPdf'), 'scan_to_pdf', () => pickImages(context, camera: true));
    final convert = [
      _Tool(ND.dsToolsIcImage2pdf, s.t('imageToPdf'), 'image_to_pdf', () => pickImages(context, camera: false), color: nc.typeImage),
      _Tool(ND.dsToolsIcWord2pdf, s.t('wordToPdf'), 'word_to_pdf', () => convertOffice(context, slides: false), color: nc.typeWord),
      _Tool(ND.dsToolsIcPdf2word, s.t('pdfToWord'), 'pdf_to_word', () => convertPdfToWord(context), color: nc.typePdf),
      _Tool(ND.dsToolsIcPpt2pdf, s.t('pptToPdf'), 'ppt_to_pdf', () => convertOffice(context, slides: true), color: nc.typePpt),
      _Tool(ND.dsToolsIcTemplates, s.t('templates'), 'tool_templates', () => openTemplates(context), color: nc.typeTxt),
      _Tool(ND.dsToolsIcCreatePdf, s.t('createPdf'), 'create_pdf', () => createBlankPdf(context), color: nc.typeExcel),
    ];
    final lists = <(String, List<_Tool>)>[
      (
        s.t('editManage'),
        [
          _Tool(ND.dsToolsIcEditText, s.t('editText'), 'edit_text', () => openMarkup(context, tool: MarkTool.editText)),
          _Tool(ND.dsToolsIcAnnotate, s.t('annotate'), 'annotate', () => openMarkup(context, tool: MarkTool.pen)),
          _Tool(ND.dsToolsIcAddText, s.t('addText'), 'add_text', () => openMarkup(context, tool: MarkTool.text)),
          _Tool(ND.dsToolsIcSign, s.t('sign'), 'sign', () => openMarkup(context, tool: MarkTool.sign)),
          _Tool(ND.dsToolsIcManagePages, s.t('managePages'), 'manage_pages', () => openManagePages(context)),
          _Tool(ND.dsToolsIcMerge, s.t('mergePdf'), 'tool_merge_pdf', () => openMerge(context)),
          _Tool(ND.dsToolsIcSplit, s.t('splitPdf'), 'tool_split_pdf', () => openSplit(context)),
        ],
      ),
      (
        s.t('others'),
        [
          _Tool(ND.dsToolsIcImport, s.t('importFiles'), 'import_files', () => importFiles(context)),
          _Tool(
            ND.dsToolsIcRecycleBin,
            s.t('recycleBin'),
            'recycle_bin',
            () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const DirectoriesPage(binOnly: true))),
            needsAccess: false,
          ),
          _Tool(ND.dsToolsIcPrint, s.t('printPdf'), 'print_pdf', () => printPdf(context)),
        ],
      ),
    ];

    Future<void> run(_Tool tool) async {
      logEvent('tool_tap', {'tool': tool.key, 'screen': 'tools'});
      logEvent(_eventOf(tool.key));
      if (tool.needsAccess && !await ensureAccess(context)) return;
      if (!context.mounted) return;
      await tool.onTap();
    }

    Widget pop(Widget child, int index) {
      if (still) return child;
      final a = _part(80 + 40 * index, 280, Curves.easeOutBack);
      return FadeTransition(
        opacity: _part(80 + 40 * index, 180, Curves.linear),
        child: ScaleTransition(scale: Tween<double>(begin: 0.8, end: 1).animate(a), child: child),
      );
    }

    Widget rise(Widget child, int index) {
      if (still) return child;
      final a = _part(160 + 40 * index, 300, Curves.easeOutCubic);
      return FadeTransition(
        opacity: a,
        child: AnimatedBuilder(
          animation: a,
          builder: (context, child) => Transform.translate(offset: Offset(0, (1 - a.value) * 16), child: child),
          child: child,
        ),
      );
    }

    // item_result_tool.xml: 52 dp frame with a 46 dp ring (surface, 2 dp stroke in the tool's
    // colour) and a 22 dp glyph in that colour; 12 sp label 6 dp below; 10 dp top / bottom
    Widget cell(_Tool tool, int index) {
      final color = tool.color ?? nc.primary;
      return Semantics(
        button: true,
        label: tool.label,
        excludeSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: () => run(tool),
            borderRadius: BorderRadius.circular(16),
            splashColor: nc.rowPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                children: [
                  pop(
                    SizedBox(
                      width: 52,
                      height: 52,
                      child: Center(
                        child: Container(
                          width: 46,
                          height: 46,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: nc.surface, shape: BoxShape.circle, border: Border.all(color: color, width: 2)),
                          child: NativeIcon(tool.icon, size: 22, tint: color),
                        ),
                      ),
                    ),
                    index,
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      tool.label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: nc.textPrimary, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    Widget grid(List<_Tool> tools) {
      final rows = <Widget>[];
      for (var start = 0; start < tools.length; start += 4) {
        rows.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = start; i < start + 4; i++)
                Expanded(child: i >= tools.length ? const SizedBox.shrink() : cell(tools[i], i)),
            ],
          ),
        );
      }
      return Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Column(children: rows));
    }

    var rowIndex = 0;
    // item_tool.xml rows inside a ds_tools_bg_card (surface, 16 dp corners, 4 dp top / bottom)
    // with 1 dp dividers inset past the icon
    Widget list(List<_Tool> tools) {
      final children = <Widget>[];
      for (var i = 0; i < tools.length; i++) {
        final tool = tools[i];
        if (i > 0) {
          children.add(
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 64, end: 14),
              child: Container(height: 1, color: nc.divider),
            ),
          );
        }
        children.add(
          Semantics(
            button: true,
            label: tool.label,
            excludeSemantics: true,
            child: InkWell(
              onTap: () => run(tool),
              splashColor: nc.rowPressed,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 58),
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 14, end: 10),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: nc.accentContainer, shape: BoxShape.circle),
                        child: NativeIcon(tool.icon, size: 20, tint: nc.dsToolsRowIcon),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          tool.label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15, color: nc.textPrimary),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _Chevron(color: nc.navbarOff),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }
      final card = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Material(
          color: nc.surface,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Column(children: children)),
        ),
      );
      return rise(card, rowIndex++);
    }

    Widget section(String title) => Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 22, 20, 6),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: nc.textSecondary)),
          ),
        );

    final heroCard = _HeroCard(
      title: hero.label,
      subtitle: s.t('dsScanHeroSub'),
      icon: hero.icon,
      onTap: () => run(hero),
    );

    return ColoredBox(
      color: nc.bgScreen,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            SizedBox(
              height: 64,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: 20, end: 12),
                child: Row(
                  children: [
                    Expanded(child: Text(s.t('tools'), maxLines: 1, overflow: TextOverflow.ellipsis, style: dsScreenTitle(context))),
                    DsTopAction(
                      icon: ND.icCrown,
                      keepColors: true,
                      iconPadding: 13,
                      tooltip: s.t('getPremium'),
                      onTap: () {
                        logEvent('tools_premium_tapped');
                        Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const PremiumPage()));
                      },
                    ),
                    DsTopAction(
                      icon: ND.icSearch,
                      tint: nc.iconMain,
                      iconPadding: 13,
                      tooltip: s.t('searchHint'),
                      onTap: () {
                        logEvent('tools_search_tapped');
                        openSearchPage(context);
                      },
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: kNavBarClearance),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: still
                        ? heroCard
                        : FadeTransition(
                            opacity: _part(0, 360, Curves.easeOut),
                            child: SlideTransition(
                              position: Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero)
                                  .animate(_part(0, 420, Curves.easeOutCubic)),
                              child: heroCard,
                            ),
                          ),
                  ),
                  section(s.t('convertCreate')),
                  grid(convert),
                  for (final (title, tools) in lists) ...[
                    section(title),
                    list(tools),
                  ],
                  const SizedBox(height: 4),
                  // cardFeedback: accent_container card (16 dp corners), at least 60 dp, a 36 dp
                  // accent_soft disc with ds_tools_ic_feedback, the question and "Tell us ›"
                  rise(
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                      child: Material(
                        color: nc.accentContainer,
                        borderRadius: BorderRadius.circular(16),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          splashColor: nc.rowPressed,
                          onTap: () {
                            logEvent('feedback_open', {'screen': 'tools'});
                            logEvent('tools_feedback_tapped');
                            Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const FeedbackPage()));
                          },
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 60),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              child: Row(
                                children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(color: nc.accentSoft, shape: BoxShape.circle),
                                    child: NativeIcon(ND.dsToolsIcFeedback, size: 20, tint: nc.navbarPillText),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      s.t('featureRequest'),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 14, color: nc.textPrimary),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(s.t('dsTellUs'), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: nc.primary)),
                                  const SizedBox(width: 2),
                                  _Chevron(color: nc.primary),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    rowIndex,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Android tool name → its "tools_…_tapped" event (ToolsFragment.openTool).
String _eventOf(String tool) => switch (tool) {
      'word_to_pdf' => 'tools_word_pdf_tapped',
      'tool_templates' => 'tools_templates_tapped',
      'tool_merge_pdf' => 'tools_merge_pdf_tapped',
      'tool_split_pdf' => 'tools_split_pdf_tapped',
      _ => 'tools_${tool}_tapped',
    };

/// ds_tools_ic_chevron (20 dp), pointing forward in both directions.
class _Chevron extends StatelessWidget {
  const _Chevron({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final icon = NativeIcon(ND.dsToolsIcChevron, size: 20, tint: color);
    return rtl ? Transform.flip(flipX: true, child: icon) : icon;
  }
}

/// cardHero: the ds_tools_hero card (20 dp corners, two soft ds_tools_hero_ring circles), at least
/// 96 dp; title 18 sp medium, subtitle 13 sp, and a 56 dp accent_soft disc with the scan glyph.
class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.title, required this.subtitle, required this.icon, required this.onTap});

  final String title;
  final String subtitle;
  final NDrawable icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nc = NC.of(context);
    return Semantics(
      button: true,
      label: title,
      excludeSemantics: true,
      child: Material(
        color: nc.dsToolsHero,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          splashColor: const Color(0x33FFFFFF),
          child: Stack(
            children: [
              PositionedDirectional(
                top: -50,
                end: -40,
                child: Container(width: 150, height: 150, decoration: BoxDecoration(color: nc.dsToolsHeroRing, shape: BoxShape.circle)),
              ),
              PositionedDirectional(
                bottom: -24,
                end: 70,
                child: Container(width: 70, height: 70, decoration: BoxDecoration(color: nc.dsToolsHeroRing, shape: BoxShape.circle)),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 96),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(20, 18, 16, 18),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: nc.dsToolsHeroText)),
                            const SizedBox(height: 2),
                            Text(subtitle, style: TextStyle(fontSize: 13, color: nc.dsToolsHeroSub)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        width: 56,
                        height: 56,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: nc.accentSoft, shape: BoxShape.circle),
                        child: NativeIcon(icon, size: 28, tint: nc.navbarPillText),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tool {
  const _Tool(this.icon, this.label, this.key, this.onTap, {this.needsAccess = true, this.color});
  final NDrawable icon;
  final String label;

  /// The Android string name of the tool (analytics).
  final String key;
  final Future<void> Function() onTap;
  final bool needsAccess;

  /// Ring / glyph colour of a grid circle.
  final Color? color;
}
