import SwiftUI

enum ToolStatus: Equatable {
    case normal     // max utilization < 70%
    case warning    // 70% – 90%
    case critical   // > 90%
    case offline    // credential error / network failure

    static func from(utilization: Double) -> ToolStatus {
        switch utilization {
        case ..<0.70:  return .normal
        case ..<0.90:  return .warning
        default:       return .critical
        }
    }

    var color: Color {
        switch self {
        case .normal:   return .green
        case .warning:  return Color.orange
        case .critical: return .red
        case .offline:  return Color(nsColor: .secondaryLabelColor)
        }
    }

    /// Used for the Menu Bar icon badge
    var priority: Int {
        switch self {
        case .normal:   return 0
        case .offline:  return 1
        case .warning:  return 2
        case .critical: return 3
        }
    }
}
