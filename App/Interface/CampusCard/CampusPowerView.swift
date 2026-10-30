import SwiftUI
import Core

struct CampusPowerSetupView: View {
    @EnvironmentObject private var campus: CampusModel
    @Environment(\.dismiss) private var dismiss
    @State private var options: [PowerNode] = []
    @State private var meters: [Meter] = []
    @State private var path: [PowerNode] = []
    @State private var busy = false
    @State private var issue: String?
    @State private var search = ""
    var body: some View {
        List {
            AutomaticPowerSection()
            Section {
                LocationPathHeader(path:path.map(\.name))
                Text("电表与热水水控是独立绑定，核对宿舍后再保存。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if busy { Text("正在读取电表信息…").foregroundStyle(.secondary) }
            if let issue { Text(issue).foregroundStyle(.orange).font(.footnote) }
            Section(meters.isEmpty ? "选择位置" : "核对电表") {
                ForEach(options.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }, id:\.id) { option in
                    Button(option.name) { Task { await choose(option) } }.disabled(busy)
                }
                ForEach(meters, id:\.comAddress) { meter in
                    Button {
                        guard let building = path.last else { return }
                        Task {
                            do { try await campus.chooseMeter(nodeID:building.id, meter:meter, nodeIsRoom:true, path:path.map(\.name)); dismiss() }
                            catch { issue = "没保存上，再试一次。" }
                        }
                    } label: {
                        VStack(alignment:.leading,spacing:8) {
                            Text(meter.name).font(.headline)
                            Text("剩余 \(NSDecimalNumber(decimal:meter.remainingKWh ?? 0).stringValue) 度 · 电费 \(NSDecimalNumber(decimal:meter.leftMoney?.yuan ?? 0).stringValue) 元")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text("确认是我的宿舍并保存").font(.footnote)
                        }.padding(.vertical,8)
                    }.disabled(busy)
                }
            }
            if !path.isEmpty { Button("重新选择位置") { Task { await loadRoot() } }.disabled(busy) }
        }.scrollContentBackground(.hidden).background(NothingTheme.background).tint(NativeTheme.tint)
            .navigationTitle("绑定电表").navigationBarTitleDisplayMode(.inline)
            .searchable(text:$search,prompt:"搜索楼栋或宿舍")
            .task { await loadRoot() }
    }
    private func loadRoot() async {
        guard !busy, campus.configured else { issue = "先登录学校账号。"; return }
        busy = true; issue = nil; path = []; meters = []; search = ""
        defer { busy = false }
        do { options = try await campus.directory(parent:nil) }
        catch { issue = (error as? ServiceError)?.userMessage ?? "位置列表读取失败" }
    }
    private func choose(_ option: PowerNode) async {
        guard !busy, campus.configured else { return }
        busy = true; issue = nil; search = ""
        defer { busy = false }
        do {
            let children = try await campus.directory(parent:option.id)
            path.append(option); options = children
            if children.isEmpty {
                meters = try await campus.meterRows(nodeID:option.id)
                if meters.isEmpty { issue = "这里没有电表，重新选一下位置。" }
            }
        } catch { issue = (error as? ServiceError)?.userMessage ?? "电表没读到，再试一次。" }
    }
}

/// Same same-name choice as onboarding, on the meter settings page.
struct AutomaticPowerSection: View {
    @EnvironmentObject private var campus: CampusModel
    @State private var selection: String?
    var body: some View {
        if campus.matchingPower || !campus.powerChoices.isEmpty || campus.powerMatchIssue != nil || campus.powerConfigured {
            Section("电表") {
                if campus.matchingPower {Label("正在找电表，可以先保存宿舍。",systemImage:"bolt")}
                else if !campus.powerChoices.isEmpty {
                    LocationChoiceList(kind:.meter, choices:campus.powerChoices.map(\.choice), selection:$selection)
                    Button("就是这间") {
                        if let candidate = campus.powerChoices.first(where:{ $0.id == selection }) { campus.choosePower(candidate) }
                    }
                    .disabled(selection == nil)
                    .accessibilityIdentifier("powerApartmentConfirm")
                } else if campus.powerConfigured {Label("电表已保存",systemImage:"checkmark.circle").foregroundStyle(Theme.ink2)}
                if let issue = campus.powerMatchIssue {
                    Text(issue).font(.footnote).foregroundStyle(.secondary)
                    Button("再找一次电表") {campus.matchPowerAutomatically()}
                }
            }
        }
    }
}
