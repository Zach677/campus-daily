import Foundation
import Core

/// The shower page's taps, run through `ShowerPageFlow` (Core) and turned into the same engine
/// calls as before: start, cancel before the authorize request, end, clear a finished record.
extension ShowerModel {
    func pageEvent(_ event: ShowerPageEvent) {
        let (next, effects) = ShowerPageFlow.reduce(page, event)
        if next != page { page = next }
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: ShowerPageEffect) {
        switch effect {
        case .start:
            startTask = Task {
                try? await run(start:true)
                startTask = nil
                pageEvent(.startReturned)
            }
        case .cancelStart:
            Task {
                guard let engine, await engine.cancelStart() else { pageEvent(.cancelRefused); return }
                // The authorize request can no longer leave; end the Bluetooth connect now.
                startTask?.cancel()
            }
        case .finish:
            Task {
                try? await run(start:false)
                pageEvent(.endReturned)
            }
        case .dismissRecord:
            Task {
                // A cancelled start may still be winding down.
                while busy { try? await Task.sleep(for:.milliseconds(50)) }
                await dismiss()
            }
        case .openReview:
            reviewRequested = true
        case .resolveManually:
            Task { await resolveManually() }
        }
    }

    #if DEBUG
    /// Demo: the page over a synthetic record, no engine involved.
    func showDemoPage(_ record: ShowerState?) {
        page = ShowerPageFlow(record:record ?? .idle, presented:record != nil)
    }
    #endif
}
