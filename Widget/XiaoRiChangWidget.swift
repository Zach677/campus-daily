import SwiftUI
import WidgetKit
import Core

struct CampusEntry: TimelineEntry { let date: Date; let model: CampusWidgetModel }
struct CampusTimeline: TimelineProvider {
    /// Widget gallery / redacted placeholder: sample numbers, not anyone's data.
    static let sample = CampusWidgetModel(state:.fresh, remainingKWh:Decimal(string:"42.6"), balance:Decimal(string:"86.50"),
                                          yesterdayKWh:Decimal(string:"5.1"), powerBalance:Decimal(string:"23.40"), updated:Date())
    /// The widget's own school read: the same stack as the app (card session → portal token →
    /// saved password once → needs login), writing the same shared snapshot, one process at a
    /// time through the lease. Built once per widget process.
    static let school = SchoolRefreshStack(store:SharedKeychain.store, http:SchoolRefreshStack.schoolHTTP(), role:"widget",
                                           leaseWait:SchoolRefreshStack.widgetLeaseWait)
    /// The read gives up after this; the stored numbers are drawn and the next timeline tries again.
    static let readDeadline: TimeInterval = 20
    static let interval: TimeInterval = 30 * 60

    private static func account() -> SchoolAccount? { (try? StoredSchoolVault(store:SharedKeychain.store).account()) ?? nil }

    private static func model(_ snapshot: HomeSnapshot?, at date: Date) -> CampusWidgetModel {
        var model = CampusWidgetModel(snapshot:snapshot, account:account(), now:date)
        model.lines = ReminderLines.shared()
        return model
    }

    func placeholder(in context: Context) -> CampusEntry { CampusEntry(date:Date(), model:Self.sample) }
    /// Transient (gallery, first add): the stored snapshot, no network.
    func getSnapshot(in context: Context, completion: @escaping (CampusEntry) -> Void) {
        let now = Date()
        let model = Self.model(Self.school.refresher.latest(), at:now)
        completion(CampusEntry(date:now, model:context.isPreview && model.state == .never ? Self.sample : model))
    }
    /// Reads the school data (unless the app just did), then draws; again in 30 minutes. When the
    /// numbers turn stale before then by time alone, a second entry switches at that moment.
    func getTimeline(in context: Context, completion: @escaping (Timeline<CampusEntry>) -> Void) {
        let done = Completion(call:completion)
        Task {
            let now = Date()
            let snapshot = await WidgetRefresh.run(Self.school.refresher, now:now, deadline:Self.readDeadline)
            let next = now.addingTimeInterval(Self.interval)
            var entries = [CampusEntry(date:now, model:Self.model(snapshot, at:now))]
            if let staleAt = WidgetStatus.staleAt(snapshot:snapshot, account:Self.account(), now:now), staleAt < next {
                entries.append(CampusEntry(date:staleAt, model:Self.model(snapshot, at:staleAt)))
            }
            done.call(Timeline(entries:entries, policy:.after(next)))
        }
    }

    /// WidgetKit's completion handler, called once from the read's task.
    private struct Completion: @unchecked Sendable {
        // @unchecked: WidgetKit accepts the call from any thread.
        let call: (Timeline<CampusEntry>) -> Void
    }
}

@main struct XiaoRiChangWidgetBundle: WidgetBundle {
    var body: some Widget {
        XiaoRiChangWidget()
        ShowerLiveActivity()
        LaundryLiveActivity()
    }
}
struct XiaoRiChangWidget: Widget {
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
            .widgetURL(entry.model.url)
    }
}
