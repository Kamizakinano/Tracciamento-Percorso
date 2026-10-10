import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity del parcheggio: conto alla rovescia del ticket sul blocco schermo.
struct ParkingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ParkingActivityAttributes.self) { context in
            ParkingLockScreenView(state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Ticket", systemImage: "car.fill")
                        .font(.headline)
                        .foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Countdown(expiry: context.state.expiry, stale: context.isStale)
                        .font(.headline)
                        .frame(width: 80)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.address).font(.subheadline).lineLimit(1)
                        if let note = context.state.note {
                            Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "car.fill").foregroundStyle(.blue)
            } compactTrailing: {
                Countdown(expiry: context.state.expiry, stale: context.isStale)
                    .font(.caption2)
                    .frame(width: 48)
            } minimal: {
                Image(systemName: "car.fill").foregroundStyle(.blue)
            }
        }
    }
}

/// Tempo rimanente; "Scaduto" quando il ticket è finito.
private struct Countdown: View {
    let expiry: Date
    let stale: Bool

    var body: some View {
        let now = Date()
        if stale || expiry <= now {
            Text("Scaduto").foregroundStyle(.red)
        } else {
            Text(timerInterval: now...expiry, countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.orange)
        }
    }
}

private struct ParkingLockScreenView: View {
    let state: ParkingActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "car.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Color.blue, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Parcheggio").font(.caption).foregroundStyle(.white.opacity(0.7))
                Text(state.address)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(state.note ?? "Scade alle \(state.expiry.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Ticket").font(.caption).foregroundStyle(.white.opacity(0.7))
                Countdown(expiry: state.expiry, stale: stale)
                    .font(.title2.weight(.bold))
                    .frame(width: 100, alignment: .trailing)
            }
        }
        .padding()
    }
}
