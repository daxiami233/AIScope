import SwiftUI

struct QuotaInfoSection: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !snapshot.windows.isEmpty {
                ForEach(snapshot.windows) { window in
                    QuotaBarView(
                        label: window.label,
                        utilization: window.remainingUtilization,
                        trailingText: windowTrailingText(window),
                        color: ToolStatus.from(utilization: window.usedUtilization).color,
                        isHighlighted: window.isHighlighted
                    )
                }
            }
            if !snapshot.pools.isEmpty {
                if !snapshot.windows.isEmpty {
                    Spacer().frame(height: 2)
                }
                ForEach(snapshot.pools) { pool in
                    QuotaBarView(
                        label: pool.label,
                        utilization: pool.remainingUtilization,
                        trailingText: poolTrailingText(pool),
                        color: ToolStatus.from(utilization: pool.utilization).color,
                        isHighlighted: false
                    )
                }
            }
        }
    }

    private func poolTrailingText(_ pool: UsagePool) -> String {
        guard pool.limit != nil else {
            return "\(pool.usedDisplay) \(pool.unit)"
        }
        if pool.displayRemainingPercentOnly == true {
            let percent = "\(Int((pool.remainingUtilization * 100).rounded()))%"
            if let reset = pool.resetsInDescription {
                return "\(reset) \(percent)"
            }
            return percent
        }
        if pool.unit == "%" {
            if let reset = pool.resetsInDescription {
                return "\(reset) \(pool.remainingDisplay)"
            }
            return "\(pool.remainingDisplay)"
        }
        let values = "\(pool.remainingDisplay)/\(pool.limitDisplay) \(pool.unit)"
        if let reset = pool.resetsInDescription {
            return "\(reset) \(values)"
        }
        return values
    }

    private func windowTrailingText(_ window: UsageWindow) -> String {
        guard let resetText = window.resetsInDescription else {
            return "\(window.remainingPercent)%"
        }
        return "\(resetText) · \(window.remainingPercent)%"
    }
}
