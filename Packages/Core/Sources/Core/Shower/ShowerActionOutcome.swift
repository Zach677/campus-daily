import Foundation

/// What 开始洗澡 / 结束并结算 came to, for the callers that speak instead of showing the page:
/// Siri, Shortcuts and the Live Activity button. A start the controller did not confirm is
/// not called confirmed, and anything that did not go through carries its real reason.
public enum ShowerActionOutcome: Sendable, Equatable {
    /// The controller confirmed the authorization.
    case started
    /// The authorization was written but the controller did not confirm it (`writePending`).
    case startUnconfirmed
    /// The end was closed and settled (the amount is on the record's receipt).
    case settled

    public static let startedText = "水控连上了，按出水键开水。"
    public static let startUnconfirmedText = "\(ShowerDisplay.writeUnconfirmedHint)。打开校日常能看到计时。"
    public static let endNotSentText = "这次没能结束，打开校日常再试一次。"

    /// `result`: the record after the engine's start or finish. `notice`: the text of its notice
    /// (a device error, a busy controller…), preferred to the record's own title.
    public static func after(start: Bool, _ result: ShowerState, notice: String?) -> Result<ShowerActionOutcome, ShowerActionFailure> {
        if result.phase == .failed {
            if result.failure?.reason == .deviceUnavailable, let device = result.failure?.deviceError {
                return .failure(ShowerActionFailure(device.userText))
            }
            if result.failure?.reason.isUnclearAuthorize == true {
                return .failure(ShowerActionFailure(ShowerAuthorizeUnclearText.spoken(platformMessage: result.failure?.platformMessage)))
            }
            if result.failure?.reason == .authorizeRefused {
                return .failure(ShowerActionFailure(ShowerAuthorizeRefusedText.spoken))
            }
            return .failure(ShowerActionFailure(ShowerDisplay.failureTitle(result.failure)))
        }
        if start {
            switch result.phase {
            case .running: return .success(.started)
            case .writePending: return .success(.startUnconfirmed)
            default: return .failure(ShowerActionFailure(notice ?? ShowerDisplay(result).title))
            }
        }
        if result.phase == .done { return .success(.settled) }
        return .failure(ShowerActionFailure(notice ?? endNotSentText))
    }
}

/// Why a start or an end did not go through, in words the system shows (Siri, Shortcuts, the
/// Live Activity).
public struct ShowerActionFailure: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }

    public static let platformMissingText = "这个版本没带热水配置，热水暂时用不了。"

    /// The engine refused before anything happened.
    public init(_ error: ShowerEngineError) {
        switch error {
        case .busy: message = "正在和水控通信，稍等一下。"
        case .blocked: message = "上次结算还没确认，打开校日常核对一下。"
        case .notAllowed: message = "现在没有可以结束的洗澡。"
        case .wrongBinding: message = "这次洗澡用的不是你现在选的水控，打开校日常看看。"
        case .storage: message = "这台手机的钥匙串暂时写不进去，重启 App 后再试。"
        case .unreadableRecord: message = "读不到上次的热水记录，打开校日常看看。"
        case .platformMissing: message = Self.platformMissingText
        }
    }

    /// A start turned down while `failure` waits for its check. An authorize the platform
    /// answered unclearly settled nothing, so it isn't called a settlement.
    public static func blockedText(_ failure: ShowerFailure?) -> String {
        if failure?.reason.isUnclearAuthorize == true {
            return ShowerAuthorizeUnclearText.spoken(platformMessage: failure?.platformMessage)
        }
        return ShowerActionFailure(.blocked).message
    }
}

public extension ShowerDeviceError {
    /// What the user can do about it.
    var userText: String {
        switch self {
        case .bluetoothOff: return "蓝牙没开，打开后再试。"
        case .notFound: return "附近没找到水控，靠近一点再试。"
        case .ambiguous: return "附近有好几台同名水控，没认出你宿舍的那台。靠近一点再试。"
        case .timedOut: return "水控没回应，靠近一点再试。"
        case .disconnected, .interrupted: return "和水控的连接断了，再试一次。"
        case .malformedFrame: return "水控回的内容看不懂，再试一次。"
        case .busy: return "正在和水控通信，稍等一下。"
        }
    }
}
