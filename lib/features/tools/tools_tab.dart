import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../native/native_shapes.dart';
import '../editor/editor_flow.dart';
import '../files/directories_page.dart';
import '../files/storage_access.dart';
import '../home/create_sheet.dart';
import '../premium/premium_page.dart';
import '../search/search_page.dart';
import '../settings/feedback_page.dart';

/// Tools tab, like the Android ToolsFragment: app name with crown and search, then "Convert &
/// Create", "Edit & Manage" and "Others" as 4-column icon grids, and "Don't have the feature you
/// want? Tell us". Every tool except Recycle bin needs file access first.
class ToolsTab extends StatelessWidget {
  const ToolsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final settings = AppScope.of(context).settings;

    // native ToolsFragment: same order and the same ic_cv_* / ic_rt_* / ic_create_* drawables
    final sections = <(String, List<_Tool>)>[
      (
        s.t('convertCreate'),
        [
          _Tool(ND.icCvImage2pdf, s.t('imageToPdf'), () => pickImages(context, camera: false)),
          _Tool(ND.icCvScan, s.t('scanToPdf'), () => pickImages(context, camera: true)),
          _Tool(ND.icCvWord2pdf, s.t('wordToPdf'), () => convertOffice(context, slides: false)),
          _Tool(ND.icCvPdf2word, s.t('pdfToWord'), () => convertPdfToWord(context)),
          _Tool(ND.icCvPpt2pdf, s.t('pptToPdf'), () => convertOffice(context, slides: true)),
          _Tool(ND.icCreateTemplates, s.t('templates'), () => openTemplates(context)),
          _Tool(ND.icCreatePdfBadge, s.t('createPdf'), () => createBlankPdf(context)),
        ],
      ),
      (
        s.t('editManage'),
        [
          _Tool(ND.icRtEditText, s.t('editText'), () => openMarkup(context, tool: MarkTool.editText)),
          _Tool(ND.icRtAnnotate, s.t('annotate'), () => openMarkup(context, tool: MarkTool.pen)),
          _Tool(ND.icRtAddText, s.t('addText'), () => openMarkup(context, tool: MarkTool.text)),
          _Tool(ND.icRtSign, s.t('sign'), () => openMarkup(context, tool: MarkTool.sign)),
          _Tool(ND.icRtManagePages, s.t('managePages'), () => openManagePages(context)),
          _Tool(ND.icRtMerge, s.t('mergePdf'), () => openMerge(context)),
          _Tool(ND.icRtSplit, s.t('splitPdf'), () => openSplit(context)),
        ],
      ),
      (
        s.t('others'),
        [
          _Tool(ND.icCreateImport, s.t('importFiles'), () => importFiles(context)),
          _Tool(
            ND.icRtRecycleBin,
            s.t('recycleBin'),
            () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const DirectoriesPage(binOnly: true))),
            needsAccess: false,
          ),
          _Tool(ND.icRtPrint, s.t('printPdf'), () => printPdf(context)),
        ],
      ),
    ];

    Future<void> run(_Tool tool) async {
      if (tool.needsAccess && !await ensureAccess(context)) return;
      if (!context.mounted) return;
      await tool.onTap();
    }

    // item_result_tool.xml: borderless ripple, 10dp top/bottom, 52dp bg_tool_tile with a 30dp icon,
    // 8dp gap, label 13sp text_primary (max 2 lines)
    Widget cell(_Tool tool) {
      return Material(
        type: MaterialType.transparency,
        child: InkResponse(
          onTap: () => run(tool),
          containedInkWell: false,
          highlightShape: BoxShape.circle,
          radius: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: NS.bgToolTile(context),
                  child: NativeIcon(tool.icon, size: 30),
                ),
                const SizedBox(height: 8),
                Text(
                  tool.label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: nc.textPrimary),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // item_tools_section.xml: GridLayout with 4 equal columns, 4dp side margins
    Widget grid(List<_Tool> tools) {
      final rows = <Widget>[];
      for (var start = 0; start < tools.length; start += 4) {
        rows.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = start; i < start + 4; i++)
                Expanded(child: i >= tools.length ? const SizedBox.shrink() : cell(tools[i])),
            ],
          ),
        );
      }
      return Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Column(children: rows));
    }

    return ColoredBox(
      color: nc.surface,
      child: Column(
        children: [
          // status bar area in @color/bg_header_top (MainActivity sets it), then the 56dp bg_home_header
          ColoredBox(color: nc.bgHeaderTop, child: SizedBox(width: double.infinity, height: MediaQuery.paddingOf(context).top)),
          Container(
            height: 56,
            decoration: NS.bgHomeHeader(context),
            padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'All Document Reader',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: nc.textPrimary),
                  ),
                ),
                // the crown is for buying Premium: hidden once Premium is on
                if (!settings.premium)
                  _HeaderButton(
                    onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const PremiumPage())),
                    child: const NativeIcon(ND.icCrown, size: 24),
                  ),
                _HeaderButton(
                  tooltip: s.t('searchHint'),
                  onTap: () => openSearchPage(context),
                  child: NativeIcon(ND.icSearch, size: 24, tint: nc.textPrimary),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                for (final (title, tools) in sections) ...[
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 16, top: 12),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: nc.toolsSection)),
                    ),
                  ),
                  grid(tools),
                ],
                // cardFeedback: 52dp bg_feedback_card, 12dp margins, ic_feedback_note 28dp
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
                  child: Material(
                    color: nc.surfaceVariant,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      splashColor: const Color(0x1F000000),
                      highlightColor: const Color(0x1F000000),
                      onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const FeedbackPage())),
                      child: SizedBox(
                        height: 52,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              const NativeIcon(ND.icFeedbackNote, size: 28),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  s.t('featureRequest'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 14, color: nc.textPrimary),
                                ),
                              ),
                              Text(
                                s.t('tellUsShort'),
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: nc.primary),
                              ),
                              const SizedBox(width: 2),
                              NativeIcon(ND.icChevronRight, size: 24, tint: nc.primary),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 44dp ImageButton with 10dp padding and a borderless ripple (fragment_tools.xml btnPremium / btnSearch).
class _HeaderButton extends StatelessWidget {
  const _HeaderButton({this.tooltip, required this.onTap, required this.child});

  final String? tooltip;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      type: MaterialType.transparency,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: SizedBox(width: 44, height: 44, child: Center(child: child)),
      ),
    );
    final message = tooltip;
    return message == null ? button : Tooltip(message: message, child: button);
  }
}

class _Tool {
  const _Tool(this.icon, this.label, this.onTap, {this.needsAccess = true});
  final NDrawable icon;
  final String label;
  final Future<void> Function() onTap;
  final bool needsAccess;
}
