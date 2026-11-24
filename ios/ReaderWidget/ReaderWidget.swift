import SwiftUI
import WidgetKit

// Home-screen widgets like the Android app's widget/Widgets.kt: "Quick tools" (search, Home, Recent,
// Bookmarks, Edit PDF), "Document reader" (search, Edit PDF, PDF / Word / Excel / PPT) and
// "PDF editor" (one tile). Every button is a link alldocreader://widget/<action>, handled by the
// app's SceneDelegate → PlatformBridge.acceptLink → Dart handleWidgetAction.
// Texts come from the app (App Group defaults "widget_labels", written in the app's language);
// English is the fallback until the app has run once. No asset catalog: SF Symbols and colours.

private let appGroup = "group.com.ol.documents.reader.docera.offline"

/// The widgets' texts, in the app's language.
struct WidgetLabels {
    private let values: [String: String]

    init() {
        values = UserDefaults(suiteName: appGroup)?.dictionary(forKey: "widget_labels") as? [String: String] ?? [:]
    }

    private func text(_ key: String, _ fallback: String) -> String {
        let value = values[key] ?? ""
        return value.isEmpty ? fallback : value
    }

    var search: String { text("search", "Search") }
    var home: String { text("home", "Home") }
    var recent: String { text("recent", "Recent") }
    var bookmarks: String { text("bookmarks", "Bookmarks") }
    var editPdf: String { text("editPdf", "Edit PDF") }
    var toolsTitle: String { text("toolsTitle", "Quick tools") }
    var toolsDesc: String { text("toolsDesc", "Search, open recent files and bookmarks, or edit a PDF from your home screen") }
    var readerTitle: String { text("readerTitle", "Document reader") }
    var readerDesc: String { text("readerDesc", "Open PDF, Word, Excel and PowerPoint files in one tap") }
    var editorTitle: String { text("editorTitle", "PDF editor") }
    var editorDesc: String { text("editorDesc", "Jump straight into editing a PDF") }
}

/// Colours of the Android widgets (bg_widget, bg_widget_pill, ic_w_*, type_* colours).
private enum WColor {
    static let top = Color(red: 0xEA / 255, green: 0xF4 / 255, blue: 0xF3 / 255)
    static let ink = Color(red: 0x1F / 255, green: 0x29 / 255, blue: 0x33 / 255)
    static let grey = Color(red: 0x64 / 255, green: 0x74 / 255, blue: 0x8B / 255)
    static let pillBorder = Color(red: 0xE2 / 255, green: 0xE8 / 255, blue: 0xF0 / 255)
    static let home = Color(red: 0x0F / 255, green: 0x76 / 255, blue: 0x6E / 255)
    static let recent = Color(red: 0x0F / 255, green: 0x76 / 255, blue: 0x6E / 255)
    static let bookmark = Color(red: 0x0F / 255, green: 0x76 / 255, blue: 0x6E / 255)
    static let edit = Color(red: 0x0D / 255, green: 0x8A / 255, blue: 0x7F / 255)
    static let pdf = Color(red: 0xD1 / 255, green: 0x43 / 255, blue: 0x43 / 255)
    static let word = Color(red: 0x2F / 255, green: 0x5F / 255, blue: 0xC8 / 255)
    static let excel = Color(red: 0x1E / 255, green: 0x8A / 255, blue: 0x55 / 255)
    static let ppt = Color(red: 0xC9 / 255, green: 0x62 / 255, blue: 0x0E / 255)

    static var background: LinearGradient {
        LinearGradient(colors: [top, .white], startPoint: .top, endPoint: .bottom)
    }
}

private func link(_ action: String) -> URL {
    URL(string: "alldocreader://widget/\(action)") ?? URL(fileURLWithPath: "/")
}

// MARK: - Timeline (the labels only; refreshed by the app through WidgetCenter)

struct LabelsEntry: TimelineEntry {
    let date: Date
    let labels: WidgetLabels
}

struct LabelsProvider: TimelineProvider {
    func placeholder(in context: Context) -> LabelsEntry {
        LabelsEntry(date: Date(), labels: WidgetLabels())
    }

    func getSnapshot(in context: Context, completion: @escaping (LabelsEntry) -> Void) {
        completion(LabelsEntry(date: Date(), labels: WidgetLabels()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LabelsEntry>) -> Void) {
        completion(Timeline(entries: [LabelsEntry(date: Date(), labels: WidgetLabels())], policy: .never))
    }
}

// MARK: - Pieces

/// The widget background: containerBackground on iOS 17+, a plain background before.
private struct WidgetBackground: ViewModifier {
    let padding: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.containerBackground(for: .widget) { WColor.background }
        } else {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WColor.background)
        }
    }
}

/// bg_widget_pill: white, thin blue-grey border, round.
private struct Pill<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                Capsule().fill(Color.white).overlay(Capsule().stroke(WColor.pillBorder, lineWidth: 1))
            )
    }
}

private struct SearchPill: View {
    let label: String

    var body: some View {
        Link(destination: link("search")) {
            Pill {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(WColor.grey)
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundColor(WColor.grey)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// One button: a 28 pt icon over an 11 pt label.
private struct WidgetButton: View {
    let action: String
    let symbol: String
    let tint: Color
    let label: String
    var filledTile = false

    var body: some View {
        Link(destination: link(action)) {
            VStack(spacing: 3) {
                if filledTile {
                    // a coloured rounded square with a white symbol (file type / edit tiles)
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint))
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(tint)
                        .frame(width: 28, height: 28)
                }
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(WColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Quick tools (systemMedium)

struct ToolsWidgetView: View {
    let entry: LabelsEntry

    var body: some View {
        let l = entry.labels
        VStack(spacing: 6) {
            SearchPill(label: l.search)
            HStack(spacing: 0) {
                WidgetButton(action: "home", symbol: "house.fill", tint: WColor.home, label: l.home)
                WidgetButton(action: "recent", symbol: "clock.fill", tint: WColor.recent, label: l.recent)
                WidgetButton(action: "bookmarks", symbol: "bookmark.fill", tint: WColor.bookmark, label: l.bookmarks)
                WidgetButton(action: "edit", symbol: "square.and.pencil", tint: WColor.edit, label: l.editPdf, filledTile: true)
            }
        }
        .modifier(WidgetBackground(padding: 12))
    }
}

struct ToolsWidget: Widget {
    var body: some WidgetConfiguration {
        let l = WidgetLabels()
        return StaticConfiguration(kind: "ToolsWidget", provider: LabelsProvider()) { entry in
            ToolsWidgetView(entry: entry)
        }
        .configurationDisplayName(l.toolsTitle)
        .description(l.toolsDesc)
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Document reader (systemMedium)

struct ReaderWidgetView: View {
    let entry: LabelsEntry

    var body: some View {
        let l = entry.labels
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                SearchPill(label: l.search)
                Link(destination: link("edit")) {
                    Pill {
                        HStack(spacing: 6) {
                            Image(systemName: "pencil")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(WColor.edit)
                            Text(l.editPdf)
                                .font(.system(size: 13))
                                .foregroundColor(WColor.ink)
                                .lineLimit(1)
                        }
                    }
                    .fixedSize()
                }
            }
            HStack(spacing: 0) {
                WidgetButton(action: "pdf", symbol: "doc.richtext", tint: WColor.pdf, label: "PDF", filledTile: true)
                WidgetButton(action: "word", symbol: "doc.text", tint: WColor.word, label: "Word", filledTile: true)
                WidgetButton(action: "excel", symbol: "tablecells", tint: WColor.excel, label: "Excel", filledTile: true)
                WidgetButton(action: "ppt", symbol: "rectangle.on.rectangle", tint: WColor.ppt, label: "PPT", filledTile: true)
            }
        }
        .modifier(WidgetBackground(padding: 12))
    }
}

/// Kind "ReaderWidget" is the one earlier versions placed, so those widgets keep working.
struct ReaderWidget: Widget {
    var body: some WidgetConfiguration {
        let l = WidgetLabels()
        return StaticConfiguration(kind: "ReaderWidget", provider: LabelsProvider()) { entry in
            ReaderWidgetView(entry: entry)
        }
        .configurationDisplayName(l.readerTitle)
        .description(l.readerDesc)
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - PDF editor (systemSmall, the whole widget is one link)

struct EditPdfWidgetView: View {
    let entry: LabelsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(WColor.pillBorder, lineWidth: 1))
                Image(systemName: "doc.richtext")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundColor(WColor.pdf)
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(WColor.edit)
                    .background(Circle().fill(Color.white))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 4) {
                Text(entry.labels.editPdf)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(WColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(WColor.home)
            }
            .padding(.top, 8)
        }
        .modifier(WidgetBackground(padding: 14))
        .widgetURL(link("edit"))
    }
}

struct EditPdfWidget: Widget {
    var body: some WidgetConfiguration {
        let l = WidgetLabels()
        return StaticConfiguration(kind: "EditPdfWidget", provider: LabelsProvider()) { entry in
            EditPdfWidgetView(entry: entry)
        }
        .configurationDisplayName(l.editorTitle)
        .description(l.editorDesc)
        .supportedFamilies([.systemSmall])
    }
}

@main
struct ReaderWidgets: WidgetBundle {
    var body: some Widget {
        ToolsWidget()
        ReaderWidget()
        EditPdfWidget()
    }
}
