import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../widgets/chrome.dart';
import '../../widgets/html_text.dart';
import 'app_links.dart';
import 'feedback_page.dart';
import 'native_bars.dart';

/// FAQ like the Android app (activity_faq.xml): View & edit / Manage files / About app chips
/// that jump to (and follow) their section, questions that open with the answer (links open
/// the matching screens), a "Yes / No" vote under every answer, and a Feedback button.
class FaqPage extends StatefulWidget {
  const FaqPage({super.key});

  @override
  State<FaqPage> createState() => _FaqPageState();
}

class _Question {
  const _Question(this.icon, this.question, this.answer);
  final NDrawable icon;
  final String question;
  final String answer;
}

const _sections = <(String, List<_Question>)>[
  ('faqViewEdit', [
    _Question(ND.icQEdit, 'faqQEdit', 'faqAEdit'),
    _Question(ND.icQDisplay, 'faqQDisplay', 'faqADisplay'),
    _Question(ND.icQCopy, 'faqQCopy', 'faqACopy'),
    _Question(ND.icQSearch, 'faqQSearch', 'faqASearch'),
  ]),
  ('faqManage', [
    _Question(ND.icQOpen, 'faqQOpen', 'faqAOpen'),
    _Question(ND.icQCreate, 'faqQCreate', 'faqACreate'),
    _Question(ND.icPrint, 'faqQPrint', 'faqAPrint'),
  ]),
  ('faqAboutApp', [
    _Question(ND.icStSubscriptions, 'faqQSubscription', 'faqASubscription'),
    _Question(ND.icQAds, 'faqQAds', 'faqAAds'),
    _Question(ND.icQSlow, 'faqQSlow', 'faqASlow'),
    _Question(ND.icShield, 'faqQPermissions', 'faqAPermissions'),
  ]),
];

class _FaqPageState extends State<FaqPage> {
  final _sectionKeys = List.generate(_sections.length, (_) => GlobalKey());
  final _scroll = ScrollController();
  final _viewportKey = GlobalKey();
  final Set<String> _open = {};

  /// question key → true (Yes) / false (No)
  final Map<String, bool> _votes = {};
  int _chip = 0;

  /// While a chip's smooth scroll runs, the scroll listener does not move the chip.
  bool _jumping = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_follow);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Native setOnScrollChangeListener: the chip follows the section at the top of the list.
  void _follow() {
    if (_jumping || !_scroll.hasClients) return;
    final viewport = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.attached) return;
    final top = viewport.localToGlobal(Offset.zero).dy;
    var index = 0;
    for (var i = 0; i < _sectionKeys.length; i++) {
      final box = _sectionKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      if (box.localToGlobal(Offset.zero).dy - top <= 24) index = i;
    }
    final position = _scroll.position;
    if (position.pixels > 0 && position.pixels >= position.maxScrollExtent - 1) index = _sections.length - 1;
    if (index != _chip) setState(() => _chip = index);
  }

  Future<void> _jump(int index) async {
    setState(() => _chip = index);
    final target = _sectionKeys[index].currentContext;
    if (target == null) return;
    _jumping = true;
    await Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    _jumping = false;
  }

  void _vote(String question, bool yes) {
    if (_votes[question] == yes) return;
    setState(() => _votes[question] = yes);
    showToast(context, S.of(context).t('faqThanks'));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    return Scaffold(
      backgroundColor: nc.bgFaq,
      body: SafeArea(
        child: Column(
          children: [
            // 52dp bar: back + "FAQ" 18sp bold
            SizedBox(
              height: 52,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: 4),
                child: Row(
                  children: [
                    const NativeBackButton(),
                    Flexible(
                      child: Text(
                        s.t('faq'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: nc.textPrimary, fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 44dp chip row (FaqChip: 32dp, bg_faq_chip, 13sp bold)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsetsDirectional.only(start: 12),
                children: [
                  for (var i = 0; i < _sections.length; i++)
                    Center(
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(end: 8),
                        child: _chipView(context, s.t(_sections[i].$1), _chip == i, () => _jump(i)),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                key: _viewportKey,
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < _sections.length; i++) ...[
                      // item_settings_section.xml with padding 6/12/0/8
                      Padding(
                        key: _sectionKeys[i],
                        padding: const EdgeInsetsDirectional.fromSTEB(6, 12, 0, 8),
                        child: Text(
                          s.t(_sections[i].$1),
                          style: TextStyle(fontWeight: FontWeight.w700, color: nc.toolsSection, fontSize: 14),
                        ),
                      ),
                      for (final q in _sections[i].$2) _card(context, q),
                    ],
                  ],
                ),
              ),
            ),
            // btnFeedback: 50dp, margin 14dp, bg_apply_btn, ic_st_feedback white, 16sp bold
            Padding(
              padding: const EdgeInsets.all(14),
              child: NativeApplyButton(
                label: s.t('feedbackOrSuggestion'),
                fontSize: 16,
                leading: const NativeIcon(ND.icStFeedback, size: 24, tint: Colors.white),
                onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const FeedbackPage())),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chipView(BuildContext context, String label, bool selected, VoidCallback onTap) {
    final nc = NC.of(context);
    return Material(
      color: selected ? nc.primary : nc.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 32,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : nc.textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  /// item_faq.xml: bg_faq_card (surface, 12dp), 52dp header, body with divider, answer, votes.
  Widget _card(BuildContext context, _Question q) {
    final s = S.of(context);
    final nc = NC.of(context);
    final open = _open.contains(q.question);
    final vote = _votes[q.question];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: nc.surface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => setState(() => open ? _open.remove(q.question) : _open.add(q.question)),
              child: SizedBox(
                height: 52,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      NativeIcon(q.icon, size: 20, tint: nc.textPrimary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          s.t(q.question),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15, color: nc.textPrimary),
                        ),
                      ),
                      AnimatedRotation(
                        turns: open ? 0.5 : 0,
                        duration: const Duration(milliseconds: 150),
                        child: NativeIcon(ND.icExpand, size: 16, tint: nc.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (open)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(46, 0, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(height: 1, color: nc.divider),
                    const SizedBox(height: 12),
                    HtmlText(
                      s.t(q.answer),
                      style: TextStyle(color: nc.textPrimary, height: 1.32, fontSize: 14),
                      linkColor: nc.primary,
                      onLink: (href) => openAppLink(context, href),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(child: _voteButton(s.t('faqYes'), vote == true, () => _vote(q.question, true))),
                        const SizedBox(width: 16),
                        Expanded(child: _voteButton(s.t('faqNo'), vote == false, () => _vote(q.question, false))),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// bg_faq_vote: surface_variant 18dp pill; selected = choice_selected_bg + 1dp primary stroke.
  Widget _voteButton(String label, bool selected, VoidCallback onTap) {
    final nc = NC.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: selected ? BorderSide(color: nc.primary) : BorderSide.none,
    );
    return Material(
      color: selected ? nc.choiceSelectedBg : nc.surfaceVariant,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: shape,
        child: SizedBox(
          height: 36,
          child: Center(child: Text(label, style: TextStyle(fontSize: 13, color: nc.textPrimary))),
        ),
      ),
    );
  }
}
