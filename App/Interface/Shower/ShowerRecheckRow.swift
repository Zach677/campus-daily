import SwiftUI
import Core

/// 再查一次水控: icon + text in accentText (a spinner and 正在查水控… in ink2 while it runs),
/// then what it found under it. Water still running goes back to the timer with no line.
struct ShowerRecheckRow: View {
    @EnvironmentObject private var shower: ShowerModel
    private var flow: ShowerPageFlow { shower.page }

    var body: some View {
        VStack(alignment:.leading, spacing:4) {
            Button { shower.pageEvent(.recheckTapped) } label: {
                HStack(spacing:8) {
                    if flow.rechecking {
                        ProgressView().controlSize(.small).frame(width:16, height:16)
                    } else {
                        Image(systemName:"arrow.clockwise").scaledFont(15, relativeTo:.body)
                    }
                    Text(flow.rechecking ? ShowerPageText.rechecking : ShowerPageText.recheck).scaledFont(17, .medium)
                }
                .foregroundStyle(flow.rechecking ? Theme.ink2 : Theme.accentText)
                .frame(minHeight:44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // While it runs the row stays at full ink2 (the reducer ignores a second tap).
            .disabled(!flow.mayRecheck && !flow.rechecking)
            .accessibilityIdentifier("showerRecheck")
            if let result = flow.recheckResult {
                if result == .stopped {
                    Text(ShowerPageText.recheckResult(result)).scaledFont(13, relativeTo:.footnote).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal:false, vertical:true)
                } else {
                    HStack(alignment:.firstTextBaseline, spacing:6) {
                        Image(systemName:"exclamationmark.circle.fill").scaledFont(17, relativeTo:.body).accessibilityHidden(true)
                        Text(ShowerPageText.recheckResult(result)).scaledFont(15, relativeTo:.subheadline)
                            .fixedSize(horizontal:false, vertical:true)
                    }
                    .foregroundStyle(Theme.accentText)
                    .accessibilityElement(children:.combine)
                }
            }
        }
    }
}

/// 再结算一次 on the 不确定 face of a settlement that failed: the first tap arms it (the line
/// under it says the next tap sends it again), the second settles once more.
struct ShowerSettleRetryRow: View {
    @EnvironmentObject private var shower: ShowerModel
    private var flow: ShowerPageFlow { shower.page }
    private var armed: Bool { flow.settleRetryArmed }
    private var enabled: Bool { shower.mayRetrySettle && flow.mayRetrySettle }

    var body: some View {
        VStack(alignment:.leading, spacing:4) {
            Button { shower.pageEvent(.settleRetryTapped) } label: {
                HStack(spacing:8) {
                    if shower.busy && shower.state.phase == .settling {
                        ProgressView().controlSize(.small).frame(width:16, height:16)
                    } else {
                        Image(systemName:armed ? "exclamationmark.arrow.circlepath" : "arrow.clockwise")
                            .scaledFont(15, relativeTo:.body)
                    }
                    Text(armed ? ShowerPageText.settleRetryConfirm : ShowerPageText.settleRetry).scaledFont(17, .medium)
                }
                .foregroundStyle(enabled ? Theme.accentText : Theme.ink3)
                .frame(minHeight:44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityIdentifier("showerSettleRetry")
            .accessibilityHint(armed ? ShowerPageText.settleRetryArmedNote : ShowerPageText.settleRetryNote)
            Text(armed ? ShowerPageText.settleRetryArmedNote : ShowerPageText.settleRetryNote)
                .scaledFont(13, relativeTo:.footnote).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal:false, vertical:true)
        }
    }
}
