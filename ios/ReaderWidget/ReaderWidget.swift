import SwiftUI
import WidgetKit

struct ReaderEntry: TimelineEntry {
    let date: Date
    let line: String
}

struct ReaderProvider: TimelineProvider {
    func placeholder(in context: Context) -> ReaderEntry {
        ReaderEntry(date: Date(), line: "0")
    }

    func getSnapshot(in context: Context, completion: @escaping (ReaderEntry) -> Void) {
        completion(ReaderEntry(date: Date(), line: currentLine()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReaderEntry>) -> Void) {
        let entry = ReaderEntry(date: Date(), line: currentLine())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 30))))
    }

    private func currentLine() -> String {
        UserDefaults(suiteName: "group.com.theoccess.alldocreader")?.string(forKey: "widget_line") ?? "0"
    }
}

struct ReaderWidgetView: View {
    var entry: ReaderEntry

    var body: some View {
        HStack(spacing: 12) {
            Text("A")
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(Color(red: 0.18, green: 0.42, blue: 1))
                .cornerRadius(8)
            VStack(alignment: .leading, spacing: 2) {
                Text("All Document Reader")
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.line)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
        // tapping the widget opens the app on its home screen (handled in SceneDelegate)
        .widgetURL(URL(string: "alldocreader://widget/home"))
    }
}

@main
struct ReaderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ReaderWidget", provider: ReaderProvider()) { entry in
            ReaderWidgetView(entry: entry)
        }
        .configurationDisplayName("All Document Reader")
        .description("Open your documents.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
