import SwiftUI
import Core

/// One dorm or meter location offered for a choice: the short name people know
/// (「3 栋 108」) and the full location that tells same-named places apart
/// (「北校区 · 东苑公寓 · 3 栋 · 108」).
struct LocationChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let location: String

    /// VoiceOver reads the location as words, not as 「点」 separators.
    var spoken: String { title + "，" + location.replacingOccurrences(of:" · ", with:"，") }
}

/// The screen text for a same-name choice (meter step and dorm step alike): title
/// 「哪个是你宿舍的电表？」 with 「电表」 accented, and 「学校有 {n} 间都叫 {name}，选你住的那间。」.
enum SameNameText {
    static let titleLead = "哪个是你宿舍的"
    static let titleAccent = "电表"
    static let titleTail = "？"
    static func hint(_ choices: [LocationChoice]) -> String {
        LocationNaming.sameNameHint(count:choices.count, name:choices.first?.title ?? "")
    }
}

/// Single-select list of same-name candidates: top hairline, rows of a 24 pt circle check,
/// the first location level that tells the rows apart (「西苑公寓」) and the full location
/// (wraps, never truncates). A tap only marks a row;
/// the screen's 「就是这间」 confirms. Shared by onboarding and Settings.
struct LocationChoiceList: View {
    let choices: [LocationChoice]
    @Binding var selection: String?

    var body: some View {
        let titles = LocationNaming.titles(locations:choices.map(\.location))
        VStack(alignment:.leading, spacing:0) {
            Hairline()
            ForEach(Array(choices.enumerated()), id:\.element.id) { index, choice in
                if index > 0 { Hairline().padding(.leading,38) }
                LocationChoiceRow(choice:choice, title:titles[index], selected:selection == choice.id) { selection = choice.id }
                    .accessibilityIdentifier("locationChoice-" + choice.id)
            }
        }
    }
}

/// One row of `LocationChoiceList`.
struct LocationChoiceRow: View {
    let choice: LocationChoice
    /// The level that tells this row apart from the others.
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action:action) {
            HStack(alignment:.center, spacing:14) {
                LocationCheck(selected:selected)
                VStack(alignment:.leading, spacing:3) {
                    Text(title).scaledFont(17, .medium).foregroundStyle(Theme.ink)
                    Text(choice.location).scaledFont(13, relativeTo:.footnote).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal:false, vertical:true)
                }
                Spacer(minLength:0)
            }
            .padding(.vertical,12)
            .frame(minHeight:72).contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(choice.spoken)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 24 pt circle check: hairline ring when off, accentText fill with a white tick when on.
struct LocationCheck: View {
    let selected: Bool
    @ScaledMetric(relativeTo:.body) private var size: CGFloat = 24

    var body: some View {
        ZStack {
            if selected {
                Circle().fill(Theme.accentText)
                Image(systemName:"checkmark").font(.system(size:size * 0.5, weight:.bold)).foregroundStyle(.white)
            } else {
                Circle().strokeBorder(Theme.ink3, lineWidth:1.5)
            }
        }
        .frame(width:size, height:size)
        .accessibilityHidden(true)
    }
}

/// The full picker's header: the path chosen so far (校区 → 公寓 → 楼栋 → 房间), 13 ink2.
struct LocationPathHeader: View {
    let path: [String]
    var placeholder = "选择校区、公寓、楼栋和房间"

    var body: some View {
        Text(path.isEmpty ? placeholder : path.joined(separator:" · "))
            .scaledFont(13, relativeTo:.footnote).foregroundStyle(Theme.ink2)
            .fixedSize(horizontal:false, vertical:true)
            .accessibilityLabel(path.isEmpty ? placeholder : "已选 " + path.joined(separator:"，"))
    }
}
