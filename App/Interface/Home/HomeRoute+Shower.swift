import Core

extension HomeRoute {
    /// Stub: every route goes through as it is.
    static func opened(_ new: [HomeRoute], over old: [HomeRoute], page: ShowerPageFlow) -> (routes: [HomeRoute], showsPage: Bool) {
        (new, false)
    }
}
