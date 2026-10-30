import SwiftUI
import UniformTypeIdentifiers
import WaterCore

/// Settings sheet (design §6, copy-r1 「设置」).
struct SettingsView: View {
    /// DEBUG demo data; nil = live models.
    var preview: HomeData? = nil
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var water: WaterModel
    @EnvironmentObject private var campus: CampusModel
    @EnvironmentObject private var laundry: LaundryModel
    @AppStorage(ReminderKey.powerLow) private var powerAlert = true
    @AppStorage(ReminderKey.cardLow) private var cardAlert = true
    @AppStorage(ReminderKey.unsettledMinutes) private var unsettledMinutes = 30
    @AppStorage(ReminderKey.laundryDone) private var laundryAlert = true
    @AppStorage(ReminderKey.powerLine) private var powerLine = 10
    @AppStorage(ReminderKey.cardLine) private var cardLine = 20
    @ObservedObject private var reminders = Reminders.shared
    @Environment(\.openURL) private var openURL

    private var data: HomeData { preview ?? HomeData(campus:campus, water:water, laundry:laundry) }

    var body: some View {
        let data = data
        NavigationStack {
            reminderHandlers(List {
                Section("我的") {
                    NavigationLink { AccountView(preview:preview) } label: {
                        SettingsRow(emoji:"🎓", title:"学校账号", value:data.signedIn ? "已登录" : "去登录")
                    }
                    NavigationLink { CampusOnboardingView() } label: {
                        SettingsRow(emoji:"🏠", title:"宿舍", value:data.dorm ?? "去设置")
                    }
                }.listRowBackground(Theme.group)
                Section("设备") {
                    if data.water == .unconfigured {
                        // Hot water is set up by choosing the dorm (controller binding), not by a file.
                        NavigationLink { CampusOnboardingView() } label: {
                            SettingsRow(emoji:"🚿", title:"热水", value:"未选")
                        }
                    } else {
                        NavigationLink { WaterDetail() } label: {
                            SettingsRow(emoji:"🚿", title:"热水", value:"已导入")
                        }
                    }
                    NavigationLink { WasherSetupView() } label: {
                        SettingsRow(emoji:"🧺", title:"常用洗衣机",
                                    value:data.laundryBound ? (data.laundryMachine.map { "\($0) 号机" } ?? "已绑定") : "去设置")
                    }
                    NavigationLink { CampusPowerSetupView() } label: {
                        SettingsRow(emoji:"⚡", title:"电表", value:data.powerBound ? "已绑定" : "去绑定")
                    }
                }.listRowBackground(Theme.group)
                reminderSection
                Section {
                    NavigationLink { AdvancedSettingsView() } label: {
                        SettingsRow(emoji:"🛠️", title:"高级")
                    }
                } footer: {
                    Text("校日常 · 非学校官方应用")
                        .scaledFont(12, relativeTo:.caption).multilineTextAlignment(.center).foregroundStyle(Theme.ink2)
                        .frame(maxWidth:.infinity).padding(.top,10)
                }.listRowBackground(Theme.group)
            })
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.confirmationAction) {
                    Button { dismiss() } label: { Text("完成").fontWeight(.semibold).foregroundStyle(Theme.accentText) }
                }
            }
            .waterDevicePicker()
        }
        .tint(Theme.accentText)
        .presentationDetents([.large])
    }
}

extension SettingsView {
    /// 提醒 (design-r2 §6). With system notifications off: switches off and disabled, plus a row to Settings.
    @ViewBuilder var reminderSection: some View {
        let off = reminders.denied
        Section {
            Toggle(isOn:off ? .constant(false) : $powerAlert) {
                lineLabel("电量低于", value:$powerLine, choices:[5, 10, 15, 20, 30], unit:" 度", off:off)
            }.disabled(off)
            Toggle(isOn:off ? .constant(false) : $cardAlert) {
                lineLabel("校园卡低于", value:$cardLine, choices:[10, 20, 30, 50], unit:" 元", off:off)
            }.disabled(off)
            if off {
                // A disabled navigation-link Picker is dimmed by the system on top of ink2, so it read lighter
                // than the three switches. Off: a static row in the same ink2 as their labels.
                HStack {
                    Text("洗完没结算").foregroundStyle(Theme.ink2)
                    Spacer()
                    Text(unsettledMinutes > 0 ? "\(unsettledMinutes) 分钟后" : "不提醒").foregroundStyle(Theme.ink2)
                    Image(systemName:"chevron.right").font(.system(size:13, weight:.semibold)).foregroundStyle(Theme.ink3)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children:.combine)
            } else {
                Picker(selection:$unsettledMinutes) {
                    ForEach([15, 30, 60], id:\.self) { Text("\($0) 分钟后").tag($0) }
                    Text("不提醒").tag(0)
                } label: { Text("洗完没结算").foregroundStyle(Theme.ink) }
                .pickerStyle(.navigationLink)
            }
            Toggle(isOn:off ? .constant(false) : $laundryAlert) {
                Text("洗衣洗好时").foregroundStyle(off ? Theme.ink2 : Theme.ink)
            }.disabled(off)
            if off {
                actionRow("去系统设置打开通知") {
                    if let url = URL(string:UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            } else if reminders.notAsked {
                // Not asked yet: the switches read on; this row explains and asks. Gone once the system has asked.
                actionRow("打开提醒") { reminders.showPrompt(from:.settings) }
            }
        } header: {
            Text("提醒")
        } footer: {
            Text(off ? "系统通知关着，这里的开关暂时不起作用。" : "电快没了、衣服洗好了，校日常会提醒你。")
                .scaledFont(13, relativeTo:.footnote).foregroundStyle(Theme.ink2)
        }
        .tint(.green)
        .listRowBackground(Theme.group)
    }
    /// Applied to the List, not the Section: Section modifiers are copied onto every row, which ran each
    /// handler once per row and stacked one permission sheet per row (dismissing settings).
    func reminderHandlers(_ list: some View) -> some View {
        list
            .onChange(of:powerAlert) { old, new in switchedOn(old, new); reminders.reevaluateCampus() }
            .onChange(of:cardAlert) { old, new in switchedOn(old, new); reminders.reevaluateCampus() }
            .onChange(of:laundryAlert) { old, new in switchedOn(old, new); reminders.resync() }
            .onChange(of:unsettledMinutes) { _, _ in reminders.resync() }
            .onChange(of:powerLine) { _, _ in reminders.shareLines(); reminders.reevaluateCampus() }
            .onChange(of:cardLine) { _, _ in reminders.shareLines(); reminders.reevaluateCampus() }
            .sheet(item:reminders.promptBinding(.settings)) { _ in
                ReminderPermissionSheet()
            }
    }
    /// Accent title + chevron (「去系统设置打开通知」/「打开提醒」).
    private func actionRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action:action) {
            HStack {
                Text(title).foregroundStyle(Theme.accentText)
                Spacer()
                Image(systemName:"chevron.right").font(.system(size:13, weight:.semibold)).foregroundStyle(Theme.ink3)
                    .accessibilityHidden(true)
            }
        }
    }
    /// 「电量低于 10 度」: the number opens a menu of lines (shared with home and the widget).
    private func lineLabel(_ lead: String, value: Binding<Int>, choices: [Int], unit: String, off: Bool) -> some View {
        HStack(spacing:4) {
            Text(lead).foregroundStyle(off ? Theme.ink2 : Theme.ink)
            Menu {
                Picker(lead, selection:value) { ForEach(choices, id:\.self) { Text("\($0)" + unit).tag($0) } }
            } label: {
                HStack(spacing:2) {
                    Text("\(value.wrappedValue)" + unit)
                    Image(systemName:"chevron.up.chevron.down").font(.system(size:11, weight:.semibold)).accessibilityHidden(true)
                }
                .foregroundStyle(off ? Theme.ink2 : Theme.accentText)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(lead + " \(value.wrappedValue)" + unit)
        }
    }
    /// First time a reminder is switched on while the system hasn't been asked yet (§7).
    private func switchedOn(_ old: Bool, _ new: Bool) {
        if !old && new { reminders.maybePrompt(from:.settings) }
    }
}

/// Emoji (17pt in a 24pt frame) · title · value in ink2.
struct SettingsRow: View {
    let emoji: String
    let title: String
    var value: String? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(spacing:12) {
            Text(emoji).scaledFont(17).frame(minWidth:24).fixedSize().accessibilityHidden(true)
            if typeSize.isAccessibilitySize {
                // Large text: value goes under the title instead of being truncated.
                VStack(alignment:.leading, spacing:2) {
                    titleText
                    if let value { Text(value).foregroundStyle(Theme.ink2) }
                }
                Spacer(minLength:0)
            } else {
                titleText
                Spacer(minLength:8)
                if let value { Text(value).foregroundStyle(Theme.ink2).lineLimit(1).minimumScaleFactor(0.8) }
            }
        }
        .accessibilityElement(children:.combine)
    }
    private var titleText: some View {
        Text(title).foregroundStyle(Theme.ink)
            // Separator starts under the title, not the emoji.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
}

/// 学校账号 detail: status, re-login, sign out.
struct AccountView: View {
    var preview: HomeData? = nil
    @EnvironmentObject private var campus: CampusModel
    @State private var confirmSignOut = false
    private var signedIn: Bool { preview?.signedIn ?? campus.configured }
    private var dorm: String? { preview?.dorm ?? Theme.dorm(campus.room) }
    var body: some View {
        List {
            Section {
                LabeledContent("状态", value:signedIn ? "已登录" : "未登录")
                if signedIn, let dorm { LabeledContent("宿舍", value:dorm) }
            }.listRowBackground(Theme.group)
            Section {
                NavigationLink(signedIn ? "重新登录学校账号" : "登录学校账号") { CampusOnboardingView() }
            } footer: {
                Text("密码只交给学校，不经过我们").foregroundStyle(Theme.ink2)
            }.listRowBackground(Theme.group)
            if signedIn {
                Section {
                    Button("退出登录", role:.destructive) { confirmSignOut = true }
                        .frame(maxWidth:.infinity)
                        .disabled(preview != nil || campus.loading)
                }.listRowBackground(Theme.group)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("学校账号").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("退出学校账号？", isPresented:$confirmSignOut, titleVisibility:.visible) {
            Button("退出登录", role:.destructive) { campus.signOut() }
            Button("取消", role:.cancel) {}
        } message: {
            Text("首页的电量和余额会清空，热水记录和洗衣设置都还在。")
        }
    }
}

/// Plain ink title + system-style chevron (actions that aren't NavigationLinks).
private struct ChevronRow: View {
    let title: String
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack {
            Text(title).foregroundStyle(Theme.ink)
            Spacer()
            Image(systemName:"chevron.right").font(.system(size:13, weight:.semibold)).foregroundStyle(Theme.ink3)
                .accessibilityHidden(true)
        }
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Rectangle())
    }
}

private enum ConfigImport { case water, campus, laundry }

/// 高级: config imports, Bluetooth connection check, Shortcuts hint, version.
struct AdvancedSettingsView: View {
    @EnvironmentObject private var water: WaterModel
    @EnvironmentObject private var campus: CampusModel
    @EnvironmentObject private var laundry: LaundryModel
    @State private var importing = false
    @State private var importKind = ConfigImport.campus
    /// Last import failure, shown under the import rows (the models' own issue lines live elsewhere).
    @State private var importIssue: String?
    private var version: String { (Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—") + " · 内测" }
    private func importRow(_ title: String, _ kind: ConfigImport) -> some View {
        Button { importKind = kind; importing = true } label: { ChevronRow(title:title) }
    }
    var body: some View {
        List {
            Section {
                importRow("导入校园卡配置", .campus).disabled(campus.loading)
                importRow("导入热水配置", .water).disabled(!water.mayImport)
                importRow("导入洗衣配置", .laundry).disabled(!laundry.mayImport)
            } header: { Text("导入配置") } footer: {
                VStack(alignment:.leading, spacing:6) {
                    if let importIssue {
                        Label(importIssue, systemImage:"exclamationmark.circle").foregroundStyle(Theme.ink2)
                            .accessibilityIdentifier("importIssue")
                    }
                    Text("通常无需导入文件。有未结算记录时请勿卸载或更换配置。操作未确认时，先核对现场及官方记录。")
                }
            }.listRowBackground(Theme.group)
            Section {
                if water.configured {
                    Button { Task { await water.inspectBluetooth() } } label: {
                        Label(water.inspecting ? "正在核对…" : "扫描并核对本宿舍水控", systemImage:"antenna.radiowaves.left.and.right")
                    }.disabled(!water.mayImport).accessibilityIdentifier("inspectWaterBluetooth")
                    if let message = water.inspectionStatus {
                        Text(message).font(.subheadline).foregroundStyle(Theme.ink2).accessibilityIdentifier("waterInspectionStatus")
                    }
                    if let device = water.verifiedDevice {
                        LabeledContent("设备名称", value:device.name)
                        LabeledContent("水控编号", value:device.machineID).accessibilityIdentifier("verifiedWaterMachine")
                        if let rssi = device.rssi { LabeledContent("本次信号", value:"\(rssi) dBm") }
                        VStack(alignment:.leading, spacing:4) {
                            Text("设备标识 " + String(device.id.prefix(8)) + "…")
                            Text("发现 \(device.nearbyCount) 台同名设备，已按宿舍水控编号匹配。")
                            Text("核对于 " + device.verifiedAt.formatted(date:.omitted, time:.standard))
                        }.font(.caption).foregroundStyle(Theme.ink2)
                    }
                } else {
                    Text("导入热水配置后可以检查").foregroundStyle(Theme.ink2)
                }
            } header: { Text("连接检查") } footer: {
                Text("只读取设备编号，不会出水。核对后会断开，开始洗澡时再连接。")
            }.listRowBackground(Theme.group)
            Section {
                Link(destination:URL(string:"shortcuts://")!) { ChevronRow(title:"快捷指令") }
            } footer: {
                Text("在“快捷指令” App 里搜“校日常”，就能把“开始洗澡”和“结束并结算”加到主屏幕或操作按钮上。")
            }.listRowBackground(Theme.group)
            Section {
                LabeledContent("版本", value:version)
            }.listRowBackground(Theme.group)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("高级").navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented:$importing, allowedContentTypes:[.json, .data]) { result in
            importIssue = nil
            do {
                let url = try result.get()
                switch importKind {
                case .water: try water.importConfig(url)
                case .campus: try campus.importConfig(url); Task { await campus.refresh(force:true) }
                case .laundry: try laundry.importConfig(url); Task { await laundry.refresh(force:true) }
                }
            } catch {
                if (error as? CocoaError)?.code == .userCancelled { return }
                let fallback: String
                switch importKind {
                case .water: fallback = "这个文件导入不了，确认是热水配置文件再试。"
                case .campus: fallback = "这个文件导入不了，确认是校园卡配置文件再试。"
                case .laundry: fallback = "这个文件导入不了，确认是洗衣配置文件再试。"
                }
                importIssue = (error as? LocalizedError)?.errorDescription ?? fallback
                switch importKind {
                case .water: water.show(error)
                case .campus: campus.importFailed(error)
                case .laundry: laundry.importFailed()
                }
            }
        }
    }
}
