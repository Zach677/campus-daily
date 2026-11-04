import Foundation

/// One presentation of the first-run guide (暖橙's cover, 清爽's checklist sheet), and where it
/// starts (`start`; nil: its first page).
///
/// Several paths ask for it close together: leaving the sample shows the live root again, whose
/// first-run check asks at once, and 去登录 or a login link asks again a moment later. Asked while
/// one is up, the guide is kept (same `id`): replacing it would dismiss the cover or sheet, which
/// marks the setup seen, and present it again. Only a more specific start changes it, in place
/// (`contentID` changes, so its pages start again from there).
public struct GuideRequest<Start: Equatable>: Identifiable, Equatable {
    /// The presentation: a new id is a new cover or sheet.
    public let id: UUID
    public private(set) var start: Start?
    private var revision = 0

    /// The guide's content: changes when `start` changes in place.
    public var contentID: String { "\(id.uuidString)/\(revision)" }

    public init(start: Start?) {
        id = UUID()
        self.start = start
    }

    /// The guide asked for at `start`, with `current` up (nil: none). Nothing up: a new one. Up:
    /// the same one, at `start` if that is a page and not the one it is on; asked for its first
    /// page, it stays where it is.
    public static func ask(_ start: Start?, over current: GuideRequest?) -> GuideRequest {
        guard var request = current else { return GuideRequest(start: start) }
        guard let start, start != request.start else { return request }
        request.start = start
        request.revision += 1
        return request
    }
}
