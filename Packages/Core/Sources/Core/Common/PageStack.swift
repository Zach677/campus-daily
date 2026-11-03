import Foundation

/// Opening a page on a navigation stack that may already hold pages, without losing what the
/// user left open there.
public enum PageStack {
    /// The stack with `page` showing: as it is when `page` is on top; back to it when it is lower
    /// and every page over it `mayClose`; otherwise `page` pushed on top (an open top-up page is
    /// never closed, it stays under).
    public static func opening<Page: Equatable>(_ page: Page, on stack: [Page], mayClose: (Page) -> Bool) -> [Page] {
        if let index = stack.lastIndex(of:page), stack[(index + 1)...].allSatisfy(mayClose) {
            return Array(stack[...index])
        }
        return stack + [page]
    }
}
