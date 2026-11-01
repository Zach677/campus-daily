import Foundation

/// What the app shows of the stored school items: signed in or not, the dorm and meter, the
/// account. Re-read at launch and after a sign-in or sign-out.
public struct SchoolShownItems: Sendable, Equatable {
    public var signedIn: Bool
    public var profile: SchoolProfile?
    public var account: SchoolAccount?

    public init(signedIn: Bool = false, profile: SchoolProfile? = nil, account: SchoolAccount? = nil) {
        self.signedIn = signedIn; self.profile = profile; self.account = account
    }

    /// The items as stored now.
    public func reread(from vault: SchoolVault) -> SchoolShownItems {
        SchoolShownItems(signedIn: ((try? vault.ecyktSession()) ?? nil) != nil,
                         profile: (try? vault.profile()) ?? nil,
                         account: (try? vault.account()) ?? nil)
    }
}
