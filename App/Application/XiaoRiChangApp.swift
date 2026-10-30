import SwiftUI
import UniformTypeIdentifiers
import Core

@main struct XiaoRiChangApp: App {
    @StateObject private var water = ShowerModel.shared
    @StateObject private var campus = CampusModel.shared
    @StateObject private var laundry = LaundryModel()
    init() {
        // FinishShowerLiveIntent (Live Activity button) runs in this process.
        ShowerActivityBridge.finish = { try await ShowerModel.shared.run(start:false) }
        // Notification delegate must be set before launch finishes, so a tapped banner is routed.
        _ = Reminders.shared
    }
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            CampusRootView().environmentObject(water).environmentObject(campus).environmentObject(laundry)
                .onChange(of:campus.room,initial:true) { ShowerActivityController.shared.dorm = Theme.dorm(campus.room) ?? "" }
                .task {
                    campus.matchPowerAutomatically()
                    await campus.refresh()
                    await laundry.refresh()
                }
                .onOpenURL { if $0.scheme != "campusdaily" { AlipayBridge.shared.handle($0); Task { await laundry.refreshOrder() } } }
        }
        .onChange(of:phase) { _, value in
            if value == .background { Reminders.scheduleRefresh() }
            if value == .active {
                Task { await Reminders.shared.refreshAuthorization() }
                // Back from Alipay without a callback URL (checkout links): read the order.
                Task { await laundry.refreshOrder() }
            }
        }
        // Background campus read: low power / card reminders (§5) and a fresh widget.
        .backgroundTask(.appRefresh(Reminders.refreshTask)) {
            Reminders.scheduleRefresh()
            await CampusModel.shared.refresh(force:true, inBackground:true)
        }
    }
}

struct ShowerDetail: View {
    @EnvironmentObject private var water: ShowerModel
    @EnvironmentObject private var campus: CampusModel
    @State private var confirmResolve = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                // Large text: stack instead of squeezing both sides into narrow wrapped columns.
                ViewThatFits(in:.horizontal) {
                    HStack { Text("宿舍热水").fixedSize(); Spacer(); Text(campus.room).fixedSize() }
                    VStack(alignment:.leading,spacing:4) { Text("宿舍热水"); Text(campus.room) }
                }.font(.subheadline).foregroundStyle(.secondary)
                VStack(alignment:.leading,spacing:13) {
                    HStack(spacing:9) {
                        if water.busy { ProgressView().controlSize(.small) }
                        else { Circle().fill(water.problem ? Color.orange : NativeTheme.tint).frame(width:7,height:7).accessibilityHidden(true) }
                        Text(headline).font(.title2.bold()).accessibilityIdentifier("waterHeadline")
                    }
                    Text(water.inspecting ? "正在只读核对附近水控，不会出水。" : water.status).font(.subheadline).foregroundStyle(water.problem ? Color.orange : Color.secondary)
                        .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("waterStatus")
                }
                ViewThatFits(in:.horizontal) {
                    HStack {
                        Text("本次费用").foregroundStyle(.secondary).fixedSize()
                        Spacer()
                        cost.fixedSize()
                    }
                    VStack(alignment:.leading,spacing:6) {
                        Text("本次费用").foregroundStyle(.secondary)
                        cost
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.padding(18).background(NativeTheme.surface,in:RoundedRectangle(cornerRadius:16))
                if let ended = water.lastEnded {
                    VStack(alignment:.leading,spacing:14) {
                        Text("最近一次用水").font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            VStack(alignment:.leading,spacing:6) {
                                Text("已结算").font(.subheadline)
                                Text(ended.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let cost = water.lastCost { Text(cost,format:.currency(code:"CNY")).font(.subheadline).monospacedDigit() }
                        }
                    }.padding(18).background(NativeTheme.surface,in:RoundedRectangle(cornerRadius:16))
                }
                if water.mayResolveManually {
                    // Way out of a record that can't close by itself; only after the user checked the official record.
                    Button("我在学校记录里核对过了") { confirmResolve = true }
                        .font(.subheadline).frame(minHeight:44).accessibilityIdentifier("resolveWaterManually")
                        .confirmationDialog("这次洗澡核对过了吗？", isPresented:$confirmResolve, titleVisibility:.visible) {
                            Button("核对过了") { Task { await water.resolveManually() } }
                            Button("取消", role:.cancel) {}
                        } message: {
                            Text("标记以后，校日常不会再结算这一次。先在学校的热水记录里找到这次洗澡，再点核对过了。")
                        }
                }
                if !water.configured {
                    NavigationLink("设置校园账号与宿舍") { CampusOnboardingView() }.frame(minHeight:44)
                }
                if water.configured {
                    NavigationLink("连接检查与水控信息") { AdvancedSettingsView() }.font(.subheadline).frame(minHeight:44)
                }
            }.padding(20).frame(maxWidth:560).frame(maxWidth:.infinity)
        }.background(NativeTheme.background)
            .navigationTitle("热水洗澡").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge:.bottom) {
                VStack(spacing:10) {
                    Button { perform(start:!closing) } label: {
                        HStack {
                            if water.busy { ProgressView().tint(Theme.pillInk).controlSize(.small) }
                            Text(water.busy ? "正在处理…" : closing ? "结束并结算" : "开始洗澡")
                            Spacer(); Image(systemName:closing ? "stop.circle" : "arrow.up.right")
                        }.padding(.horizontal,18).frame(minHeight:52)
                    }.buttonStyle(ShowerButtonStyle(primary:true,accent:NativeTheme.tint))
                        .disabled(closing ? !water.mayFinish : !water.mayStart)
                        .accessibilityIdentifier(closing ? "finishWater" : "startWater")
                    Text(closing ? "结算完成前，先别离开水控。" : "授权后，按水控上的出水键。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(.horizontal,20).padding(.top,12).padding(.bottom,12).background(NativeTheme.background)
            }
    }
    @ViewBuilder private var cost: some View {
        if water.state.phase == .done, let cost = water.lastCost {
            Text(cost,format:.currency(code:"CNY")).font(.title2.weight(.semibold)).monospacedDigit().accessibilityIdentifier("settlementCost")
        } else if water.state.phase == .done {
            Text("没拿到金额").font(.subheadline).foregroundStyle(.secondary)
        } else { Text("结算后显示").font(.subheadline) }
    }
    private var closing: Bool { water.state.canFinish }
    private var headline: String {
        if water.inspecting { return "正在核对水控" }
        if water.busy { return "正在处理" }
        if water.problem { return "本次待核对" }
        if !water.configured { return "尚未配置热水" }
        switch water.state.phase {
        case .running, .writePending: return "热水已授权"
        case .done: return "结算完成"
        case .idle: return "准备洗澡"
        default: return "当前记录待核对"
        }
    }
    private func perform(start:Bool) { Task { try? await water.run(start:start) } }
}

struct ShowerButtonStyle: ButtonStyle {
    let primary: Bool
    let accent: Color
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold))
            .foregroundStyle(primary ? Theme.pillInk : accent)
            .background(primary ? NativeTheme.action : NativeTheme.tint.opacity(0.10),in:RoundedRectangle(cornerRadius:12))
            .opacity(enabled ? (configuration.isPressed ? 0.76 : 1) : 0.4)
    }
}
