import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../services/ios_analytics.dart';
import '../../widgets/chrome.dart';
import '../../widgets/html_text.dart';
import 'app_links.dart';
import 'native_bars.dart';

/// Terms of use (the Android app's terms_html, in the app language), like activity_policy.xml:
/// a blue 56dp bar (white back + 18sp title, blue status bar) over selectable 14sp text.
class TermsPage extends StatefulWidget {
  const TermsPage({super.key});

  @override
  State<TermsPage> createState() => _TermsPageState();
}

class _TermsPageState extends State<TermsPage> {
  @override
  void initState() {
    super.initState();
    IosAnalytics.activate('terms');
  }

  @override
  void dispose() {
    IosAnalytics.left('terms');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    // activity_policy.xml ("Plum deck"): the page-coloured bar with the back circle and title
    return Scaffold(
        backgroundColor: nc.bgScreen,
        body: Column(
          children: [
            SafeArea(
              bottom: false,
              child: SizedBox(
                height: 56,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 8),
                  child: Row(
                    children: [
                      NativeBackButton(onTap: () {
                        IosAnalytics.back('terms');
                        Navigator.of(context).maybePop();
                      }),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(s.t('termsOfUse'), maxLines: 1, overflow: TextOverflow.ellipsis, style: dsTopBarTitle(context)),
                      ),
                    ],
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
                      s.t(Platform.isIOS ? 'termsHtmlIos' : 'termsHtml', {'app': 'All Document Reader', 'email': termsContactEmail}),
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
    );
  }
}
