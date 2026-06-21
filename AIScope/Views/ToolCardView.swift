import SwiftUI

// MARK: - ToolCardView

/// 单个 AI 工具的用量卡片。
/// 错误状态下优先展示可用缓存，并提示本次刷新失败原因。
struct ToolCardView: View {

    let snapshot: UsageSnapshot
    let provider: any AIToolProvider
    let status:   ToolStatus
    let reauthenticateAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            if snapshot.isError && !snapshot.hasDisplayData {
                errorSection
            } else {
                if snapshot.isError {
                    staleWarningSection
                }
                if snapshot.windows.isEmpty && snapshot.pools.isEmpty {
                    emptyQuotaSection
                } else {
                    dataSection
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - 标题行

    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(provider.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            if let plan = snapshot.planName {
                Text(plan)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(planColor(for: plan))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(planColor(for: plan).opacity(0.15))
                    )
            }

            Spacer()
        }
        .padding(.bottom, 9)
    }

    // MARK: - 错误状态区域

    private var errorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(snapshot.errorMessage ?? "获取数据失败")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            reauthenticateButton
        }
    }

    private var staleWarningSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: snapshot.requiresUserAction ? "exclamationmark.triangle.fill" : "wifi.exclamationmark")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(staleWarningText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            reauthenticateButton
        }
        .padding(.bottom, 6)
        .help(snapshot.errorMessage ?? "刷新失败")
    }

    // MARK: - 正常数据区域

    private var emptyQuotaSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.badge.questionmark")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(emptyQuotaText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var dataSection: some View {
        QuotaInfoSection(snapshot: snapshot)
    }

    private var emptyQuotaText: String {
        if let quotaExtra = snapshot.extras.first(where: { $0.label.contains("额度") }) {
            return quotaExtra.value
        }
        return "暂无可显示额度"
    }

    private var staleWarningText: String {
        guard snapshot.requiresUserAction, let message = snapshot.errorMessage else {
            return "本次刷新失败，正在显示上次成功数据"
        }
        return "\(message)，正在显示上次成功数据"
    }

    @ViewBuilder
    private var reauthenticateButton: some View {
        if snapshot.requiresUserAction, let reauthenticateAction {
            Button {
                reauthenticateAction()
            } label: {
                Label("重新登录", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .help("重新登录 \(provider.displayName)")
        }
    }

    private func planColor(for plan: String) -> Color {
        let lower = plan.lowercased()
        if lower.contains("max") { return .orange }
        if lower.contains("pro") { return .purple }
        if lower.contains("standard") { return .blue }
        if lower.contains("lite") { return .teal }
        if lower.contains("年度") || lower.contains("annual") { return .orange }
        return .accentColor
    }
}
