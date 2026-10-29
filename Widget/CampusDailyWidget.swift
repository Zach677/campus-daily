import SwiftUI
import WidgetKit
import WaterCore

struct CampusEntry: TimelineEntry { let date: Date; let model: CampusWidgetModel }
struct CampusTimeline: TimelineProvider {
    /// Widget gallery / redacted placeholder: sample numbers, not anyone's data.
    static let sample = CampusWidgetModel(signedIn:true, remainingKWh:Decimal(string:"42.6"), balance:Decimal(string:"86.50"),
                                          yesterdayKWh:Decimal(string:"5.1"), powerBalance:Decimal(string:"23.40"), updated:Date())
    private static func cachedModel() -> CampusWidgetModel {
        let config = CampusSharedCache.config()
        let cached = CampusSharedCache.read(CampusSnapshot.self).flatMap { $0.owner == config?.cacheIdentity ? $0 : nil }
        var model = CampusWidgetModel(snapshot:cached, loggedIn:config != nil)
        model.lines = ReminderLines.shared()
        return model
    }
    func placeholder(in context: Context) -> CampusEntry { CampusEntry(date:Date(), model:Self.sample) }
    func getSnapshot(in context: Context, completion: @escaping (CampusEntry) -> Void) {
        let model = Self.cachedModel()
        completion(CampusEntry(date:Date(), model:context.isPreview && !model.signedIn ? Self.sample : model))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CampusEntry>) -> Void) {
        Task { @MainActor in
            var cached = CampusSharedCache.read(CampusSnapshot.self)
            if let config = CampusSharedCache.config(), (try? config.validate()) != nil {
                if cached?.owner != config.cacheIdentity { cached = nil }
                var next = cached ?? CampusSnapshot(owner:config.cacheIdentity)
                let provider = CampusProvider()
                if next.balanceIsStale() {
                    do { next.recordBalance(.success(try await provider.balance(config:config))) }
                    catch { next.recordBalance(.failure((error as? CampusError) ?? .network)) }
                }
                if !config.buildingID.isEmpty, next.powerIsStale() {
                    do { next.recordPower(.success(try await provider.electricity(config:config))) }
                    catch { next.recordPower(.failure((error as? CampusError) ?? .network)) }
                }
                if CampusSharedCache.config()?.cacheIdentity == config.cacheIdentity {
                    try? CampusSharedCache.save(next); cached = next
                } else { cached = CampusSharedCache.read(CampusSnapshot.self) }
            }
            let config = CampusSharedCache.config()
            if cached?.owner != config?.cacheIdentity { cached = nil }
            var model = CampusWidgetModel(snapshot:cached, loggedIn:config != nil)
            model.lines = ReminderLines.shared()
            // Every 30 minutes; the app also reloads after each foreground read.
            completion(Timeline(entries:[CampusEntry(date:Date(), model:model)], policy:.after(Date().addingTimeInterval(30 * 60))))
        }
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
    /// Unchanged from round 1 so widgets already on the home screen keep working.
    let kind = "CampusDailyBalances"
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
