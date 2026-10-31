import Foundation

/// Words on the meter page (home 电量 › 电表, Settings). Only there: the same failures read as
/// `ServiceError.userMessage` everywhere else.
public enum MeterPageText {
    public static let title = "电表"
    /// Above the picker, before anything is chosen.
    public static let pickerPrompt = "找不到的话，自己选一下"
    /// The school took too long (the lookup or a picker read).
    public static let tooSlow = "学校那边太慢了，等一下再找。"

    /// The page's wording for an issue that reads `ServiceError.userMessage` elsewhere.
    public static func issue(_ text: String) -> String {
        text == ServiceError.timedOut.userMessage ? tooSlow : text
    }

    /// A picker read that failed: a `ServiceError` in the page's words, anything else `otherwise`.
    public static func issue(_ error: Error, otherwise: String) -> String {
        (error as? ServiceError).map { issue($0.userMessage) } ?? otherwise
    }
}
