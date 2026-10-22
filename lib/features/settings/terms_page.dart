import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../widgets/html_text.dart';
import 'app_links.dart';
import 'native_bars.dart';

/// Terms of use (the Android app's terms_html, in the app language), like activity_policy.xml:
/// a blue 56dp bar (white back + 18sp title, blue status bar) over selectable 14sp text.
class TermsPage extends StatelessWidget {
  const TermsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    return NativeLightStatusBar(
      child: Scaffold(
        backgroundColor: nc.surface,
        body: Column(
          children: [
            Material(
              color: nc.primary,
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: 56,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(start: 4),
                    child: Row(
                      children: [
                        const NativeBackButton(tint: Colors.white),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            s.t('termsOfUse'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 18),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
                  child: SelectionArea(
                    child: HtmlText(
                      s.t('termsHtml', {'app': 'All Document Reader', 'email': termsContactEmail}),
                      // lineSpacingExtra 3dp on 14sp
                      style: TextStyle(height: 1.4, fontSize: 14, color: nc.textPrimary),
                      linkColor: nc.primary,
                      onLink: (href) => openAppLink(context, href),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
