import 'package:flutter_test/flutter_test.dart';

import 'package:alldocreader/app.dart';
import 'package:alldocreader/core/settings/app_settings.dart';
import 'package:alldocreader/data/file_library.dart';
import 'package:alldocreader/l10n/s.dart';
import 'package:alldocreader/services/ad_service.dart';
import 'package:alldocreader/services/billing_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('first launch shows splash then language', (tester) async {
    await S.preload();
    final settings = AppSettings.defaults();
    await tester.pumpWidget(
      AllDocApp(
        settings: settings,
        library: FileLibrary.memory(),
        ads: AdService(settings),
        billing: BillingService(settings),
      ),
    );
    await tester.pump();
    expect(find.text('All Document Reader'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2700));
    await tester.pump();
    expect(find.text('Language'), findsOneWidget);
  });
}
