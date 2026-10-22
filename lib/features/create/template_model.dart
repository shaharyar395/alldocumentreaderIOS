import 'dart:ui' show Rect;

/*
 * An editable template page: shapes (fixed decoration), texts and pictures, positioned in PDF
 * points on an A4 page (595 × 842). Texts and pictures can be selected, moved, turned, resized,
 * restyled, duplicated and deleted in the template editor.
 */

const double tplPageW = 595;
const double tplPageH = 842;

enum TplCategory { resume, letter, briefing, poster }

abstract class TEl {
  TEl({required this.x, required this.y, this.rotation = 0});

  double x;
  double y;

  /// Degrees, clockwise.
  double rotation;

  TEl copyEl();
}

enum TShapeKind { rect, oval, line }

/// Fixed decoration (background blocks, lines, circles); not selectable.
class TShape extends TEl {
  TShape(
    this.kind, {
    required super.x,
    required super.y,
    required this.w,
    required this.h,
    required this.color,
    this.color2,
    this.horizontal = false,
    this.radius = 0,
    this.stroke = 0,
    super.rotation,
  });

  final TShapeKind kind;
  final double w;
  final double h;
  final int color;

  /// Gradient end (top → bottom, or left → right when [horizontal]).
  final int? color2;
  final bool horizontal;
  final double radius;

  /// > 0 = outline only.
  final double stroke;

  @override
  TEl copyEl() => TShape(kind, x: x, y: y, w: w, h: h, color: color, color2: color2, horizontal: horizontal, radius: radius, stroke: stroke, rotation: rotation);
}

/// A text box of width [w]; its height follows the text.
class TText extends TEl {
  TText(
    this.text, {
    required super.x,
    required super.y,
    required this.w,
    required this.size,
    this.color = 0xFF1B1F2A,
    this.font = tplDefaultFont,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.list = 0,
    this.align = 0,
    this.lineMult = 1.2,
    super.rotation,
  });

  String text;
  double w;
  double size;
  int color;
  String font;
  bool bold;
  bool italic;
  bool underline;
  bool strike;

  /// 0 = none, 1 = bullets, 2 = numbers.
  int list;

  /// 0 = left, 1 = centre, 2 = right.
  int align;
  double lineMult;

  @override
  TEl copyEl() => TText(
        text,
        x: x,
        y: y,
        w: w,
        size: size,
        color: color,
        font: font,
        bold: bold,
        italic: italic,
        underline: underline,
        strike: strike,
        list: list,
        align: align,
        lineMult: lineMult,
        rotation: rotation,
      );
}

/// A picture: built-in art ([res]) or a picked photo ([path]).
class TImage extends TEl {
  TImage({
    this.res,
    this.path,
    required super.x,
    required super.y,
    required this.w,
    required this.h,
    super.rotation,
    this.flipH = false,
    this.flipV = false,
    this.crop = const Rect.fromLTRB(0, 0, 1, 1),
    this.circle = false,
    this.corner = 0,
  });

  String? res;
  String? path;
  double w;
  double h;
  bool flipH;
  bool flipV;

  /// Visible part of the picture as fractions (Crop).
  Rect crop;
  bool circle;
  double corner;

  @override
  TEl copyEl() => TImage(res: res, path: path, x: x, y: y, w: w, h: h, rotation: rotation, flipH: flipH, flipV: flipV, crop: crop, circle: circle, corner: corner);
}

class TPage {
  TPage(this.bg, this.elements);

  final int bg;
  final List<TEl> elements;

  TPage copyPage() => TPage(bg, [for (final el in elements) el.copyEl()]);
}

class Template {
  const Template(this.id, this.category, this.nameKey, this.build, {this.premium = false});

  final String id;
  final TplCategory category;

  /// l10n key of the name shown under the thumbnail.
  final String nameKey;
  final TPage Function() build;

  /// Crowned: Premium (free users get a few tries a day).
  final bool premium;
}

const tplDefaultFont = 'Roboto';

// ---------------------------------------------------------------------------------------------
// The built-in templates (original designs and sample text), like the Android app.
// ---------------------------------------------------------------------------------------------

const _ink = 0xFF1B1F2A;
const _grey = 0xFF6B7380;
const _light = 0xFF9AA1AC;
const _blue = 0xFF1E6FE6;
const _white = 0xFFFFFFFF;
const _navy = 0xFF24407A;
const _script = 'Dancing Script';

/// Small builder so the templates below read like a layout.
class _B {
  _B([this.bg = _white]);

  final int bg;
  final List<TEl> els = [];

  void rect(double x, double y, double w, double h, int color, {int? color2, double radius = 0, bool horizontal = false}) {
    els.add(TShape(TShapeKind.rect, x: x, y: y, w: w, h: h, color: color, color2: color2, radius: radius, horizontal: horizontal));
  }

  void oval(double x, double y, double w, double h, int color, {int? color2}) {
    els.add(TShape(TShapeKind.oval, x: x, y: y, w: w, h: h, color: color, color2: color2));
  }

  void line(double x, double y, double w, {int color = 0xFFE3E7ED, double thick = 0.8}) {
    els.add(TShape(TShapeKind.line, x: x, y: y, w: w, h: thick, color: color));
  }

  void t(
    String text,
    double x,
    double y,
    double w,
    double size, {
    int color = _ink,
    bool bold = false,
    String font = tplDefaultFont,
    int align = 0,
    int list = 0,
    bool italic = false,
    double line = 1.25,
  }) {
    els.add(TText(text, x: x, y: y, w: w, size: size, color: color, font: font, bold: bold, italic: italic, list: list, align: align, lineMult: line));
  }

  void img(String res, double x, double y, double w, double h, {bool circle = false}) {
    els.add(TImage(res: res, x: x, y: y, w: w, h: h, circle: circle));
  }

  TPage page() => TPage(bg, els);
}

String _today() {
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  final now = DateTime.now();
  return '${months[now.month - 1]} ${now.day}, ${now.year}';
}

const _summary = 'Experienced in leading end-to-end product development across mobile and SaaS platforms. '
    'Skilled in user research, data-driven decision making, and cross-functional collaboration, '
    'with a strong focus on driving measurable business impact.';
const _job1 = 'Spearheaded the launch of a new mobile productivity app across the APAC region, achieving 1.2 million '
    'downloads in the first 6 months and a user retention rate of 38% at Day 30.\nDefined the product roadmap and prioritized '
    'the backlog in collaboration with engineering and UX teams, reducing feature time-to-market by 25%.';
const _job2 = 'Managed a SaaS product for SME customers in Southeast Asia. Launched five major features within 18 months, '
    'growing ARR from US\$1.8M to US\$4.2M.\nSupported the product team for a consumer-facing e-commerce platform, managing feature '
    'definition and user-story creation.';

void _contact(_B b, double x, double y, {int color = _grey}) {
  const rows = [
    ('tpl_ic_pin', 'Singapore'),
    ('tpl_ic_mail', 'riley.morgan@email.com'),
    ('tpl_ic_phone', '+65 9123-4567'),
    ('tpl_ic_web', 'www.nexora-tech.com'),
  ];
  for (var i = 0; i < rows.length; i++) {
    b.img(rows[i].$1, x, y + i * 17, 10, 10);
    b.t(rows[i].$2, x + 16, y + i * 17, 150, 8.5, color: color);
  }
}

// ------------------------------------------------------------------ resumes

TPage _resumeClassic() {
  final b = _B();
  b.t('Product Manager', 40, 42, 300, 8, color: _grey);
  b.t('Riley K. Morgan', 40, 54, 360, 26, bold: true);
  b.line(0, 100, tplPageW, color: 0xFFE9ECF1, thick: 1);
  b.t('Summary', 40, 120, 200, 10, bold: true);
  b.t(_summary, 40, 138, 330, 8.5, color: _grey, line: 1.45);
  b.t('Contact', 400, 120, 150, 10, bold: true);
  _contact(b, 400, 140);
  b.t('Education', 40, 222, 200, 10, bold: true);
  b.t('2013 – 2018', 40, 242, 80, 8, color: _light);
  b.t('University of Birmingham', 130, 242, 300, 8.5, bold: true);
  b.t('Master of Business Administration (MBA), Strategy\nBachelor of Science in Business Administration', 130, 256, 400, 8, color: _grey, line: 1.4);
  b.t('Experience', 40, 300, 200, 10, bold: true);
  b.t('2023 – Present', 40, 320, 80, 8, color: _light);
  b.t('Senior Product Manager', 130, 320, 300, 8.5, bold: true);
  b.t(_job1, 130, 334, 420, 8, color: _grey, line: 1.45);
  b.t('2021 – 2022', 40, 420, 80, 8, color: _light);
  b.t('Product Manager', 130, 420, 300, 8.5, bold: true);
  b.t(_job2, 130, 434, 420, 8, color: _grey, line: 1.45);
  b.rect(40, 530, 515, 62, 0xFFEEF3FB);
  b.rect(40, 530, 3, 62, _blue);
  b.t('SOCIAL SKILLS', 56, 542, 200, 7.5, color: _blue, bold: true);
  b.t('Product Strategy & Roadmapping\nA/B Testing & Experimentation', 56, 558, 220, 8, color: _grey, list: 1);
  b.t('Go-to-Market (GTM) Strategy\nAgile & Scrum Methodology', 300, 558, 220, 8, color: _grey, list: 1);
  return b.page();
}

TPage _resumeGradient() {
  final b = _B();
  b.rect(0, 0, tplPageW, 170, 0xFFF3E8FF, color2: 0xFFFFFFFF);
  b.img('tpl_avatar_1', 262, 30, 70, 70, circle: true);
  b.t('Riley K. Morgan', 60, 108, 475, 20, bold: true, align: 1);
  b.t('Product Manager  ·  Singapore  ·  riley.morgan@email.com', 60, 136, 475, 8.5, color: _grey, align: 1);
  b.t('Summary', 50, 190, 100, 10, bold: true);
  b.t(_summary, 150, 190, 400, 8.5, color: _grey, line: 1.45);
  b.line(50, 250, 495);
  b.t('Experience', 50, 266, 100, 10, bold: true);
  b.t('Senior Product Manager · 2023 – Present', 150, 266, 400, 9, bold: true);
  b.t(_job1, 150, 282, 400, 8, color: _grey, line: 1.45);
  b.t('Product Manager · 2021 – 2022', 150, 366, 400, 9, bold: true);
  b.t(_job2, 150, 382, 400, 8, color: _grey, line: 1.45);
  b.line(50, 470, 495);
  b.t('Education', 50, 486, 100, 10, bold: true);
  b.t('University of Birmingham, 2013 – 2018\nMaster of Business Administration (MBA), Strategy', 150, 486, 400, 8.5, color: _grey, line: 1.45);
  b.line(50, 540, 495);
  b.t('Skills', 50, 556, 100, 10, bold: true);
  b.t('Roadmapping   ·   GTM Strategy   ·   UX Collaboration   ·   Data Analysis', 150, 556, 400, 8.5, color: _grey);
  return b.page();
}

TPage _resumeDark() {
  final b = _B(0xFF15161A);
  b.rect(0, 0, 200, tplPageH, 0xFF1F2127);
  b.rect(200, 520, 395, 322, 0xFF15161A, color2: 0xFF6B4A12);
  b.t('CONTACTS', 26, 40, 150, 8, color: 0xFFB9BDC6, bold: true);
  _contact(b, 26, 60, color: 0xFFB9BDC6);
  b.t('SKILLS', 26, 150, 150, 8, color: 0xFFB9BDC6, bold: true);
  b.t('Roadmapping\nGTM Strategy\nUser Research\nData Analysis\nAgile / Scrum', 26, 168, 150, 8.5, color: 0xFFDDE0E6, list: 1, line: 1.5);
  b.t('EDUCATION', 26, 280, 150, 8, color: 0xFFB9BDC6, bold: true);
  b.t('University of Birmingham\nMBA, Strategy\n2013 – 2018', 26, 298, 160, 8.5, color: 0xFFDDE0E6, line: 1.5);
  b.t('Riley K. Morgan', 226, 40, 340, 24, color: _white, bold: true);
  b.t('Product Manager', 226, 72, 340, 12, color: 0xFFF2B233);
  b.t('SUMMARY', 226, 110, 340, 8, color: 0xFFB9BDC6, bold: true);
  b.t(_summary, 226, 126, 340, 8.5, color: 0xFFDDE0E6, line: 1.45);
  b.t('EXPERIENCE', 226, 196, 340, 8, color: 0xFFB9BDC6, bold: true);
  b.t('Senior Product Manager · 2023 – Present', 226, 214, 340, 9, color: _white, bold: true);
  b.t(_job1, 226, 230, 340, 8, color: 0xFFDDE0E6, line: 1.45);
  b.t('Product Manager · 2021 – 2022', 226, 330, 340, 9, color: _white, bold: true);
  b.t(_job2, 226, 346, 340, 8, color: 0xFFDDE0E6, line: 1.45);
  return b.page();
}

TPage _resumeBlue() {
  final b = _B();
  b.rect(0, 0, 190, tplPageH, 0xFF3D7BEA);
  b.t('Riley K. Morgan', 20, 36, 160, 16, color: _white, bold: true);
  b.t('Product Manager', 20, 58, 160, 9, color: 0xFFDCE7FF);
  b.img('tpl_avatar_2', 35, 90, 120, 120, circle: true);
  b.t('Summary', 20, 236, 160, 10, color: _white, bold: true);
  b.t(_summary, 20, 254, 155, 8, color: 0xFFEAF1FF, line: 1.45);
  b.t('Contact Me', 214, 40, 300, 12, bold: true);
  _contact(b, 214, 64);
  b.t('Experience', 214, 150, 300, 12, bold: true);
  b.t('Senior Product Manager', 214, 172, 340, 9.5, bold: true);
  b.t('2023 – Present · Singapore', 214, 186, 340, 8, color: _light);
  b.t(_job1, 214, 200, 350, 8, color: _grey, line: 1.45);
  b.t('Product Manager', 214, 290, 340, 9.5, bold: true);
  b.t('2021 – 2022 · Singapore', 214, 304, 340, 8, color: _light);
  b.t(_job2, 214, 318, 350, 8, color: _grey, line: 1.45);
  b.t('Education', 214, 410, 300, 12, bold: true);
  b.t('University of Birmingham · 2013 – 2018\nMaster of Business Administration (MBA), Strategy', 214, 432, 350, 8.5, color: _grey, line: 1.45);
  return b.page();
}

// ------------------------------------------------------------------ letters

const _letterBody = 'Dear Mr. Carter,\n\nThank you for taking the time to meet with our team last week. We truly enjoyed learning '
    'more about your goals for the coming year and how Brandex can support them.\n\nAs discussed, we have prepared a proposal '
    'that covers the project scope, timeline and budget. We believe this plan will help you reach your targets while keeping '
    'costs under control. Please review the attached documents and let us know if you have any questions.\n\nWe look forward '
    'to working with you.\n\nKind regards,';

TPage _letterCompany() {
  final b = _B();
  b.img('tpl_logo', 50, 44, 22, 22);
  b.t('brandex', 78, 46, 200, 15, color: _blue, bold: true);
  b.t(_today(), 380, 50, 165, 8.5, color: _grey, align: 2);
  b.line(50, 86, 495);
  b.t('Mr. Daniel Carter\nBrightMove Interactive\n12 Harbour Road, Singapore', 50, 104, 300, 9, line: 1.4);
  b.t(_letterBody, 50, 170, 495, 9.5, line: 1.5);
  b.t('Morgan', 50, 470, 200, 22, font: _script);
  b.t('Riley K. Morgan\nProject Director, Brandex', 50, 502, 250, 9, color: _grey, line: 1.4);
  b.line(50, 780, 495);
  b.t('brandex · 88 Market Street, Singapore · hello@brandex.com', 50, 790, 495, 7.5, color: _light, align: 1);
  return b.page();
}

TPage _letterFax() {
  final b = _B();
  b.t('FAX', 50, 50, 200, 36, bold: true);
  b.t('BrightMove Interactive', 350, 60, 195, 9, color: _grey, align: 2);
  final rows = [
    ('To:', 'Daniel Carter'),
    ('Phone:', '+65 6123-4567'),
    ('Fax:', '+65 6123-4568'),
    ('From:', 'Riley K. Morgan'),
    ('Pages:', '3'),
    ('Date:', _today()),
  ];
  for (var i = 0; i < rows.length; i++) {
    b.t(rows[i].$1, 50, 120 + i * 20.0, 80, 9, color: _grey, bold: true);
    b.t(rows[i].$2, 130, 120 + i * 20.0, 300, 9);
    b.line(130, 133 + i * 20.0, 300);
  }
  b.t('Urgent   ☐     For Review   ☐     Please Reply   ☐', 50, 260, 495, 9);
  b.t('Comments', 50, 300, 200, 11, bold: true);
  b.t(_letterBody.replaceFirst('Dear Mr. Carter,', 'Hello Daniel,'), 50, 322, 495, 9, color: _grey, line: 1.5);
  return b.page();
}

TPage _letterHandwritten() {
  final b = _B(0xFFFBF6EE);
  b.img('tpl_art_flowers', 0, 647, 300, 195);
  b.t('Dear Friend,', 60, 70, 470, 22, color: 0xFF5A4636, font: _script);
  b.t(
    'It has been a while since I last wrote, and I have been thinking about the day we walked together at the park — '
    'the sky was so clear.\n\nI remember you mentioned you were preparing for a new adventure, and I imagine you are '
    'busy with it now. I hope everything is going well and that you are taking good care of yourself.\n\nWhen you are '
    "back in town, let's meet for coffee and catch up on everything.",
    60,
    120,
    470,
    15,
    color: 0xFF5A4636,
    font: _script,
    line: 1.35,
  );
  b.t('With love,\nMy', 330, 560, 200, 16, color: 0xFF5A4636, font: _script, align: 2);
  return b.page();
}

TPage _letterProposal() {
  final b = _B();
  b.oval(-80, 700, 760, 260, 0xFF1E6FE6, color2: 0xFF0F3E9C);
  b.oval(-60, 680, 720, 200, 0xFFDDE9FB);
  b.oval(-40, 700, 680, 180, _white);
  b.img('tpl_logo', 50, 44, 22, 22);
  b.t('BrightMove Interactive', 78, 47, 250, 11, color: _blue, bold: true);
  b.t('BUSINESS PROPOSAL', 50, 110, 495, 22, color: _blue, bold: true);
  b.t(_today(), 50, 146, 300, 9, color: _grey);
  b.t('Prepared for: Daniel Carter, Brandex', 50, 162, 400, 9, color: _grey);
  b.t('Overview', 50, 200, 300, 12, bold: true);
  b.t(
    'BrightMove Interactive proposes to redesign the Brandex mobile experience to increase engagement and online sales. '
    'The project will be delivered in three phases over twelve weeks.',
    50,
    220,
    495,
    9.5,
    color: _grey,
    line: 1.5,
  );
  b.t('Scope of work', 50, 290, 300, 12, bold: true);
  b.t('User research and analytics review\nNew design system and prototypes\nApp development and testing\nLaunch support and reporting', 50, 310, 495, 9.5,
      color: _grey, list: 2, line: 1.6);
  b.t('Investment', 50, 400, 300, 12, bold: true);
  b.t('Total project fee: US\$48,000, payable in three instalments at the start of each phase.', 50, 420, 495, 9.5, color: _grey, line: 1.5);
  b.t('Morgan', 50, 480, 200, 20, font: _script);
  b.t('Riley K. Morgan, Project Director', 50, 510, 300, 9, color: _grey);
  return b.page();
}

// ------------------------------------------------------------------ briefings

TPage _briefingMinutes() {
  final b = _B(0xFFFBF8F1);
  b.t('Meeting\nMinutes\nBriefing', 40, 40, 200, 24, bold: true, line: 1.0);
  b.t('Meeting Time: Monday, 10:00 AM\nMeeting Venue: Room 4B\nRecorder: Riley Morgan', 300, 48, 250, 9, color: _grey, line: 1.5);
  b.line(40, 130, 515, color: _ink, thick: 1.2);
  b.t('1  Meeting Agenda and Discussion Content', 40, 146, 515, 11, bold: true);
  b.t('Review of last quarter\'s results and customer feedback\nPlanning of the new product release\nBudget and resources for Q3', 40, 168, 515, 9.5,
      color: _grey, list: 1, line: 1.5);
  b.t('2  Meeting Resolutions', 40, 240, 515, 11, bold: true);
  const colors = [0xFFE8453C, 0xFF3C8BE8, 0xFF1FB35A, 0xFFF2B233];
  for (var i = 0; i < 4; i++) {
    final x = 40 + (i % 2) * 262.0;
    final y = 266 + (i ~/ 2) * 96.0;
    b.rect(x, y, 253, 86, _white, radius: 4);
    b.rect(x, y, 4, 86, colors[i]);
    b.t('Resolution ${i + 1}', x + 14, y + 10, 230, 9.5, bold: true);
    b.t('Owner: Team ${String.fromCharCode(0x41 + i)}\nDeadline: within two weeks\nStatus: in progress', x + 14, y + 28, 230, 8.5, color: _grey, line: 1.4);
  }
  b.t('3  Next Steps', 40, 470, 515, 11, bold: true);
  b.t('Share the release plan with all teams by Friday. The next briefing will review progress on each resolution.', 40, 492, 515, 9.5,
      color: _grey, line: 1.5);
  return b.page();
}

TPage _briefingBlueprint() {
  final b = _B();
  b.rect(40, 36, 515, 4, 0xFF1FB35A);
  b.t('Strategic Work\nArrangement Blueprint', 40, 56, 400, 24, bold: true, line: 1.05);
  const steps = [
    ('TASK 1', 'Goal & role assignment — define the quarter\'s goals and who owns each one.'),
    ('TASK 2', 'Resource preparation — confirm budget, tools and people for every goal.'),
    ('TASK 3', 'Customer development — interview customers and collect feedback.'),
    ('TASK 4', 'Product optimisation — turn feedback into improvements and release them.'),
  ];
  for (var i = 0; i < steps.length; i++) {
    final y = 140 + i * 110.0;
    b.t('${i + 1}', 40, y, 50, 48, color: 0xFFD6DBE3, bold: true);
    b.t(steps[i].$1, 110, y + 6, 120, 9, color: 0xFF1FB35A, bold: true);
    b.t(steps[i].$2, 110, y + 22, 440, 10, line: 1.45);
    b.line(110, y + 90, 445);
  }
  b.t('Work Objectives', 380, 600, 175, 10, color: 0xFF1FB35A, bold: true, align: 2);
  return b.page();
}

TPage _briefingWeekly() {
  final b = _B();
  b.rect(40, 40, 110, 18, 0xFFF2B233, radius: 9);
  b.t('NOVEMBER 11TH', 40, 44, 110, 7.5, bold: true, align: 1);
  b.t('Academic Weekly\nTask Schedule', 40, 70, 400, 26, bold: true, line: 1.05);
  const parts = [
    ('WORK', 'Finish the project report and send it for review.'),
    ('STUDY', 'Read chapters 4–6 and prepare notes for the seminar.'),
    ('LIFE', 'Plan meals for the week and book a dentist appointment.'),
    ('PERSONAL DEVELOPMENT', 'Practise public speaking for 20 minutes every day.'),
  ];
  const times = ['2-4 hours', '1.5 hours', '1 hour', '20 min'];
  for (var i = 0; i < parts.length; i++) {
    final y = 170 + i * 100.0;
    b.t('(${i + 1})  ${parts[i].$1}', 40, y, 400, 11, bold: true);
    b.t(parts[i].$2, 40, y + 20, 400, 9.5, color: _grey, line: 1.45);
    b.rect(470, y + 14, 80, 20, 0xFFFFF1CC, radius: 10);
    b.t(times[i], 470, y + 19, 80, 8, color: 0xFF8A6100, bold: true, align: 1);
    b.line(40, y + 72, 515);
  }
  return b.page();
}

// ------------------------------------------------------------------ posters

TPage _posterGrads() {
  final b = _B(0xFFFBF1E3);
  b.t('Grads', 60, 70, 475, 64, color: _navy, bold: true, align: 1);
  b.t('Party', 60, 140, 475, 64, color: _navy, bold: true, align: 1);
  b.t('Great', 150, 205, 300, 34, color: 0xFFF26B1D, font: _script, align: 1);
  b.img('tpl_art_cap', 147, 260, 300, 300);
  b.t('Class of 2026', 60, 580, 475, 14, color: _navy, align: 1);
  b.rect(60, 640, 475, 1.5, _navy);
  b.t('NUS Kent Ridge\n36 Heng Mui Keng Terrace, Singapore', 60, 660, 300, 10, color: _navy, line: 1.4);
  b.t('06/NOV/26', 380, 664, 155, 16, color: 0xFFF26B1D, bold: true, align: 2);
  return b.page();
}

TPage _posterAgency() {
  final b = _B();
  b.rect(0, 0, tplPageW, 330, 0xFFF7C23C);
  b.img('tpl_art_megaphone', 330, 120, 240, 190);
  b.t('DIGITAL', 40, 40, 300, 10, bold: true);
  b.t('MARKETING\nAGENCY', 40, 60, 400, 48, bold: true, line: 1.0);
  b.t('ABOUT US', 40, 360, 250, 11, bold: true);
  b.t('We help brands grow online with strategy, content and campaigns that bring real results.', 40, 380, 250, 9.5, color: _grey, line: 1.5);
  b.t('WHY CHOOSE US?', 40, 450, 250, 11, bold: true);
  b.t('10+ years of experience\n200+ happy clients\nClear monthly reporting', 40, 470, 250, 9.5, color: _grey, list: 1, line: 1.6);
  b.t('OUR SERVICES', 320, 360, 235, 11, bold: true);
  b.t('Strategic Consulting\nCreative Campaigns\nAnalytics & Optimization\nSocial Media Management', 320, 380, 235, 9.5, color: _grey, list: 1, line: 1.7);
  b.rect(0, 770, tplPageW, 72, _ink);
  b.t('YOURWEBSITE.COM', 40, 798, 515, 12, color: _white, bold: true, align: 1);
  return b.page();
}

TPage _posterWebinar() {
  final b = _B(0xFFFBEBDD);
  b.img('tpl_art_sun', 360, 20, 220, 220);
  b.rect(40, 50, 90, 20, 0xFF1FB35A, radius: 10);
  b.t('Free Webinar', 40, 55, 90, 8.5, color: _white, bold: true, align: 1);
  b.t('EXCELLING\nIN ONLINE\nMARKETING', 40, 90, 360, 44, color: _navy, bold: true, line: 1.0);
  b.t('Get expert tips on creating effective campaigns, finding your audience and growing your brand.', 40, 260, 330, 11, color: _grey, line: 1.5);
  b.t('Host:', 40, 330, 60, 10, color: _grey);
  b.rect(40, 348, 110, 22, 0xFF3C3CE8);
  b.t('ALEX REED', 40, 354, 110, 9.5, color: _white, bold: true, align: 1);
  b.rect(0, 520, tplPageW, 322, 0xFF2A2FD6);
  b.t('25', 40, 570, 120, 70, color: _white, bold: true);
  b.t('AUG\nThursday\n3:00 PM – 4:30 PM', 150, 580, 200, 12, color: _white, line: 1.5);
  b.oval(400, 600, 150, 150, 0xFFF26B1D);
  b.t('Reserve\nyour spot\ntoday!', 400, 640, 150, 14, color: _white, bold: true, align: 1);
  return b.page();
}

TPage _posterBlackFriday() {
  final b = _B(0xFFD9262E);
  b.img('tpl_art_bags', 150, 60, 300, 270);
  b.t('BLACK\nFRIDAY', 40, 360, 515, 70, color: _white, bold: true, italic: true, align: 1, line: 0.95);
  b.rect(170, 530, 255, 60, _ink, radius: 8);
  b.t('50% OFF', 170, 540, 255, 34, color: 0xFFFFD447, bold: true, align: 1);
  b.t('Black Friday deals up to 50% off on all items.\nThursday – Sunday only.', 40, 630, 515, 12, color: _white, align: 1, line: 1.5);
  return b.page();
}

TPage _posterChristmas() {
  final b = _B(0xFFF7EEDD);
  b.img('tpl_art_tree', 172, 80, 250, 300);
  b.t('Merry', 40, 420, 515, 54, color: 0xFFB3262B, font: _script, align: 1);
  b.t('Christmas', 40, 486, 515, 54, color: 0xFF1F7A45, font: _script, align: 1);
  b.t('May your holidays be filled with joy, warmth and laughter.\nWishing you a happy new year!', 60, 590, 475, 12, color: _grey, align: 1, line: 1.5);
  return b.page();
}

/// 16 templates in four groups; the second half of each group is crowned (Premium).
const List<Template> tplLibrary = [
  Template('resume_classic', TplCategory.resume, 'resume', _resumeClassic),
  Template('resume_gradient', TplCategory.resume, 'resume', _resumeGradient),
  Template('resume_dark', TplCategory.resume, 'resume', _resumeDark, premium: true),
  Template('resume_blue', TplCategory.resume, 'resume', _resumeBlue, premium: true),
  Template('letter_company', TplCategory.letter, 'letter', _letterCompany),
  Template('letter_handwritten', TplCategory.letter, 'letter', _letterHandwritten),
  Template('letter_fax', TplCategory.letter, 'fax', _letterFax, premium: true),
  Template('letter_proposal', TplCategory.letter, 'proposal', _letterProposal, premium: true),
  Template('briefing_minutes', TplCategory.briefing, 'briefing', _briefingMinutes),
  Template('briefing_blueprint', TplCategory.briefing, 'briefing', _briefingBlueprint),
  Template('briefing_weekly', TplCategory.briefing, 'schedule', _briefingWeekly, premium: true),
  Template('poster_grads', TplCategory.poster, 'poster', _posterGrads),
  Template('poster_agency', TplCategory.poster, 'poster', _posterAgency),
  Template('poster_webinar', TplCategory.poster, 'poster', _posterWebinar, premium: true),
  Template('poster_poster_bf', TplCategory.poster, 'poster', _posterBlackFriday, premium: true),
  Template('poster_christmas', TplCategory.poster, 'poster', _posterChristmas, premium: true),
];

Template? templateById(String id) {
  for (final template in tplLibrary) {
    if (template.id == id) return template;
  }
  return null;
}
