import SwiftUI
import Core

/// Settings sheet.
struct SettingsView: View {
    #if DEBUG
    /// DEBUG demo data; nil = live models.
    var preview: HomeData? = nil
    /// DEBUG demo: the switch flips locally (seeded from the demo data).
    @State private var previewLaundry: Bool?
    private var account: AccountView { AccountView(preview:preview) }
    private var advanced: AdvancedSettingsView { AdvancedSettingsView(preview:preview) }
    private var themePage: ThemeSettingsView { ThemeSettingsView(preview:preview) }
    #else
    private var preview: HomeData? { nil }
    private var previewLaundry: Bool? { get { nil } nonmutating set {} }
    private var account: AccountView { AccountView() }
    private var advanced: AdvancedSettingsView { AdvancedSettingsView() }
    private var themePage: ThemeSettingsView { ThemeSettingsView() }
    #endif
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var shower: ShowerModel
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

    private var data: HomeData { preview ?? HomeData(campus:campus, shower:shower, laundry:laundry) }
    /// 「去设置热水」 after an account switch.
    @State private var hotWaterSetup = false
    /// 学校账号, pushed when the widget asked for it.
    @State private var accountPage = false
    /// 主题, pushed by a DEBUG demo.
    @State private var themePageShown = false

    /// 「学校洗衣机」 switch.
    var laundryOn: Bool { preview != nil ? (previewLaundry ?? preview?.laundryEnabled ?? true) : laundry.schoolEnabled }
    private var laundryLocked: Bool { preview?.laundryLocked ?? laundry.schoolSwitchLocked }
    private var laundrySwitch: Binding<Bool> {
        Binding(get:{ laundryOn }, set:{ on in
            // Default List insert/delete animation for 「常用洗衣机」 and 「洗衣洗好时」.
            withAnimation {
                if preview != nil { previewLaundry = on } else { laundry.setSchoolEnabled(on) }
            }
        })
    }

    var body: some View {
        let data = data
        NavigationStack {
            reminderHandlers(List {
                Section("我的") {
                    NavigationLink { account } label: {
                        SettingsRow(symbol:"graduationcap", title:"学校账号", value:AccountText.row(signedIn:data.signedIn, account:data.schoolAccount))
                    }
                    NavigationLink { CampusOnboardingView() } label: {
                        // Full location under the title; 「去设置」 until there is one.
                        if let location = data.dormLocation { SettingsRow(symbol:"house", title:"宿舍", detail:location) }
                        else { SettingsRow(symbol:"house", title:"宿舍", value:data.dorm ?? "去设置") }
                    }
                }.listRowBackground(Theme.group)
                // 电表, 热水, 学校洗衣机, 常用洗衣机; the 学校洗衣机 footnote stays under the group.
                Section {
                    NavigationLink { CampusPowerSetupView() } label: {
                        if data.powerBound, let location = data.meterLocation { SettingsRow(symbol:"bolt", title:"电表", detail:location) }
                        else { SettingsRow(symbol:"bolt", title:"电表", value:data.powerBound ? "已绑定" : "去绑定") }
                    }
                    if data.shower == .unconfigured {
                        // Hot water is set up by choosing the dorm (controller binding), not by a file.
                        NavigationLink { CampusOnboardingView() } label: {
                            SettingsRow(symbol:"shower", title:"热水", value:"未选")
                        }
                    } else {
                        NavigationLink { ShowerDetail() } label: {
                            SettingsRow(symbol:"shower", title:"热水", value:"已导入")
                        }
                    }
                    Toggle(isOn:laundrySwitch) {
                        SettingsRow(symbol:"washer", title:SchoolLaundryPreference.title)
                    }
                    .tint(.green)
                    .disabled(laundryLocked)
                    .accessibilityIdentifier("schoolLaundrySwitch")
                    if laundryOn {
                        NavigationLink { WasherSetupView() } label: {
                            // No icon: the title lines up with 「学校洗衣机」 above.
                            SettingsRow(symbol:nil, title:"常用洗衣机",
                                        value:data.laundryBound ? (data.laundryMachine.map { "\($0) 号机" } ?? "已绑定") : "去设置")
                        }
                    }
                } header: {
                    Text("设备")
                } footer: {
                    Text(SchoolLaundryPreference.footer(isOn:laundryOn, locked:laundryLocked))
                        .scaledFont(13, relativeTo:.footnote).foregroundStyle(Theme.ink2)
                }.listRowBackground(Theme.group)
                reminderSection
                Section("外观") {
                    NavigationLink { themePage } label: {
                        SettingsRow(symbol:"paintpalette", title:"主题", value:Theme.current.name)
                    }
                    .accessibilityLabel(Theme.current.settingsRowLabel)
                    .accessibilityIdentifier("themeRow")
                }.listRowBackground(Theme.group)
                Section {
                    NavigationLink { advanced } label: {
                        SettingsRow(symbol:"wrench.and.screwdriver", title:"高级")
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
            .navigationDestination(isPresented:$hotWaterSetup) {
                if shower.configured { ShowerDetail() } else { CampusOnboardingView() }
            }
            .navigationDestination(isPresented:$accountPage) { account }
            .navigationDestination(isPresented:$themePageShown) { themePage }
            .onAppear {
                if preview == nil { campus.reloadAccount() }
                if campus.hotWaterSetupRequested { campus.hotWaterSetupRequested = false; hotWaterSetup = true }
                if preview?.themePageShown == true { themePageShown = true }
                openAccountPageIfRequested()
            }
            .onChange(of:campus.accountPageRequested) { _, _ in openAccountPageIfRequested() }
        }
        .tint(Theme.accentText)
        // On the stack, not its root: pushing a page must not hand the alert to the screen below.
        .accountSwitchAlert { hotWaterSetup = true }
        .presentationDetents([.large])
    }
}

extension SettingsView {
    func openAccountPageIfRequested() {
        guard campus.accountPageRequested else { return }
        campus.accountPageRequested = false
        accountPage = true
    }

    /// 提醒. With system notifications off: switches off and disabled, plus a row to Settings.
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
                    Text("洗完澡没结算").foregroundStyle(Theme.ink2)
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
                } label: { Text("洗完澡没结算").foregroundStyle(Theme.ink) }
                .pickerStyle(.navigationLink)
            }
            if laundryOn {
                // Hidden with 学校洗衣机 off; its value is kept.
                Toggle(isOn:off ? .constant(false) : $laundryAlert) {
                    Text("洗衣洗好时").foregroundStyle(off ? Theme.ink2 : Theme.ink)
                }.disabled(off)
            }
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
            Text(off ? "系统通知关着，这里的开关暂时不起作用。" : (laundryOn ? "电快没了、衣服洗好了，校日常会提醒你。" : "电快没了、校园卡钱不多了，校日常会提醒你。"))
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
    /// First time a reminder is switched on while the system hasn't been asked yet.
    private func switchedOn(_ old: Bool, _ new: Bool) {
        if !old && new { reminders.maybePrompt(from:.settings) }
    }
}

/// Icon (`RowIcon`, 20pt in a 26pt column) · title · value in ink2.
struct SettingsRow: View {
    /// SF Symbol name; nil keeps the column empty (a sub-row aligned with the row above).
    let symbol: String?
    let title: String
    var value: String? = nil
    /// Second line under the title (a full location), 13 ink2, wraps; replaces `value`.
    var detail: String? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo:.title3) private var iconColumn: CGFloat = 26
    var body: some View {
        HStack(spacing:12) {
            Group { if let symbol { RowIcon(symbol:symbol) } else { Color.clear.frame(height:1) } }
                .frame(width:iconColumn)
            if let detail {
                VStack(alignment:.leading, spacing:2) {
                    titleText
                    Text(detail).scaledFont(13, relativeTo:.footnote).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal:false, vertical:true)
                        .accessibilityLabel(detail.replacingOccurrences(of:" · ", with:"，"))
                }
                .frame(minHeight:62, alignment:.leading)
                Spacer(minLength:0)
            } else if typeSize.isAccessibilitySize {
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
            // Separator starts under the title, not the icon.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
}

/// Plain ink title + system-style chevron (actions that aren't NavigationLinks).
struct ChevronRow: View {
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
