#if canImport(SwiftUI)
import SwiftUI
import ETAEngine

/// HSL brand palette (from HSL's public design system; verify against current guidelines).
public enum HSLColor {
    public static let blue = Color(hex: 0x007AC9)        // HSL blue, buses
    public static let darkBlue = Color(hex: 0x000F2D)
    public static let trunk = Color(hex: 0xEA7000)       // Runkolinja orange
    public static let tram = Color(hex: 0x00985F)
    public static let lightRail = Color(hex: 0x00B2A9)
    public static let metro = Color(hex: 0xFF6319)
    public static let train = Color(hex: 0x8C4799)
    public static let ferry = Color(hex: 0x00B9E4)
    public static let uBus = Color(hex: 0xEA7000)
    public static let walk = Color(hex: 0x666666)
    public static let cityBike = Color(hex: 0xF2B62D)

    public static let green = Color(hex: 0x64BE14)       // success / on time
    public static let yellow = Color(hex: 0xFED100)
    public static let orange = Color(hex: 0xFF8A00)
    public static let red = Color(hex: 0xDC0451)

    public static let surface = Color(hex: 0x1C1C1E)
    public static let surfaceRaised = Color(hex: 0x2C2C2E)

    public static func mode(_ mode: TransitMode) -> Color {
        switch mode {
        case .bus: return blue
        case .trunkBus: return trunk
        case .uBus: return uBus
        case .tram: return tram
        case .lightRail: return lightRail
        case .metro: return metro
        case .rail: return train
        case .ferry: return ferry
        case .bicycle: return cityBike
        case .walk, .unknown: return walk
        }
    }

    public static func pace(_ state: PaceState) -> Color {
        switch state {
        case .relax, .atStop, .onBoard: return green
        case .leaveSoon: return blue
        case .goNow: return blue
        case .walkBriskly: return yellow
        case .run: return orange
        case .willMiss: return red
        }
    }
}

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// HSL uses Gotham Rounded (licensed). SF Pro Rounded is the closest system font.
public enum HSLFont {
    public static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    public static func title(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    public static func body(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .medium, design: .rounded) }
    public static func caption(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    public static func number(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .rounded).monospacedDigit()
    }
}

public extension TransitMode {
    var symbolName: String {
        switch self {
        case .bus, .trunkBus, .uBus: return "bus.fill"
        case .tram, .lightRail: return "tram.fill"
        case .metro: return "tram.fill.tunnel"
        case .rail: return "train.side.front.car"
        case .ferry: return "ferry.fill"
        case .walk: return "figure.walk"
        case .bicycle: return "bicycle"
        case .unknown: return "questionmark.circle"
        }
    }

    var displayName: String {
        switch self {
        case .bus: return "Bus"
        case .trunkBus: return "Trunk bus"
        case .uBus: return "U-bus"
        case .tram: return "Tram"
        case .lightRail: return "Light rail"
        case .metro: return "Metro"
        case .rail: return "Train"
        case .ferry: return "Ferry"
        case .walk: return "Walk"
        case .bicycle: return "Bike"
        case .unknown: return "Transit"
        }
    }
}

/// Rounded line badge, e.g. [🚌 551].
public struct LineBadge: View {
    var name: String
    var mode: TransitMode
    var showsIcon: Bool
    var size: CGFloat

    public init(_ name: String, mode: TransitMode, showsIcon: Bool = true, size: CGFloat = 15) {
        self.name = name
        self.mode = mode
        self.showsIcon = showsIcon
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 4) {
            if showsIcon { Image(systemName: mode.symbolName).font(.system(size: size * 0.85, weight: .bold)) }
            Text(name).font(.system(size: size, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, size * 0.55)
        .padding(.vertical, size * 0.25)
        .background(HSLColor.mode(mode), in: RoundedRectangle(cornerRadius: size * 0.45, style: .continuous))
    }
}

/// Dark rounded tile used in the live trip sheet (How full / Speed / Ends).
public struct InfoTile<Content: View>: View {
    var title: String
    var dot: Color?
    @ViewBuilder var content: Content

    public init(_ title: String, dot: Color? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.dot = dot
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(title).font(HSLFont.caption(12)).foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// HFP `occu` percent to a friendly label.
public enum Occupancy {
    public static func label(_ percent: Int?) -> (String, Color) {
        guard let p = percent else { return ("No data", Color.gray) }
        switch p {
        case ..<40: return ("Seats", HSLColor.green)
        case ..<80: return ("Standing", HSLColor.yellow)
        default: return ("Full", HSLColor.red)
        }
    }
}
#endif
