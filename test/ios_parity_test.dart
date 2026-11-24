import 'package:alldocreader/services/ios_analytics.dart';
import 'package:alldocreader/services/local_reminders.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cancel event stays within 40 characters', () {
    const allowed = 'image_to_pdf_selection_cancel_tapped';
    const dropped = 'image_to_pdf_selection_screen_cancel_tapped';
    expect(allowed.length, lessThanOrEqualTo(40));
    expect(IosAnalytics.sanitize(allowed), allowed);
    expect(dropped.length, greaterThan(40));
    expect(IosAnalytics.sanitize(dropped).length, 40);
  });

  test('a real open skips the rest of today and keeps the weekly cap', () {
    final now = DateTime(2026, 11, 23, 9).millisecondsSinceEpoch;
    final plan = ReminderPlanner.next(
      now: now,
      open: now,
      sentAt: 0,
      install: now,
      weekStart: 0,
      weekCount: 0,
      prodWeek: 0,
      prodCount: 0,
      readingOpen: -1,
      documentOpen: -1,
      welcomeOpen: -1,
      sentPdf: false,
      sentFiles: false,
      sentTools: false,
    );
    expect(plan, isNotNull);
    final at = DateTime.fromMillisecondsSinceEpoch(plan!.at);
    expect(at.day, 24);
    expect(at.hour, 10);
    expect(plan.kind, 'daily');
  });

  test('seven days away chooses welcome before the one-shot tools reminder', () {
    final now = DateTime(2026, 11, 23, 8).millisecondsSinceEpoch;
    final open = DateTime(2026, 11, 16, 8).millisecondsSinceEpoch;
    final plan = ReminderPlanner.next(
      now: now,
      open: open,
      sentAt: 0,
      install: open,
      weekStart: 0,
      weekCount: 0,
      prodWeek: 0,
      prodCount: 0,
      readingOpen: -1,
      documentOpen: -1,
      welcomeOpen: -1,
      sentPdf: true,
      sentFiles: true,
      sentTools: false,
    );
    expect(plan?.kind, 'welcome');
    expect(DateTime.fromMillisecondsSinceEpoch(plan!.at).hour, 11);
  });
}
