import AppKit
import SwiftUI
import Darwin

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
struct UsageInfoView: View {
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("额度说明").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 22, height: 22) }
                    .buttonStyle(.borderless).accessibilityLabel("关闭说明")
            }
            section("理论用量", "按当前时间在额度窗口中的进度，计算匀速消耗时的理论已用和剩余百分比。它是消费节奏参考，不代表额度随时间补充。")
            section("窗口时间", "开始时间由“下次重置时间 − 窗口长度”推算。所有时间使用系统时区：\(TimeZone.current.identifier)。")
            section("重置机会", "可用次数以服务端返回值为准。到期明细可能不完整；未提供到期时间不代表永久有效。")
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("近星点 \(AppVersion.version)（构建 \(AppVersion.build)）").font(.subheadline.weight(.medium))
                Text("作者：白星澈AstraWhite").font(.callout).foregroundStyle(.secondary)
            }
        }.padding(18).frame(width: 320, alignment: .leading)
    }
    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(body).font(.callout).foregroundStyle(.secondary)
                .lineSpacing(4).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
struct SetupView: View {
    @ObservedObject var store: Store
    private var installed: Bool { CLIReader.locate() != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连接你的 Codex").font(.title3.weight(.semibold))
            Text("近星点复用本机 CLI 登录，只读取订阅额度。每位使用者登录自己的 ChatGPT 账户。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 9) {
                Label("1 · 安装 Codex CLI", systemImage: installed ? "checkmark.circle.fill" : "circle")
                    .font(.headline)
                if installed {
                    Text(store.cliVersion ?? "已找到 CLI，请完成登录检测。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(CLIReader.locate() ?? "").font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled)
                } else {
                    Text("已安装 Homebrew 时，可在终端执行以下命令：")
                        .font(.caption).foregroundStyle(.secondary)
                    command("brew install --cask codex")
                }
                HStack {
                    Link("安装与更新说明", destination: URL(string: "https://learn.chatgpt.com/docs/codex/cli")!)
                    Spacer()
                    Button("选择已有 CLI…") { store.chooseCLI() }.disabled(store.loading)
                }.font(.caption)
            }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 9) {
                Label("2 · 登录 ChatGPT 账户", systemImage: store.snapshot != nil ? "checkmark.circle.fill" : "circle")
                    .font(.headline)
                Text("使用订阅账户登录，完成浏览器授权后返回这里重新检测。API Key 登录不适用于订阅额度。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                command(CLIReader.locate().map { CLIReader.shellQuote($0) + " login" } ?? "codex login")
                Button("打开终端登录…") { store.openLogin() }.disabled(!installed || store.loading)
            }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if store.snapshot != nil {
                Label("已连接，可以查看额度了。", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
            }
            HStack {
                Button(store.loading ? "正在检测…" : "重新检测") { store.refresh() }.disabled(store.loading)
                Spacer()
                Button("开始使用") { store.finishSetup() }.disabled(store.snapshot == nil || store.loading)
                    .buttonStyle(.borderedProminent)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func command(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            Button { store.copyCommand(text) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("复制命令")
        }.padding(8).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}
typealias ViewState<Value> = SwiftUI.State<Value>
struct PanelView: View {
    @ObservedObject var store: Store
    @ViewState private var contentHeight: CGFloat = 320
    @ViewState private var showCredits = false
    @ViewState private var showInfo = false
    init(store: Store, expanded: Bool = false) {
        self.store = store
        _showCredits = ViewState(initialValue: expanded)
    }
    private var nearestExpiry: Date? {
        store.snapshot?.rateLimitResetCredits?.credits?.compactMap { $0.expiresAt }.min().map(Date.init(timeIntervalSince1970:))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: EnergyMark.image(remaining: store.snapshot?.mainWindow?.remaining, direction: store.depletionDirection)).foregroundStyle(Color.accentColor)
                Text("近星点").font(.headline).fixedSize()
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    if store.loading { ProgressView().controlSize(.mini) }
                    else { Circle().fill(store.error == nil ? Color.green : Color.orange).frame(width: 5, height: 5) }
                    Text(updateText).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }.help("\(updateText)\n\(dateText(store.updatedAt))")
                Button { store.refresh() } label: {
                    toolbarIcon("arrow.clockwise")
                }.buttonStyle(.plain).disabled(store.loading).help("刷新额度")
                Button { showInfo.toggle() } label: {
                    toolbarIcon("info.circle")
                }.buttonStyle(.plain)
                    .accessibilityLabel("查看额度说明")
                    .popover(isPresented: $showInfo, arrowEdge: .top) {
                        UsageInfoView { showInfo = false }
                    }
                Menu {
                    Picker("主题", selection: $store.theme) {
                        ForEach(AppTheme.allCases) { theme in Text(theme.title).tag(theme) }
                    }.pickerStyle(.menu)
                    Divider()
                    Picker("能量格熄灭方向", selection: $store.depletionDirection) {
                        ForEach(DepletionDirection.allCases) { direction in Text(direction.title).tag(direction) }
                    }.pickerStyle(.menu)
                    Picker("菜单栏显示", selection: $store.menuBarDisplay) {
                        ForEach(MenuBarDisplay.allCases) { mode in Text(mode.title).tag(mode) }
                    }.pickerStyle(.menu)
                    Picker("进度条分段", selection: $store.progressStyle) {
                        ForEach(ProgressStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }.pickerStyle(.menu)
                    Divider()
                    Button("连接与登录引导…") { store.showSetup = true; store.refresh() }
                    Button("选择 Codex CLI…") { store.chooseCLI() }
                    Divider()
                    Button("退出 近星点") { NSApp.terminate(nil) }
                } label: { toolbarIcon("gearshape") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).foregroundStyle(.secondary).fixedSize().help("设置")
            }
            ScrollView {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ContentHeightKey.self, value: geometry.size.height)
                    })
            }
            .frame(height: min(contentHeight, 480))
            .onPreferenceChange(ContentHeightKey.self) { height in
                if height > 0 && abs(contentHeight - height) > 0.5 { contentHeight = height }
            }

        }.padding(16).frame(width: 400)
        .background {
            if store.theme == .readable {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            }
        }
    }
    private func toolbarIcon(_ name: String) -> some View {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return Image(nsImage: image)
            .renderingMode(.original)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
    private var updateText: String {
        if store.loading { return "正在刷新…" }
        guard let date = store.updatedAt else { return "尚未获取额度" }
        let minutes = max(0, Int(store.now.timeIntervalSince(date) / 60))
        let relative = minutes == 0 ? "刚刚更新" : "\(minutes) 分钟前更新"
        return store.error == nil ? relative : "上次成功：\(shortDate(date))"
    }
    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.showSetup {
                SetupView(store: store)
            } else if let snapshot = store.snapshot {
                ForEach(snapshot.buckets, id: \.0) { key, bucket in
                    let name = bucket.limitName ?? (key == "codex" ? "Codex" : key)
                    ForEach(bucket.orderedWindows, id: \.0) { _, window in
                        WindowView(resetNews: store.resetNews, showsResetNews: key == "codex", resetCredits: snapshot.rateLimitResetCredits?.credits ?? [], title: windowTitle(name, window, plan: bucket.planType ?? store.planType), window: window, now: store.now, progressStyle: store.progressStyle).id(store.panelSession)
                    }
                }
                if snapshot.buckets.isEmpty { Text("当前账户未返回额度窗口。").foregroundStyle(.secondary) }
                if snapshot.rateLimitResetCredits != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Button { showCredits.toggle() } label: {
                        HStack {
                            Text("可用重置").font(.subheadline.weight(.medium))
                            Text(snapshot.rateLimitResetCredits?.availableCount.map { "\($0) 次" } ?? "暂无数据").font(.subheadline.weight(.semibold))
                            Spacer()
                            if let nearestExpiry {
                                Text("最近到期 \(creditExpirySummary(nearestExpiry, now: store.now))")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
                                    .help("到期时间：\(dateText(nearestExpiry))\n\(creditTimeRemaining(nearestExpiry, now: store.now))")
                            }
                            if let credits = snapshot.rateLimitResetCredits?.credits, !credits.isEmpty {
                                Image(systemName: showCredits ? "chevron.up" : "chevron.down")
                                    .foregroundStyle(.secondary).frame(width: 20, height: 20)
                            }
                        }.frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .disabled(snapshot.rateLimitResetCredits?.credits?.isEmpty != false)
                        .help(showCredits ? "收起到期明细" : "展开到期明细")
                        .accessibilityLabel(showCredits ? "收起重置机会明细" : "展开重置机会明细")
                    if showCredits, let credits = snapshot.rateLimitResetCredits?.credits {
                        Divider()
                        ForEach(Array(credits.sorted { ($0.expiresAt ?? .infinity) < ($1.expiresAt ?? .infinity) }.enumerated()), id: \.offset) { index, credit in
                            HStack {
                                Text("重置机会 \(index + 1)").foregroundStyle(.secondary)
                                Spacer()
                                let expiry = credit.expiresAt.map(Date.init(timeIntervalSince1970:))
                                Text(expiry.map { creditExpirySummary($0, now: store.now) } ?? "未提供到期时间")
                                    .lineLimit(1).minimumScaleFactor(0.85)
                                    .help("到期时间：\(dateText(expiry))\n\(creditTimeRemaining(expiry, now: store.now))")
                            }.font(.caption).monospacedDigit()
                        }
                    }
                }.padding(.horizontal, 2)
                }
            } else if store.error == nil {
                Text("正在读取本机 Codex 账户额度…").foregroundStyle(.secondary).padding(.vertical, 24)
            }
            if !store.showSetup, let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
