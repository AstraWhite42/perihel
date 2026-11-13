import AppKit
import SwiftUI
import Darwin

struct WindowView: View {
    @ObservedObject var resetNews: ResetNewsFeed
    let showsResetNews: Bool
    let resetCredits: [ResetCredit]
    let title: String
    let window: Window
    let now: Date
    let progressStyle: ProgressStyle
    private var notice: ResetNewsNotice? { showsResetNews && window.isWeekly ? resetNews.notice(now: now) : nil }
    private var forecast: Date? { notice?.reference(in: window, now: now) }
    @ViewState private var showBudgetDetails = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(TimeZone.current.identifier).font(.caption2)
                    .lineLimit(1).truncationMode(.middle)
                    .help("当前系统时区：\(TimeZone.current.identifier)")
            }.foregroundStyle(.secondary)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("剩余额度").font(.caption).foregroundStyle(.secondary)
                    Text(percent(window.remaining)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("距离重置").font(.caption).foregroundStyle(.secondary)
                    Text(countdown(window.end, now)).font(.subheadline.weight(.medium)).monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("开始 \(shortDate(window.start))")
                        .help("开始时间（推算）：\(dateText(window.start))")
                    Spacer(minLength: 8)
                    Text("重置 \(shortDate(window.end))")
                        .help("下次重置：\(dateText(window.end))")
                }.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                UsageBar(actual: window.usedPercent, theory: window.theoretical(now), window: window, style: progressStyle, resetCredits: resetCredits, now: now, forecast: forecast)
                HStack(spacing: 5) {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                    Text("实际已用")
                    Text("·")
                    Text("理论刻度")
                    if !window.resetExpiryDates(resetCredits).isEmpty {
                        Image(systemName: "diamond.fill").font(.system(size: 6)).foregroundStyle(.orange)
                        Text("机会到期")
                    }
                    Spacer(minLength: 8)
                    if let actual = window.usedPercent, let theory = window.theoretical(now) {
                        let difference = actual - theory
                        if window.supportsBudgetDetails {
                        Button { showBudgetDetails.toggle() } label: {
                            HStack(spacing: 4) {
                                Text(abs(difference) < 0.05 ? "预算持平" : String(format: "%@预算 %.1f%%", difference > 0 ? "领先" : "落后", abs(difference)))
                                    .monospacedDigit()
                                Image(systemName: showBudgetDetails ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                            }.fixedSize().contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .help(showBudgetDetails ? "收起预算计算依据" : "查看实际与理论用量及差值")
                            .accessibilityLabel(showBudgetDetails ? "收起预算计算依据" : "展开预算计算依据")
                        } else {
                            Text(abs(difference) < 0.05 ? "预算持平" : String(format: "%@预算 %.1f%%", difference > 0 ? "领先" : "落后", abs(difference)))
                                .monospacedDigit()
                        }
                    }
                }.font(.caption2).foregroundStyle(.secondary)
            }
            if let notice { ResetNewsView(notice: notice, now: now) }
            if window.supportsBudgetDetails, showBudgetDetails, let actual = window.usedPercent, let theory = window.theoretical(now) {
                Divider()
            Grid(horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("用量").frame(maxWidth: .infinity, alignment: .leading)
                    Text("已用").frame(width: 60, alignment: .trailing)
                    Text("剩余").frame(width: 60, alignment: .trailing)
                    HStack(spacing: 3) {
                        Text("差值")
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 10))
                    }.frame(width: 60, alignment: .trailing)
                        .contentShape(Rectangle())
                        .help("差值 = 当前实际已用 − 对应行的理论已用\n正值：领先预算\n负值：落后预算\n单位：百分点")
                        .accessibilityLabel("差值，悬停查看计算说明")
                }.font(.caption).foregroundStyle(.secondary)
                usageRow("实际", window.usedPercent, window.remaining)
                usageRow("当前理论", theory, 100 - theory, difference: actual - theory)
                let midnightTheory = window.theoreticalAtMidnight(now)
                usageRow("今晚24时理论", midnightTheory, midnightTheory.map { 100 - $0 }, difference: midnightTheory.map { actual - $0 }, explanation: "按系统时区计算今晚 24 时的理论用量。\n沿用当前额度窗口的匀速预算。\n若窗口在此前结束，理论已用记为 100%。")
                if let forecast, let forecastTheory = window.theoretical(forecast) {
                    usageRow(notice?.theoryTitle ?? "预告时点理论", forecastTheory, 100 - forecastTheory, difference: actual - forecastTheory,
                             explanation: "按预告参考时间计算当前周窗口的理论用量。\n实际已用减去该值即为差值。\n具体重置安排以公告原文为准。")
                }
            }.font(.subheadline).monospacedDigit()
            }
        }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .onAppear { if CommandLine.arguments.contains("--budget-details") { showBudgetDetails = true } }
    }
    func usageRow(_ title: String, _ used: Double?, _ remaining: Double?, difference: Double? = nil, explanation: String? = nil) -> some View {
        GridRow {
            HStack(spacing: 3) {
                Text(title)
                if explanation != nil {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .help(explanation ?? "")
            Text(percent(used)).frame(width: 60, alignment: .trailing)
            Text(percent(remaining)).frame(width: 60, alignment: .trailing)
            Text(difference.map { abs($0) < 0.05 ? "0.0%" : String(format: "%+.1f%%", $0) } ?? "—")
                .frame(width: 60, alignment: .trailing)
        }
    }
}
