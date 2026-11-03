import SwiftUI

/// Error lines under the page's content, in `notice`. Cached data stays visible above them.
struct ClearLaundryIssueLines: View {
    let lines: [String]

    var body: some View {
        ForEach(lines, id:\.self) { line in
            Label {
                Text(line).fixedSize(horizontal:false, vertical:true)
            } icon: {
                Image(systemName:"exclamationmark.circle")
            }
            .font(.footnote)
            .foregroundStyle(Theme.notice)
            .frame(maxWidth:.infinity, alignment:.leading)
        }
    }
}
