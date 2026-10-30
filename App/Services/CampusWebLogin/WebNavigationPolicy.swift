import Foundation

/// The school login and recharge web views enforce their host allow-list in
/// `webView(_:decidePolicyFor:decisionHandler:)`. That method is optional in
/// `WKNavigationDelegate`, so if its Swift spelling stops matching the SDK it still compiles and
/// WebKit simply never calls it. Each coordinator asserts at init that WebKit will find it.
enum WebNavigationPolicy {
    static let selector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
}
