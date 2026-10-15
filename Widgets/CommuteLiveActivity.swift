import ActivityKit
import SwiftUI
import WidgetKit
import ETAEngine
import HSLDesign

/// Lock Screen + Dynamic Island. The countdown is rendered with `Text(timerInterval:)`
/// so it ticks every second without the app sending updates.
struct CommuteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CommuteActivityAttributes.self) { context in
            LockScreenView(state: context.state, destination: context.attributes.destinationName)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 4) {
                        LineBadge(s.line, mode: s.mode, size: 14)
                        Text(s.stopName).font(HSLFont.caption(12)).lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Countdown(state: s, size: 30)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        PaceStrip(state: s)
                        ProgressBar(progress: s.progress, color: HSLColor.mode(s.mode))
                    }
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: s.mode.symbolName).foregroundStyle(HSLColor.mode(s.mode))
                    Text(s.line).font(.system(size: 14, weight: .heavy, design: .rounded))
                }
            } compactTrailing: {
                CompactCountdown(state: s)
            } minimal: {
                Image(systemName: paceIcon(s.pace)).foregroundStyle(HSLColor.pace(s.pace))
            }
            .keylineTint(HSLColor.mode(s.mode))
        }
    }
}

private struct LockScreenView: View {
    let state: CommuteActivityAttributes.ContentState
    let destination: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                LineBadge(state.line, mode: state.mode, size: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(headline).font(HSLFont.caption(12)).foregroundStyle(.secondary)
                    Text(state.headsign).font(HSLFont.title(18)).lineLimit(1)
                }
                Spacer()
                Countdown(state: state, size: 34)
            }
            ProgressBar(progress: state.progress, color: HSLColor.mode(state.mode))
            if state.askOccupancy {
                OccupancyButtons(line: state.line)
            } else {
                PaceStrip(state: state)
            }
            if let note = state.transferNote {
                Label(note, systemImage: "arrow.triangle.swap").font(HSLFont.caption(12)).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }

    private var headline: String {
        switch state.phase {
        case .walking: return "Walk to \(state.stopName)"
        case .waiting: return "At \(state.stopName)"
        case .transfer: return "Go to \(state.stopName)"
        case .riding: return "To \(state.stopName) · \(destination)"
        case .arrived: return "Arrived"
        }
    }
}

private struct Countdown: View {
    let state: CommuteActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        let target = state.countdownTarget
        VStack(alignment: .trailing, spacing: 0) {
            if target.date > Date() {
                Text(timerInterval: Date()...target.date, countsDown: true, showsHours: false)
                    .font(HSLFont.number(size))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: size * 3.2, alignment: .trailing)
            } else {
                Text("Now").font(HSLFont.number(size))
            }
            HStack(spacing: 3) {
                if !target.isLeave {
                    Circle().fill(state.isLive ? HSLColor.green : .gray).frame(width: 5, height: 5)
                }
                Text(target.label).font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CompactCountdown: View {
    let state: CommuteActivityAttributes.ContentState

    var body: some View {
        if state.countdownTarget.date > Date() {
            Text(timerInterval: Date()...state.countdownTarget.date, countsDown: true, showsHours: false)
                .font(.system(size: 14, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(HSLColor.pace(state.pace))
                .frame(maxWidth: 48)
        } else {
            Text("Now").font(.system(size: 14, weight: .heavy, design: .rounded))
        }
    }
}

private struct PaceStrip: View {
    let state: CommuteActivityAttributes.ContentState

    var body: some View {
        if state.phase != .riding, !state.paceMessage.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: paceIcon(state.pace)).font(.system(size: 16, weight: .bold))
                Text(state.paceMessage).font(HSLFont.body(14)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(state.pace == .walkBriskly ? Color.black : Color.white)
            .background(HSLColor.pace(state.pace), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let next = state.nextStopName {
            HStack {
                Text("Next stop").font(HSLFont.caption(12)).foregroundStyle(.secondary)
                Text(next).font(HSLFont.body(14))
                Spacer()
                if let full = state.fullness {
                    Text(full).font(HSLFont.caption(12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// One-tap "how full is it?" right on the Lock Screen (runs in the app via ReportOccupancyIntent).
private struct OccupancyButtons: View {
    let line: String

    var body: some View {
        HStack(spacing: 6) {
            Text("How full is \(line)?").font(HSLFont.caption(12)).lineLimit(1)
            Spacer(minLength: 4)
            ForEach(CrowdLevel.allCases, id: \.self) { level in
                Button(intent: ReportOccupancyIntent(level: level.rawValue)) {
                    Text(level.title).font(HSLFont.caption(12))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .background(Occupancy.color(level).opacity(0.3), in: Capsule())
            }
        }
    }
}

private struct ProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(color).frame(width: max(geo.size.width * progress, 6))
            }
        }
        .frame(height: 6)
    }
}

extension CommuteActivityAttributes.ContentState {
    /// Before you leave, count down to leaving; after that, to the vehicle.
    var countdownTarget: (date: Date, label: String, isLeave: Bool) {
        if phase == .walking, let leave = leaveAt, leave > Date(), pace == .relax || pace == .leaveSoon {
            return (leave, "until you leave", true)
        }
        switch phase {
        case .riding: return (eta, isLive ? "live · to your stop" : "to your stop", false)
        default: return (eta, isLive ? "live · leaves" : "leaves", false)
        }
    }
}

private func paceIcon(_ s: PaceState) -> String {
    switch s {
    case .relax: return "cup.and.saucer.fill"
    case .leaveSoon: return "clock.fill"
    case .goNow: return "figure.walk"
    case .walkBriskly: return "figure.walk.motion"
    case .run: return "figure.run"
    case .willMiss: return "xmark.octagon.fill"
    case .atStop: return "mappin.circle.fill"
    case .onBoard: return "tram.fill"
    }
}

#Preview("Lock Screen", as: .content, using: CommuteActivityAttributes(destinationName: "Work", startedAt: .now)) {
    CommuteLiveActivity()
} contentStates: {
    CommuteActivityAttributes.ContentState.preview
}
