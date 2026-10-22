import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_scope.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../widgets/chrome.dart';
import '../premium/premium_page.dart';
import '../settings/feedback_page.dart';
import 'template_editor_page.dart';
import 'template_model.dart';
import 'template_painter.dart';
import 'tool_widgets.dart';

const _freeTriesPerDay = 2;

String tplCategoryLabel(S s, TplCategory category) {
  return switch (category) {
    TplCategory.resume => s.t('resume'),
    TplCategory.letter => s.t('letter'),
    TplCategory.briefing => s.t('briefing'),
    TplCategory.poster => s.t('poster'),
  };
}

int _today() {
  final now = DateTime.now();
  final start = DateTime(now.year);
  return now.year * 1000 + now.difference(start).inDays + 1;
}

/// Crowned templates: Premium, or one of today's free tries. Says how many tries are left;
/// opens Get Premium when none are.
Future<bool> useTemplateTry(BuildContext context, Template template) async {
  final scope = AppScope.of(context);
  if (!template.premium || scope.settings.premium) return true;
  final s = S.of(context);
  final prefs = await SharedPreferences.getInstance();
  final day = prefs.getInt('gate_templates_day') ?? 0;
  final used = day == _today() ? (prefs.getInt('gate_templates_used') ?? 0) : 0;
  final left = _freeTriesPerDay - used;
  if (!context.mounted) return false;
  if (left <= 0) {
    final rewarded = await scope.ads.showRewarded();
    if (!context.mounted) return false;
    if (rewarded) return true;
    showToast(context, s.t('premiumLimitReached', {'feature': s.t('templates')}));
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PremiumPage()));
    return false;
  }
  await prefs.setInt('gate_templates_day', _today());
  await prefs.setInt('gate_templates_used', used + 1);
  if (!context.mounted) return false;
  final now = left - 1;
  showToast(context, now > 0 ? s.t('premiumFreeUsesLeft', {'count': '$now'}) : s.t('premiumLastFreeUse'));
  return true;
}

/// Opens [id] in the template editor (Create → resume: 'resume_classic').
Future<void> openTemplateEditor(BuildContext context, String id) async {
  final template = templateById(id);
  if (template == null) return;
  if (!await useTemplateTry(context, template) || !context.mounted) return;
  final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => TemplateEditorPage(template: template)));
  if (saved == true && context.mounted) showToast(context, S.of(context).t('savedSuccessfully'));
}

/// The resume template, ready to edit.
Future<void> openResumeTemplate(BuildContext context) => openTemplateEditor(context, 'resume_classic');

/// "Select a template": tabs Resume / Letter / Briefing / Poster above one list of sections (the
/// tab follows the scrolling, tapping a tab jumps to its section), real page thumbnails with a
/// crown on Premium ones, and "Need more templates? Tell us" at the end.
class TemplatesPage extends StatefulWidget {
  const TemplatesPage({super.key});

  @override
  State<TemplatesPage> createState() => _TemplatesPageState();
}

class _TemplatesPageState extends State<TemplatesPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: TplCategory.values.length, vsync: this);
  final ScrollController _scroll = ScrollController();
  final Map<TplCategory, GlobalKey> _headers = {for (final category in TplCategory.values) category: GlobalKey()};
  final GlobalKey _viewport = GlobalKey();
  static final Map<String, ui.Image> _thumbs = {};
  bool _jumping = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_syncTab);
    _drawThumbs();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _drawThumbs() async {
    for (final template in tplLibrary) {
      if (_thumbs.containsKey(template.id)) continue;
      final image = await TplRenderer.render(template.build(), 300);
      if (!mounted) {
        _thumbs[template.id] = image;
        return;
      }
      setState(() => _thumbs[template.id] = image);
    }
  }

  void _syncTab() {
    if (_jumping) return;
    final viewport = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.hasSize) return;
    final top = viewport.localToGlobal(Offset.zero).dy;
    var current = TplCategory.values.first;
    if (_scroll.hasClients && _scroll.position.pixels >= _scroll.position.maxScrollExtent - 2) {
      current = TplCategory.values.last;
    } else {
      for (final category in TplCategory.values) {
        final box = _headers[category]?.currentContext?.findRenderObject() as RenderBox?;
        if (box == null || !box.attached) continue;
        if (box.localToGlobal(Offset.zero).dy <= top + 24) current = category;
      }
    }
    if (_tabs.index != current.index) _tabs.animateTo(current.index);
  }

  Future<void> _jumpTo(TplCategory category) async {
    final target = _headers[category]?.currentContext;
    if (target == null) return;
    _jumping = true;
    await Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    _jumping = false;
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final premium = AppScope.of(context).settings.premium;
    // two columns in an 8dp-padded list; each cell is the 595:842 page plus 6dp all round
    final cell = (MediaQuery.sizeOf(context).width - 16) / 2;
    final cellHeight = (cell - 12) * 842 / 595 + 12;
    return Scaffold(
      backgroundColor: nc.surface,
      appBar: NativeTopBar(title: s.t('selectTemplate')),
      body: Column(
        children: [
          // TabLayout: 44dp, scrollable from the start, 15sp bold, primary / text_secondary,
          // 24 x 3dp primary indicator, no ripple
          Container(
            height: 44,
            color: nc.surface,
            child: TabBar(
              controller: _tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              padding: EdgeInsets.zero,
              labelPadding: const EdgeInsets.symmetric(horizontal: 14),
              dividerColor: Colors.transparent,
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              splashFactory: NoSplash.splashFactory,
              labelColor: nc.primary,
              unselectedLabelColor: nc.textSecondary,
              labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              unselectedLabelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              indicator: _TabIndicator(nc.primary),
              onTap: (index) => _jumpTo(TplCategory.values[index]),
              tabs: [for (final category in TplCategory.values) Tab(height: 44, text: tplCategoryLabel(s, category))],
            ),
          ),
          Expanded(
            child: ColoredBox(
              color: nc.surfaceVariant,
              child: CustomScrollView(
                key: _viewport,
                controller: _scroll,
                slivers: [
                  for (final category in TplCategory.values) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        key: _headers[category],
                        padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 8, 10),
                        child: Text(tplCategoryLabel(s, category), style: TextStyle(fontSize: 15, color: nc.textSecondary)),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisExtent: cellHeight),
                        delegate: SliverChildListDelegate([
                          for (final template in tplLibrary.where((t) => t.category == category)) _tile(nc, template, premium),
                        ]),
                      ),
                    ),
                  ],
                  // item_tpl_more.xml: 64dp bg_tpl_more card, "Need more templates?", ic_tpl_chat, "Tell us"
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
                      child: Material(
                        color: nc.surface,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          splashColor: const Color(0x1F000000),
                          highlightColor: const Color(0x1F000000),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FeedbackPage())),
                          child: Container(
                            height: 64,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                Expanded(child: Text(s.t('tplNeedMore'), style: TextStyle(fontSize: 15, color: nc.textPrimary))),
                                const NativeIcon(ND.icTplChat, size: 20),
                                const SizedBox(width: 4),
                                Text(s.t('tellUsShort'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: nc.primary)),
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
          ),
        ],
      ),
    );
  }

  /// item_tpl_thumb.xml: 6dp padding, white MaterialCardView (2dp corners, elevation 1), the page
  /// at 595:842 on @color/skeleton, crown badge (26dp bg_crown_badge) for Premium templates.
  Widget _tile(NC nc, Template template, bool premium) {
    final thumb = _thumbs[template.id];
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Align(
        alignment: Alignment.topCenter,
        child: AspectRatio(
          aspectRatio: 595 / 842,
          child: Material(
            color: Colors.white,
            elevation: 1,
            borderRadius: BorderRadius.circular(2),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () async {
                await openTemplateEditor(context, template.id);
                if (mounted) setState(() {});
              },
              child: Stack(
                children: [
                  Positioned.fill(
                    child: thumb == null
                        ? ColoredBox(color: nc.skeleton)
                        : RawImage(image: thumb, fit: BoxFit.fill),
                  ),
                  if (template.premium && !premium)
                    PositionedDirectional(
                      end: 6,
                      top: 6,
                      child: Container(
                        width: 26,
                        height: 26,
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: nc.surface,
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0x33FFC21A)),
                          boxShadow: const [BoxShadow(color: Color(0x24000000), blurRadius: 2, offset: Offset(0, 1))],
                        ),
                        child: const NativeIcon(ND.icCrown),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// tab_indicator.xml: a 24 x 3dp bar with 2dp corners centred under the tab.
class _TabIndicator extends Decoration {
  const _TabIndicator(this.color);

  final Color color;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _TabIndicatorPainter(color);
}

class _TabIndicatorPainter extends BoxPainter {
  _TabIndicatorPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) return;
    final rect = Rect.fromLTWH(offset.dx + (size.width - 24) / 2, offset.dy + size.height - 3, 24, 3);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(2)), Paint()..color = color);
  }
}
