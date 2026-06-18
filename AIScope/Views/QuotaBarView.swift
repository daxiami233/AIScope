import SwiftUI

// MARK: - QuotaBarView

/// 通用进度条组件，复用于 UsageWindow 行和 UsagePool 行。
/// 支持高亮模式（橙/红渐变），颜色由调用方传入。
struct QuotaBarView: View {

    let label:         String
    let utilization:   Double    // 0.0 – 1.0, usually remaining ratio
    let trailingText:  String    // 右侧说明，如 "68%" 或 "1200/1500 Credits"
    let color:         Color
    let isHighlighted: Bool
    var leadingText:   String? = nil

    private var barGradient: LinearGradient {
        LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let leadingText {
                    Text(leadingText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(isHighlighted ? Color.orange : Color.primary)
                    .lineLimit(1)
                Spacer()
                Text(trailingText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isHighlighted ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 6)
                    Capsule()
                        .frame(
                            width: max(0, min(geo.size.width * utilization, geo.size.width)),
                            height: 6
                        )
                        .foregroundStyle(
                            isHighlighted
                                ? AnyShapeStyle(barGradient)
                                : AnyShapeStyle(color)
                        )
                        .animation(.easeInOut(duration: 0.18), value: utilization)
                }
            }
            .frame(height: 6)
        }
    }
}

#if ENABLE_SWIFTUI_PREVIEWS
#Preview {
    VStack(spacing: 12) {
        QuotaBarView(label: "5h",        utilization: 0.68, trailingText: "68%",               color: .green,  isHighlighted: false)
        QuotaBarView(label: "7d 总量",    utilization: 0.25, trailingText: "25%",               color: .orange, isHighlighted: false)
        QuotaBarView(label: "7d OAuth",   utilization: 0.09, trailingText: "9%",                color: .red,    isHighlighted: true)
        QuotaBarView(label: "AI Credits", utilization: 0.80, trailingText: "1200/1500 Credits", color: .green,  isHighlighted: false)
    }
    .padding()
    .frame(width: 280)
}
#endif
