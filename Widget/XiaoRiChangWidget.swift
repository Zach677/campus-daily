import SwiftUI
import WidgetKit
import Core

struct CampusEntry: TimelineEntry { let date: Date; let model: CampusWidgetModel }
struct CampusTimeline: TimelineProvider {
    /// Widget gallery / redacted placeholder: sample numbers, not anyone's data.
    static let sample = CampusWidgetModel(signedIn:true, remainingKWh:Decimal(string:"42.6"), balance:Decimal(string:"86.50"),
                                          yesterdayKWh:Decimal(string:"5.1"), powerBalance:Decimal(string:"23.40"), updated:Date())
    /// The app writes `shared.snapshot` after every read; the widget only reads it (no network).
    private static func storedModel() -> CampusWidgetModel {
        var model = CampusWidgetModel(snapshot:(try? SharedSnapshotStore(store:SharedKeychain.store).loadSnapshot()) ?? nil)
        model.lines = ReminderLines.shared()
        return model
    }

    func placeholder(in context: Context) -> CampusEntry { CampusEntry(date:Date(), model:Self.sample) }
    func getSnapshot(in context: Context, completion: @escaping (CampusEntry) -> Void) {
        let model = Self.storedModel()
        completion(CampusEntry(date:Date(), model:context.isPreview && !model.signedIn ? Self.sample : model))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CampusEntry>) -> Void) {
        // Every 30 minutes; the app also reloads after each snapshot write.
        completion(Timeline(entries:[CampusEntry(date:Date(), model:Self.storedModel())], policy:.after(Date().addingTimeInterval(30 * 60))))
    }
}

@main struct CampusDailyBundle: WidgetBundle {
    var body: some Widget {
        CampusDailyWidget()
        ShowerLiveActivity()
        LaundryLiveActivity()
    }
}
struct CampusDailyWidget: Widget {
    let kind = SharedSnapshotStore.widgetKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind:kind, provider:CampusTimeline()) { entry in
            CampusWidgetEntryView(entry:entry)
        }
        .configurationDisplayName("校日常")
        .description("宿舍电量和校园卡余额，一眼就看到。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
struct CampusWidgetEntryView: View {
    let entry: CampusEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        CampusWidgetFace(model:entry.model, medium:family == .systemMedium)
            .privacySensitive()
            .containerBackground(CampusWidgetPalette.group, for:.widget)
            .widgetURL(URL(string:"campusdaily://home"))
    }
}
