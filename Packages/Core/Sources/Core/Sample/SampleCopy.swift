import Foundation

/// The sample mode's copy: its entry on the login step, the bar over every page while it is on,
/// and the one message every blocked action shows.
public enum SampleCopy {
    /// The login step's second entry, under 用学校网页登录.
    public static let entry = "先看看示例"
    /// Under the entry while it is shut (`LiveShowerGate`), one line for every reason (a real
    /// shower not over, waiting for its check, or its record not read); VoiceOver reads it after
    /// the entry's label.
    public static let entryRefused = "有一次洗澡还没结完，结完就能看示例。"
    /// The bar's text, on its left.
    public static let barText = "示例数据，不是你的账号"
    /// The bar's button: leaves the sample, back to the login step.
    public static let barAction = "去登录"
    /// VoiceOver reads the bar as one element with the button as its action.
    public static let barSpoken = barText + "。" + barAction
    /// What a blocked action (money, Bluetooth, binding, sending, resetting) says instead.
    public static let blocked = "示例里不能操作，登录学校账号后就能用。"
}
