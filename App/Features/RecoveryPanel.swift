import SwiftUI
import ETAEngine
import HSLDesign

/// "Missed it" / "Your bus is late": the fastest alternatives and exactly where to go.
struct RecoveryPanel: View {
    let session: CommuteSession
    let recovery: RecoveryState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let error = recovery.error, recovery.options.isEmpty {
                Text(error).font(HSLFont.caption()).foregroundStyle(.secondary)
            }
            ForEach(recovery.options.prefix(3)) { option in
                RecoveryOptionCard(option: option, now: session.now,
                                   isSelected: option.id == recovery.selected?.id)
                    .onTapGesture { session.selectRecovery(option) }
            }
            buttons
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: recovery.isSuggestion ? "bolt.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 22, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text(recovery.title).font(HSLFont.title(18)).lineLimit(2)
                Text(recovery.subtitle).font(HSLFont.caption()).opacity(0.9)
            }
            Spacer()
            if recovery.loading { ProgressView().tint(.white) }
        }
        .padding(14)
        .background(recovery.isSuggestion ? HSLColor.blue : HSLColor.red,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var buttons: some View {
        if let selected = recovery.selected {
            HStack(spacing: 10) {
                Button { session.dismissRecovery() } label: {
                    Text(recovery.isSuggestion ? "Keep my plan" : "Back")
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(.white.opacity(0.1), in: Capsule())
                }
                Button { session.takeRecovery(selected) } label: {
                    Text(recovery.isSuggestion ? "Switch to \(selected.line)" : "Go: \(selected.line)")
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(HSLColor.green, in: Capsule())
                }
            }
            .font(HSLFont.body())
            .buttonStyle(.plain)
        }
    }
}

struct RecoveryOptionCard: View {
    let option: RecoveryOption
    let now: Date
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    if option.isFastest {
                        Text("FASTEST").font(.system(size: 10, weight: .heavy, design: .rounded))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(HSLColor.green, in: Capsule())
                    }
                    LegStrip(legs: option.itinerary.legs)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Arrive \(option.arrival.formatted(date: .omitted, time: .shortened))").font(HSLFont.title(16))
                    Text(delayLabel).font(HSLFont.caption(11)).foregroundStyle(delayColor)
                }
            }
            // Where to go
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(HSLColor.mode(option.firstTransit.mode))
                Text(option.whereToGo).font(HSLFont.body(14)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    RecoveryPlanner.openWalkingDirections(to: option.boardingStop)
                } label: {
                    Image(systemName: "map.fill").font(.system(size: 15, weight: .bold))
                        .frame(width: 34, height: 34).background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
            }
            // When, and how fast
            HStack(spacing: 6) {
                Circle().fill(HSLColor.pace(option.advice.state)).frame(width: 8, height: 8)
                Text(timing).font(HSLFont.caption(12)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.white.opacity(isSelected ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(isSelected ? HSLColor.green : .clear, lineWidth: 2))
    }

    private var timing: String {
        let mins = Int(option.departure.timeIntervalSince(now) / 60)
        let when = mins <= 0 ? "leaves now" : "leaves in \(mins) min"
        let pace: String
        switch option.advice.state {
        case .atStop: pace = "you're there"
        case .relax, .leaveSoon: pace = "plenty of time"
        case .goNow: pace = "walk now"
        case .walkBriskly: pace = "walk briskly"
        case .run: pace = "run"
        default: pace = option.advice.state.title.lowercased()
        }
        return "\(option.line) \(when) · \(pace)"
    }

    private var delayLabel: String {
        switch option.delayVsPlan {
        case ..<0: return "\(-option.delayVsPlan) min sooner"
        case 0: return "as planned"
        default: return "+\(option.delayVsPlan) min vs plan"
        }
    }

    private var delayColor: Color {
        option.delayVsPlan <= 0 ? HSLColor.green : (option.delayVsPlan <= 10 ? HSLColor.yellow : HSLColor.orange)
    }
}
