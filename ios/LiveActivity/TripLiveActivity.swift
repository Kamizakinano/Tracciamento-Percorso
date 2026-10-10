import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PercorsoLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        TripLiveActivity()
        ParkingLiveActivity()
    }
}

/// Live Activity sul blocco schermo (e Dynamic Island) durante la registrazione.
struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.distanceText, systemImage: context.state.modeIcon)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.attributes.startDate...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let instruction = context.state.instruction {
                        NavigationLine(state: context.state, instruction: instruction)
                    } else {
                        StatusLine(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.onOldRoad ? "exclamationmark.triangle.fill" : context.state.modeIcon)
                    .foregroundStyle(context.state.onOldRoad ? .orange : .blue)
            } compactTrailing: {
                Text(context.state.distanceText).font(.caption2).monospacedDigit()
            } minimal: {
                Image(systemName: context.state.onOldRoad ? "exclamationmark.triangle.fill" : context.state.modeIcon)
                    .foregroundStyle(context.state.onOldRoad ? .orange : .blue)
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<TripActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.attributes.automatic ? "Registrazione automatica" : "Registrazione",
                      systemImage: "record.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Spacer()
                Text(timerInterval: context.attributes.startDate...Date.distantFuture, countsDown: false)
                    .font(.subheadline)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .foregroundStyle(.white)
            }
            HStack(alignment: .firstTextBaseline) {
                Label(context.state.distanceText, systemImage: context.state.modeIcon)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                if let p = context.state.newPercent {
                    Text("Nuove: \(p)%")
                        .font(.headline)
                        .foregroundStyle(.green)
                }
            }
            if let instruction = context.state.instruction {
                NavigationLine(state: context.state, instruction: instruction)
            } else {
                StatusLine(state: context.state)
            }
        }
        .padding()
    }
}

private struct NavigationLine: View {
    let state: TripActivityAttributes.ContentState
    let instruction: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.maneuverIcon ?? "arrow.up")
                .font(.title.weight(.bold))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                if let d = state.maneuverText {
                    Text(d).font(.headline).foregroundStyle(.white)
                }
                Text(instruction)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if state.onOldRoad {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }
}

private struct StatusLine: View {
    let state: TripActivityAttributes.ContentState

    var body: some View {
        if state.onOldRoad {
            Label("Strada già percorsa", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
        } else {
            Label("Strada nuova", systemImage: "sparkles")
                .font(.subheadline)
                .foregroundStyle(.green)
        }
    }
}
