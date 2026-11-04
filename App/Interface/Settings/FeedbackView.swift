import PhotosUI
import SwiftUI
import Core

/// 反馈问题: a sheet with the text, up to four screenshots the person picks (none by default),
/// 取消 and 发送. A failed send shows one fixed line, never the service's words.
struct FeedbackView: View {
    let endpoint: FeedbackEndpoint
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var images: [UIImage] = []
    @State private var sending = false
    @State private var failure: String?
    @State private var sent = false

    private var issue: FeedbackDraft.Issue? { FeedbackDraft.issue(message:message, imageCount:images.count) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("遇到了什么问题，或者想要什么功能？", text:$message, axis:.vertical)
                        .lineLimit(5 ... 12)
                        .accessibilityIdentifier("feedbackText")
                } footer: {
                    if let line = FeedbackText.issue(issue) {
                        Text(line).foregroundStyle(Theme.redText).accessibilityIdentifier("feedbackTooLong")
                    }
                }
                Section {
                    if !images.isEmpty { thumbnails }
                    PhotosPicker(selection:$pickerItems,
                                 maxSelectionCount:max(1, FeedbackDraft.maximumImages - images.count),
                                 matching:.images) {
                        Label("添加截图", systemImage:"photo.on.rectangle")
                    }
                    .disabled(sending || images.count >= FeedbackDraft.maximumImages)
                    .accessibilityIdentifier("feedbackAddScreenshot")
                } footer: {
                    Text("最多 4 张。会附上 App 版本、手机型号和系统版本，不带账号和余额。")
                }
                if let failure {
                    Section {
                        Label(failure, systemImage:"exclamationmark.circle.fill")
                            .foregroundStyle(Theme.redText)
                            .accessibilityIdentifier("feedbackFailure")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(NativeTheme.background.ignoresSafeArea())
            .navigationTitle("反馈问题").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) {
                    Button("取消") { dismiss() }.disabled(sending)
                }
                ToolbarItem(placement:.confirmationAction) {
                    Button(sending ? "正在发送…" : "发送") { send() }
                        .fontWeight(.semibold)
                        .disabled(sending || issue != nil)
                        .accessibilityIdentifier("feedbackSend")
                }
            }
            .onChange(of:pickerItems) { _, items in
                Task { await load(items) }
            }
            .alert("发出去了", isPresented:$sent) {
                Button("好") { dismiss() }
            } message: {
                Text("谢谢反馈。")
            }
        }
        .tint(NativeTheme.tint)
        .typesettingLanguage(Theme.typesetting)
        .interactiveDismissDisabled(sending)
    }

    private var thumbnails: some View {
        ScrollView(.horizontal) {
            HStack(spacing:8) {
                ForEach(images.indices, id:\.self) { index in
                    Image(uiImage:images[index])
                        .resizable()
                        .scaledToFill()
                        .frame(width:72, height:72)
                        .clipShape(RoundedRectangle(cornerRadius:8))
                        .overlay(alignment:.topTrailing) {
                            Button {
                                images.remove(at:index)
                            } label: {
                                Image(systemName:"xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .padding(4)
                            .disabled(sending)
                            .accessibilityLabel("删掉这张截图")
                        }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func load(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        for item in items {
            guard images.count < FeedbackDraft.maximumImages,
                  let data = try? await item.loadTransferable(type:Data.self),
                  let image = UIImage(data:data)
            else { continue }
            images.append(image)
        }
        pickerItems = []
    }

    private func send() {
        sending = true
        failure = nil
        Task {
            do {
                try await FeedbackReporter.send(message:message, images:images, to:endpoint)
                sent = true
            } catch {
                failure = FeedbackText.failure(error)
            }
            sending = false
        }
    }
}
