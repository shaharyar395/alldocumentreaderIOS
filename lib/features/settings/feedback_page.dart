import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../services/platform_bridge.dart';
import '../../widgets/chrome.dart';
import 'app_links.dart';
import 'native_bars.dart';

/// "Feedback or suggestion" like the Android FeedbackActivity: 5-star rating, problem chips,
/// details, up to 4 screenshots, Submit (enabled once there is a rating, a problem or text).
/// Submit writes an e-mail to the support address with the app version and the device; with
/// screenshots it goes through the share sheet (an e-mail link cannot carry attachments).
/// The page closes after sending.
class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  static const _maxShots = 4;
  static const _problems = ['fbCantOpen', 'fbTooManyAds', 'fbSlow', 'fbCrashes', 'fbOthers'];
  static const _appName = 'All Document Reader';

  int _stars = 0;
  final Set<String> _chips = {};
  final _text = TextEditingController();
  final List<XFile> _shots = [];
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _canSubmit => _stars > 0 || _chips.isNotEmpty || _text.text.trim().isNotEmpty;

  Future<void> _addShots() async {
    final s = S.of(context);
    if (_shots.length >= _maxShots) {
      showToast(context, s.t('fbMaxShots'));
      return;
    }
    final scope = AppScope.of(context);
    scope.guard.arm(scope.settings);
    final files = await ImagePicker().pickMultiImage();
    if (!mounted || files.isEmpty) return;
    final room = _maxShots - _shots.length;
    setState(() => _shots.addAll(files.take(room)));
    if (files.length > room) showToast(context, s.t('fbMaxShots'));
  }

  /// "Android 14 (SDK 34) · Samsung SM-S911B" from the platform when it offers it (channel
  /// method "deviceInfo"); otherwise the system name and version known to Dart.
  Future<String> _deviceLine() async {
    try {
      final info = await const MethodChannel('com.theoccess.alldocreader/platform').invokeMethod<String>('deviceInfo');
      if (info != null && info.isNotEmpty) return info;
    } catch (_) {
      // not offered by this platform side
    }
    final system = Platform.isAndroid ? 'Android' : (Platform.isIOS ? 'iOS' : Platform.operatingSystem);
    return '$system ${Platform.operatingSystemVersion}';
  }

  Future<void> _submit() async {
    if (_sending) return;
    _sending = true;
    final s = S.of(context);
    final scope = AppScope.of(context);
    final version = await PlatformBridge.appVersion() ?? '';
    final device = await _deviceLine();
    if (!mounted) {
      _sending = false;
      return;
    }
    final details = _text.text.trim();
    final body = [
      if (_stars > 0) s.t('fbRatingLine', {'stars': '$_stars'}),
      if (_chips.isNotEmpty) '${s.t('whatProblems')} ${[for (final key in _problems) if (_chips.contains(key)) s.t(key)].join(', ')}',
      if (details.isNotEmpty) ...['', details],
      '',
      '—',
      '$_appName $version'.trim(),
      device,
    ].join('\n');
    final subject = '$_appName – ${s.t('feedbackOrSuggestion')}';
    scope.guard.arm(scope.settings);
    var sent = false;
    try {
      if (_shots.isEmpty) {
        final uri = Uri(
          scheme: 'mailto',
          path: supportEmail,
          query: 'subject=${Uri.encodeComponent(subject)}&body=${Uri.encodeComponent(body)}',
        );
        sent = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        await Share.shareXFiles(_shots, text: body, subject: subject);
        sent = true;
      }
    } catch (error) {
      debugPrint('feedback: $error');
    }
    _sending = false;
    if (!mounted) return;
    if (!sent) {
      showToast(context, s.t('noAppToOpen'));
      return;
    }
    showToast(context, s.t('faqThanks'));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    // activity_feedback.xml (Theme.DocReader.FaqBar: bg_faq status bar)
    return Scaffold(
      backgroundColor: nc.surface,
      body: Column(
        children: [
          // top block (bg_faq, paddingBottom 14dp): back, logo, app name / "Rate our app", stars
          ColoredBox(
            color: nc.bgFaq,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  children: [
                    SizedBox(
                      height: 56,
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(start: 4),
                        child: Row(
                          children: [
                            const NativeBackButton(),
                            const SizedBox(width: 4),
                            const NativeIcon(ND.icLogo, size: 30),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _appName,
                                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: nc.textPrimary),
                                  ),
                                  Text(s.t('rateOurApp'), style: TextStyle(fontSize: 12, color: nc.textSecondary)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 5 stars: 40dp ImageViews, padding 4dp, margins 8dp; empty ones tinted text_hint
                    SizedBox(
                      height: 44,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 1; i <= 5; i++)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: InkResponse(
                                onTap: () => setState(() => _stars = i),
                                radius: 22,
                                child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: i <= _stars
                                      ? const NativeIcon(ND.icStarFilled, size: 32)
                                      : NativeIcon(ND.icStarEmpty, size: 32, tint: nc.textHint),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  s.t('whatProblems'),
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: nc.textPrimary),
                ),
                // ChipGroup (marginTop 10dp, chipSpacingHorizontal 10dp); Material chips are 32dp
                // inside a 48dp touch target, so rows sit 24dp apart.
                const SizedBox(height: 18),
                Wrap(
                  spacing: 10,
                  runSpacing: 24,
                  children: [
                    for (final chip in _problems) _problemChip(context, s.t(chip), _chips.contains(chip), chip),
                  ],
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _text,
                  minLines: 7,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                  cursorColor: nc.primary,
                  style: TextStyle(fontSize: 14, color: nc.textPrimary),
                  decoration: InputDecoration(
                    hintText: s.t('feedbackHintDetail'),
                    hintStyle: TextStyle(color: nc.textHint, fontSize: 14),
                    border: InputBorder.none,
                    isCollapsed: true,
                  ),
                ),
              ],
            ),
          ),
          // screenshots: the add button (bg_add_shot, 56dp, ic_camera), then the chosen pictures
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Tooltip(
                  message: s.t('addScreenshotOne'),
                  child: Material(
                    color: nc.surfaceVariant,
                    borderRadius: BorderRadius.circular(10),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: _addShots,
                      child: SizedBox(
                        width: 56,
                        height: 56,
                        child: Center(child: NativeIcon(ND.icCamera, size: 24, tint: nc.textPrimary)),
                      ),
                    ),
                  ),
                ),
                for (final shot in _shots)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 10),
                    child: _Thumb(file: shot, onRemove: () => setState(() => _shots.remove(shot))),
                  ),
              ],
            ),
          ),
          // btnSubmit: 50dp, margin 16dp, bg_apply_btn; alpha 0.45 while disabled
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Opacity(
                opacity: _canSubmit ? 1 : 0.45,
                child: NativeApplyButton(label: s.t('submit'), onTap: _canSubmit ? _submit : null),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Material Chip with feedback_chip_bg / feedback_chip_text (checked = primary / white).
  Widget _problemChip(BuildContext context, String label, bool checked, String key) {
    final nc = NC.of(context);
    return Material(
      color: checked ? nc.primary : nc.surfaceVariant,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => checked ? _chips.remove(key) : _chips.add(key)),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          child: Text(label, style: TextStyle(fontSize: 14, color: checked ? Colors.white : nc.textPrimary)),
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.file, required this.onRemove});

  final XFile file;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onRemove,
      child: SizedBox(
        width: 56,
        height: 56,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(File(file.path), fit: BoxFit.cover, cacheWidth: 168),
              ),
            ),
            PositionedDirectional(
              top: -6,
              end: -6,
              child: Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(color: Color(0xCC10141C), shape: BoxShape.circle),
                child: const Icon(Icons.close_rounded, size: 13, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
