import Foundation

/// The QR codes found in a photo picked on the common-washer page.
public enum WasherPhotoCodes: Equatable, Sendable {
    case one(String)
    /// No readable code in the photo.
    case none
    /// Different codes: the photo shows more than one machine.
    case several

    /// `payloads`: what the detector read per code (nil = a code it could not read).
    public init(payloads: [String?]) {
        let codes = Set(payloads.compactMap { $0 })
        switch codes.count {
        case 0: self = .none
        case 1: self = .one(codes.first!)
        default: self = .several
        }
    }

    /// What the page shows instead of going on; nil for `.one`.
    public var message: String? {
        switch self {
        case .one: return nil
        case .none: return "照片里没找到二维码，换一张拍清楚的。"
        case .several: return "照片里有好几个码，选一张只拍了一台的。"
        }
    }
}

/// Why choosing or saving a common washer did not go ahead, each with its own text.
public enum WasherSetupRefusal: Error, Equatable, Sendable {
    /// A laundry order is still open: machines don't change until it is checked.
    case orderOpen
    /// A machine read or an order step is running.
    case busy
    /// The machine is no longer in the saved list.
    case notSaved
    /// Nothing scanned to save.
    case nothingToSave
    /// Empty, over 40 characters, or with a line break or other control character.
    case badName

    public var message: String {
        switch self {
        case .orderOpen: return "先核对已有洗衣订单。"
        case .busy: return "正在处理上一步，稍等一下。"
        case .notSaved: return "这台机器不在常用列表里了，再扫一次机身二维码。"
        case .nothingToSave: return "先扫一次机身二维码。"
        case .badName: return "机器名称最多 40 个字。"
        }
    }

    /// The refusal for changing machines now, or nil when it may go ahead. An open order wins:
    /// waiting does not help there.
    public static func check(orderOpen: Bool, busy: Bool) -> WasherSetupRefusal? {
        if orderOpen { return .orderOpen }
        return busy ? .busy : nil
    }

    /// The name to save (trimmed), or `.badName`.
    public static func machineName(_ name: String) -> Result<String, WasherSetupRefusal> {
        let alias = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty, alias.count <= 40, alias.rangeOfCharacter(from: .controlCharacters) == nil else {
            return .failure(.badName)
        }
        return .success(alias)
    }
}
