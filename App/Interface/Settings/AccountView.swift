import SwiftUI
import Core

/// 学校账号 detail (design §5): account, status, 保存密码, re-login, sign out.
struct AccountView: View {
    var preview: HomeData? = nil
    @EnvironmentObject private var campus: CampusModel
    @State private var confirmSignOut = false
    @State private var askPassword = false
    @State private var typedAccount = ""
    @State private var typedPassword = ""
    @State private var saving = false
    @State private var saveIssue: String?
    /// The typed account isn't the signed-in one: nothing saved, nobody switched (B2).
    @State private var differentAccount = false
    /// DEBUG demo: the switch flips locally (seeded from the demo data).
    @State private var previewSaved: Bool?
    private var signedIn: Bool { preview?.signedIn ?? campus.configured }
    private var dorm: String? { preview?.dorm ?? Theme.dorm(campus.room) }
    private var account: SchoolAccount? { preview != nil ? preview?.schoolAccount : campus.account }
    private var passwordSaved: Bool { preview != nil ? (previewSaved ?? preview?.passwordSaved ?? false) : campus.passwordSaved }
    private var passwordSwitch: Binding<Bool> {
        Binding(get:{ passwordSaved || askPassword || saving }, set:{ on in
            saveIssue = nil
            if on {
                typedAccount = ""; typedPassword = ""
                askPassword = true
            } else if preview != nil {
                previewSaved = false
            } else {
                Task { await campus.forgetPassword() }
            }
        })
    }

    var body: some View {
        List {
            Section {
                if let account { LabeledContent("账号") { Text(account.masked).monospacedDigit() } }
                LabeledContent("状态", value:signedIn ? "已登录" : "未登录")
                if signedIn, let dorm { LabeledContent("宿舍", value:dorm) }
            }.listRowBackground(Theme.group)
            if signedIn {
                Section {
                    Toggle(isOn:passwordSwitch) {
                        HStack(spacing:8) {
                            Text("保存密码").foregroundStyle(Theme.ink)
                            if saving { ProgressView() }
                        }
                    }
                    .tint(.green)
                    .disabled(saving)
                    .accessibilityIdentifier("savePasswordSwitch")
                } footer: {
                    VStack(alignment:.leading, spacing:6) {
                        if let saveIssue {
                            Label(saveIssue, systemImage:"exclamationmark.circle.fill").foregroundStyle(Theme.accentText)
                                .accessibilityIdentifier("savePasswordIssue")
                        }
                        Text(passwordSaved ? "小组件会自动刷新。关掉会删掉存着的密码。" : "不保存的话，过几个小时小组件就要打开 App 才能更新。")
                            .foregroundStyle(Theme.ink2)
                    }
                }.listRowBackground(Theme.group)
            }
            Section {
                NavigationLink(signedIn ? "重新登录学校账号" : "登录学校账号") { CampusOnboardingView() }
            } footer: {
                Text("密码只交给学校，不经过我们。").foregroundStyle(Theme.ink2)
            }.listRowBackground(Theme.group)
            if signedIn {
                Section {
                    Button("退出登录", role:.destructive) { confirmSignOut = true }
                        .frame(maxWidth:.infinity)
                        // Only while a password check is in flight. A running refresh is no reason:
                        // sign-out drops it (its late result is never written back).
                        .disabled(saving)
                }.listRowBackground(Theme.group)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("学校账号").navigationBarTitleDisplayMode(.inline)
        // Signed in on the web page: no account known, so the alert asks for both.
        .alert(account == nil ? "输入学校账号和密码" : "输入学校账号的密码", isPresented:$askPassword) {
            // Signed in on the web page: the account was never told to us, so ask for it too.
            if account == nil {
                TextField("账号", text:$typedAccount)
                    .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            SecureField("密码", text:$typedPassword).textContentType(.password)
            Button("取消", role:.cancel) { typedPassword = "" }
            Button("保存") { save() }
        } message: {
            Text("密码只存在这台 iPhone 的钥匙串里。")
        }
        .alert(SchoolLoginText.differentAccountTitle, isPresented:$differentAccount) {
            Button("好", role:.cancel) {}
        } message: {
            Text(SchoolLoginText.differentAccountMessage)
        }
        .confirmationDialog("退出学校账号？", isPresented:$confirmSignOut, titleVisibility:.visible) {
            // DEBUG demo data: the dialog shows, nothing is signed out.
            Button("退出登录", role:.destructive) { if preview == nil { campus.signOut() } }
            Button("取消", role:.cancel) {}
        } message: {
            Text("首页的电量和余额会清空，热水记录和洗衣设置都还在。")
        }
    }

    /// One login checks the password before it is kept; never retried.
    private func save() {
        let password = typedPassword, name = typedAccount.trimmingCharacters(in:.whitespaces)
        let askedAccount = account == nil
        typedPassword = ""
        guard !password.isEmpty else { return }
        if preview != nil { previewSaved = true; return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await campus.savePassword(password, account:account == nil ? name : nil)
            } catch SchoolLoginFailure.wrongCredentials {
                saveIssue = askedAccount ? "账号或密码不对，没保存。" : "密码不对，没保存。"
            } catch SchoolLoginFailure.differentAccount {
                differentAccount = true
            } catch {
                saveIssue = SchoolLoginText.text(error)
            }
        }
    }
}
