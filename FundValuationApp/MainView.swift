import SwiftUI
import Charts

struct MainView: View {
    @StateObject private var viewModel = FundViewModel()
    @AppStorage("fund_theme") private var themeMode: String = "system"
    @Environment(\.refresh) private var refreshAction
    @Environment(\.scenePhase) private var scenePhase

    @State private var showEditor = false
    @State private var showAIDrawer = false
    @State private var showSettings = false
    @State private var hasBeenInBackground = false
    @State private var periodicRefreshTask: Task<Void, Never>?

    @State private var editingFund: FundPosition?
    @State private var selectedSnapshot: FundSnapshot?

    var body: some View {
        NavigationStack {
            ZStack {
                pageBackground.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        summarySection
                        holdingHeader
                        sortHeaderRow
                        listSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 120)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    topBar
                }
                .refreshable {
                    await viewModel.refreshAll()
                }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                                showAIDrawer = true
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color(hex: 0x8E00FF), Color(hex: 0x4F39F6)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                Image(systemName: "sparkles")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 52, height: 52)
                            .shadow(color: Color(hex: 0xAD46FF).opacity(0.35), radius: 16, y: 8)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
                }

            }
            .navigationBarHidden(true)
        }
        .fullScreenCover(isPresented: $showEditor) {
            FundEditorView(
                editing: editingFund,
                viewModel: viewModel,
                displayName: editingFund.flatMap { fund in
                    viewModel.snapshots.first(where: { $0.id == fund.id })?.name
                },
                onDelete: { id in
                    viewModel.deleteFund(id)
                    showEditor = false
                    Task { await viewModel.refreshAll() }
                },
                onSave: { id, code, cost, shares in
                    if viewModel.addOrUpdateFund(editingID: id, code: code, costPrice: cost, shares: shares) {
                        showEditor = false
                        Task { await viewModel.refreshAll() }
                    }
                }
            )
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsPageView(viewModel: viewModel, themeMode: $themeMode)
        }
        .fullScreenCover(item: $selectedSnapshot) { snap in
            FundDetailPageView(
                snap: snap,
                viewModel: viewModel,
                totalAsset: viewModel.summary.totalAsset,
                fund: viewModel.funds.first(where: { $0.id == snap.id }),
                onClose: { selectedSnapshot = nil },
                onSave: { id, code, cost, shares in
                    if viewModel.addOrUpdateFund(editingID: id, code: code, costPrice: cost, shares: shares) {
                        Task { await viewModel.refreshAll() }
                    }
                },
                onDelete: { id in
                    viewModel.deleteFund(id)
                    selectedSnapshot = nil
                    Task { await viewModel.refreshAll() }
                }
            )
        }
        .fullScreenCover(isPresented: $showAIDrawer) {
            AIAnalysisPageView(viewModel: viewModel)
        }
        .task {
            viewModel.loadInitialData()
            await viewModel.refreshAll()
            startPeriodicRefresh()
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                if hasBeenInBackground {
                    Task { await viewModel.refreshAll() }
                    hasBeenInBackground = false
                }
                startPeriodicRefresh()
            case .inactive, .background:
                hasBeenInBackground = true
                periodicRefreshTask?.cancel()
                periodicRefreshTask = nil
            @unknown default:
                break
            }
        }
    }

    private func startPeriodicRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await viewModel.refreshAll()
            }
        }
    }

    private var pageBackground: Color {
        Color(hex: 0x1C1C1E)
    }

    private var topBar: some View {
        ZStack {
            Color(hex: 0x0A0A0A)
            HStack {
                Button {
                    if let refreshAction {
                        Task { await refreshAction() }
                    } else {
                        Task { await viewModel.refreshAll() }
                    }
                } label: {
                    ZStack {
                        if viewModel.isRefreshing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: 0xA1A1A1)))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.85))
                        }
                    }
                    .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isRefreshing)
                Spacer()
                Text("Fund Valuation")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.85))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 49)
        .background(Color(hex: 0x0A0A0A).ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(hex: 0x262626).opacity(0.2))
                .frame(height: 1)
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("账户总资产")
                .font(.system(size: 10))
                .tracking(1.1)
                .foregroundStyle(Color.white.opacity(0.45))

            Text(NumberFormat.signed(viewModel.summary.totalAsset, digits: 2, prefixYuan: false).replacingOccurrences(of: "+", with: ""))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)

            HStack(spacing: 32) {
                AssetMetric(
                    title: "当日收益",
                    value: NumberFormat.signed(viewModel.summary.totalTodayProfit, digits: 2, prefixYuan: false),
                    subValue: NumberFormat.signedPercent(viewModel.summary.totalTodayRate),
                    divider: true
                )
                AssetMetric(
                    title: "持有收益",
                    value: NumberFormat.signed(viewModel.summary.totalCumulativeProfit, digits: 2, prefixYuan: false),
                    subValue: NumberFormat.signedPercent(viewModel.summary.totalCumulativeRate),
                    divider: false
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 11)
        .frame(height: 135)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 6)
        )
    }

    private var holdingHeader: some View {
        HStack {
            Text("我的持仓")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button {
                editingFund = nil
                showEditor = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("添加")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(Color(hex: 0x4473BB)))
            }
            .buttonStyle(.plain)
        }
    }

    private var sortHeaderRow: some View {
        HStack(spacing: 0) {
            Spacer()
            Button {
                viewModel.toggleSort(.today)
            } label: {
                HStack(spacing: 2) {
                    Text("当日收益")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.37)
                        .textCase(.uppercase)
                    Image(systemName: sortIcon(for: .today))
                        .font(.system(size: 10))
                }
                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(viewModel.sortField == .today ? 0.8 : 0.45))
            }
            .buttonStyle(.plain)
            .frame(width: 82, alignment: .trailing)

            Button {
                viewModel.toggleSort(.cumulative)
            } label: {
                HStack(spacing: 2) {
                    Text("累计收益")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.37)
                        .textCase(.uppercase)
                    Image(systemName: sortIcon(for: .cumulative))
                        .font(.system(size: 10))
                }
                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(viewModel.sortField == .cumulative ? 0.8 : 0.45))
            }
            .buttonStyle(.plain)
            .frame(width: 82, alignment: .trailing)
        }
        .frame(height: 23)
        .padding(.horizontal, 16)
        .padding(.top, -12)
        .padding(.bottom, -8)
    }

    private func sortIcon(for field: SortField) -> String {
        if viewModel.sortField == field {
            return viewModel.sortOrder == .desc ? "chevron.down" : "chevron.up"
        }
        return "chevron.up.chevron.down"
    }

    private var listSection: some View {
        VStack(spacing: 0) {
            if viewModel.sortedSnapshots.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("暂无持仓")
                        .font(.headline)
                    Text("添加基金代码、成本价与持有份额即可查看估值与收益")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ForEach(Array(viewModel.sortedSnapshots.enumerated()), id: \.element.id) { index, snap in
                    Button {
                        selectedSnapshot = snap
                    } label: {
                        FundListRowView(snap: snap, dark: true)
                    }
                    .buttonStyle(.plain)
                    if index < viewModel.sortedSnapshots.count - 1 {
                        Divider()
                            .overlay(Color(hex: 0x262626).opacity(0.2))
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(hex: 0x0A0A0A))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(hex: 0x262626).opacity(0.2), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        )
    }

}

private struct AssetMetric: View {
    let title: String
    let value: String
    let subValue: String?
    let divider: Bool

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10))
                    .tracking(1.1)
                    .foregroundStyle(Color.white.opacity(0.4))
                Text(value)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(fgColor(value))
                if let subValue {
                    Text(subValue)
                        .font(.system(size: 12))
                        .foregroundStyle(fgColor(subValue))
                }
            }
            if divider {
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1, height: 56)
            }
        }
    }

    private func fgColor(_ text: String) -> Color {
        if text.contains("+") { return Color(hex: 0xFF0005) }
        if text.contains("-") { return Color(hex: 0x00A63E) }
        return .white
    }
}

private struct FundListRowView: View {
    let snap: FundSnapshot
    let dark: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snap.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(dark ? .white : Color(hex: 0x0A0A0A))
                HStack(spacing: 6) {
                    if snap.hasTodayNav {
                        Text("已更新")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(dark ? Color(hex: 0x34D399) : Color(hex: 0x059669))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(dark ? Color(hex: 0x064E3B).opacity(0.8) : Color(hex: 0xD1FAE5))
                            )
                    }
                    Text(NumberFormat.signed(snap.holdValue, digits: 2, prefixYuan: false).replacingOccurrences(of: "+", with: ""))
                        .font(.system(size: 12))
                        .foregroundStyle((dark ? Color(hex: 0xA1A1A1) : Color(hex: 0x717182)).opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(NumberFormat.signed(snap.todayProfit, digits: 2))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colorFor(snap.todayProfit))
                Text(NumberFormat.signedPercent(snap.todayRate))
                    .font(.system(size: 12))
                    .foregroundStyle(colorFor(snap.todayProfit))
            }
            .frame(width: 82, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 2) {
                Text(NumberFormat.signed(snap.cumulativeProfit, digits: 2))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colorFor(snap.cumulativeProfit))
                Text(NumberFormat.signedPercent(snap.cumulativeRate))
                    .font(.system(size: 12))
                    .foregroundStyle(colorFor(snap.cumulativeProfit))
            }
            .frame(width: 82, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 68)
    }

    private func colorFor(_ v: Double?) -> Color {
        guard let v else { return .secondary }
        if v > 0 { return Color(hex: 0xFB2C36) }
        if v < 0 { return Color(hex: 0x00A63E) }
        return .secondary
    }
}

private struct FundDetailPageView: View {
    let snap: FundSnapshot
    @ObservedObject var viewModel: FundViewModel
    let totalAsset: Double
    let fund: FundPosition?
    let onClose: () -> Void
    let onSave: (_ editingID: String?, _ code: String, _ cost: Double, _ shares: Double) -> Void
    let onDelete: (_ id: String) -> Void

    @State private var showEditor = false
    @State private var dailyPerformanceTrend: [DailyPerformancePoint] = []
    @State private var csi300Trend: [DailyPerformancePoint] = []
    @State private var performanceRange: PerformanceRange = .m3

    private var currentSnap: FundSnapshot {
        viewModel.snapshots.first(where: { $0.id == snap.id }) ?? snap
    }

    private var weightText: String {
        guard totalAsset > 0, let hold = currentSnap.holdValue else { return "--" }
        return NumberFormat.fixed(hold / totalAsset * 100, digits: 2) + "%"
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(hex: 0x1C1C1E).ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    HStack {
                        Button(action: onClose) {
                            HStack(spacing: 2) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 16, weight: .medium))
                                Text("返回")
                                    .font(.system(size: 16, weight: .medium))
                            }
                            .foregroundStyle(Color(hex: 0x2B7FFF))
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 72, alignment: .leading)
                        Spacer()
                        Button {
                            if fund != nil { showEditor = true }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 14, weight: .medium))
                                Text("编辑")
                                    .font(.system(size: 16, weight: .medium))
                            }
                            .foregroundStyle(Color(hex: 0x2B7FFF))
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 72, alignment: .trailing)
                    }
                    Text("持仓详情")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .frame(height: 49)
                .background(Color(hex: 0x0A0A0A))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color(hex: 0x262626).opacity(0.2)).frame(height: 1)
                }

                ScrollView {
                    VStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(currentSnap.code)
                                .font(.system(size: 13))
                                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.6))
                            Text(currentSnap.name)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("当日涨幅")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.5))
                                        Text(NumberFormat.signedPercent(currentSnap.todayRate))
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundStyle(colorFor(currentSnap.todayRate))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("当日收益")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.5))
                                        Text(NumberFormat.signed(currentSnap.todayProfit, digits: 2))
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundStyle(colorFor(currentSnap.todayProfit))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Text(currentSnap.hasTodayNav
                                    ? "净值日期 \(DateHelper.formatDataDateDisplay(currentSnap.dataDate))"
                                    : "估值时间 \(DateHelper.formatValuationTimeWithDate(currentSnap.valuationTime))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.45))
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 12)
                        .background(Color(hex: 0x0A0A0A))

                        detailsGrid
                        chartSection
                    }
                }
            }
        }
        .swipeBackGesture(onBack: onClose)
        .fullScreenCover(isPresented: $showEditor) {
            if let fund {
                FundEditorView(
                    editing: fund,
                    viewModel: viewModel,
                    displayName: currentSnap.name,
                    onDelete: { id in
                        onDelete(id)
                        showEditor = false
                    },
                    onSave: { id, code, cost, shares in
                        onSave(id, code, cost, shares)
                        showEditor = false
                    }
                )
            }
        }
    }

    private var detailsGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                detailCell("持有金额", NumberFormat.fixed(currentSnap.holdValue, digits: 2))
                detailCell("持有份额", NumberFormat.fixed(currentSnap.shares, digits: 2))
                detailCell("持仓占比", weightText, showRightDivider: false)
            }
            Divider().overlay(Color(hex: 0x262626).opacity(0.1))
            HStack(spacing: 0) {
                detailCell("持有收益", NumberFormat.signed(currentSnap.cumulativeProfit, digits: 2, prefixYuan: false), color: colorFor(currentSnap.cumulativeProfit))
                detailCell("持有收益率", NumberFormat.signedPercent(currentSnap.cumulativeRate), color: colorFor(currentSnap.cumulativeProfit))
                detailCell("持仓成本", NumberFormat.fixed(currentSnap.costPrice, digits: 4), showRightDivider: false)
            }
        }
        .frame(height: 124)
        .background(Color(hex: 0x0A0A0A))
    }

    private var chartSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("业绩走势")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider().overlay(Color(hex: 0x262626).opacity(0.15))
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 20) {
                    (Text("本基金 ").foregroundColor(.white) + Text(NumberFormat.signedPercent(dailyPerformanceTrend.last?.cumulativeReturn)).foregroundColor(colorFor(dailyPerformanceTrend.last?.cumulativeReturn)))
                        .font(.system(size: 13, weight: .semibold))
                    (Text("沪深300 ").foregroundColor(.white) + Text(NumberFormat.signedPercent(csi300Trend.last?.cumulativeReturn)).foregroundColor(colorFor(csi300Trend.last?.cumulativeReturn)))
                        .font(.system(size: 13, weight: .semibold))
                }

                FundDailyPerformanceChartView(
                    fundPoints: dailyPerformanceTrend,
                    indexPoints: csi300Trend,
                    darkMode: true
                )
                .frame(height: 173)

                GeometryReader { geo in
                    let w = max(1, (geo.size.width - 8) / 5)
                    HStack(spacing: 2) {
                        ForEach(PerformanceRange.allCases, id: \.self) { r in
                            Button {
                                performanceRange = r
                            } label: {
                                Text(r.rawValue)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(performanceRange == r ? .white : Color(hex: 0xA1A1A1).opacity(0.7))
                                    .frame(width: w)
                                    .padding(.vertical, 6)
                                    .background(performanceRange == r ? Color(hex: 0x2B7FFF).opacity(0.35) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: 36)
            }
            .padding(16)
        }
        .background(Color(hex: 0x0A0A0A))
        .task(id: "\(currentSnap.code)_\(performanceRange.rawValue)") {
            let (fund, index) = await viewModel.fetchPerformanceTrend(fundCode: currentSnap.code, range: performanceRange)
            dailyPerformanceTrend = fund
            csi300Trend = index
        }
    }

    private func detailCell(_ title: String, _ value: String, color: Color = .white, showRightDivider: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.55))
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.leading, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            if showRightDivider {
                Rectangle()
                    .fill(Color(hex: 0x262626).opacity(0.1))
                    .frame(width: 1)
            }
        }
    }

    private func colorFor(_ v: Double?) -> Color {
        guard let v else { return .white }
        if v > 0 { return Color(hex: 0xFB2C36) }
        if v < 0 { return Color(hex: 0x00A63E) }
        return .white
    }
}

private struct SettingsPageView: View {
    @ObservedObject var viewModel: FundViewModel
    @Binding var themeMode: String
    @Environment(\.dismiss) private var dismiss

    @State private var showModelConfig = false
    @State private var editModel = ""
    @State private var editEndpoint = ""
    @State private var editApiKey = ""
    @State private var testStatus = ""

    var body: some View {
        ZStack {
            Color(hex: 0x1C1C1E).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .medium))
                            Text("返回")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundStyle(Color(hex: 0x2B7FFF))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("设置")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Color.clear.frame(width: 58, height: 24)
                }
                .padding(.horizontal, 16)
                .frame(height: 49)
                .background(Color(hex: 0x0A0A0A))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color(hex: 0x262626).opacity(0.2)).frame(height: 1)
                }

                ScrollView {
                    VStack(spacing: 8) {
                        sectionTitle("AI 智能分析")

                        settingCard {
                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    showModelConfig.toggle()
                                    if showModelConfig {
                                        editModel = viewModel.aiConfig.model
                                        editEndpoint = viewModel.aiConfig.endpoint
                                        editApiKey = viewModel.aiConfig.apiKey
                                        testStatus = ""
                                    }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "cpu")
                                        .font(.system(size: 18))
                                        .foregroundStyle(Color(hex: 0xFAFAFA))
                                        .frame(width: 18, height: 18)
                                    Text("模型配置")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Color(hex: 0xFAFAFA))
                                    Spacer()
                                    Text(viewModel.aiConfig.model)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.5))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.5))
                                        .rotationEffect(.degrees(showModelConfig ? 90 : 0))
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 50.5)
                            }
                            .buttonStyle(.plain)

                            if showModelConfig {
                                Rectangle()
                                    .fill(Color(hex: 0x262626).opacity(0.2))
                                    .frame(height: 1)
                                    .padding(.horizontal, 16)

                                VStack(spacing: 14) {
                                    settingsField(label: "模型名称", text: $editModel)
                                    settingsField(label: "API ENDPOINT", text: $editEndpoint)
                                    settingsField(label: "API KEY", text: $editApiKey, isSecure: true)

                                    HStack(spacing: 10) {
                                        Button {
                                            viewModel.aiConfig.model = editModel
                                            viewModel.aiConfig.endpoint = editEndpoint
                                            viewModel.aiConfig.apiKey = editApiKey
                                            viewModel.saveAIConfig()
                                        } label: {
                                            Text("保存")
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundStyle(.white)
                                                .frame(maxWidth: .infinity, minHeight: 41)
                                                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x2B7FFF)))
                                        }
                                        .buttonStyle(.plain)

                                        Button {
                                            testStatus = "测试中..."
                                            Task {
                                                viewModel.aiConfig.model = editModel
                                                viewModel.aiConfig.endpoint = editEndpoint
                                                viewModel.aiConfig.apiKey = editApiKey
                                                viewModel.saveAIConfig()
                                                await viewModel.runAIAnalysis(mode: .realtime, auto: false)
                                                testStatus = viewModel.isAiRunning ? "测试中..." : "测试完成"
                                            }
                                        } label: {
                                            Text(testStatus.isEmpty ? "测试" : testStatus)
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundStyle(Color(hex: 0xFAFAFA))
                                                .frame(maxWidth: .infinity, minHeight: 41)
                                                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x262626).opacity(0.6)))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.top, 4)
                                }
                                .padding(16)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                }
            }
        }
        .swipeBackGesture(onBack: { dismiss() })
    }

    private func sectionTitle(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
                .tracking(1.16)
                .textCase(.uppercase)
                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.5))
                .padding(.leading, 4)
            Spacer()
        }
    }

    private func settingsField(label: String, text: Binding<String>, isSecure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .tracking(0.34)
                .textCase(.uppercase)
                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.6))
            Group {
                if isSecure {
                    SecureField("", text: text)
                } else {
                    TextField("", text: text)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(Color(hex: 0xFAFAFA).opacity(0.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(height: 43)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: 0x2C2C2E))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0x262626).opacity(0.2), lineWidth: 1))
            )
        }
    }

    private func settingCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(hex: 0x0A0A0A))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: 0x262626).opacity(0.2), lineWidth: 1))
                .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
        )
    }
}

/// 业绩走势图数据点（供 PerformanceChartView 使用）
private struct PerformanceChartPoint: Identifiable {
    let id: String
    let index: Int
    let date: String
    let value: Double
    let series: String
}

/// 业绩走势图 X 轴修饰器（仅网格线，标签用自定义 overlay 避免被裁剪）
private struct PerformanceChartXAxisModifier: ViewModifier {
    let tickIndices: [Int]
    let mergedDataCount: Int
    let axisGridColor: Color

    func body(content: Content) -> some View {
        let scaled = content.chartXScale(domain: 0...Double(max(0, mergedDataCount - 1)))
        return scaled.chartXAxis {
            AxisMarks(values: tickIndices.map { Double($0) }) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2]))
                    .foregroundStyle(axisGridColor)
                AxisValueLabel { EmptyView() }
            }
        }
    }
}

/// 业绩走势图主体（Chart + X 轴），拆成独立 struct 以减轻编译器负担
private struct PerformanceChartView: View {
    let seriesData: [PerformanceChartPoint]
    let minY: Double
    let maxY: Double
    let tickIndices: [Int]
    let mergedDataCount: Int
    let axisGridColor: Color

    var body: some View {
        chartWithScales
            .modifier(PerformanceChartXAxisModifier(
                tickIndices: tickIndices,
                mergedDataCount: mergedDataCount,
                axisGridColor: axisGridColor
            ))
    }

    private var chartWithScales: some View {
        chartWithStyle
            .chartLegend(.hidden)
            .chartYScale(domain: minY...maxY)
    }

    private var chartWithStyle: some View {
        lineChart.chartForegroundStyleScale([
            "本基金": Color(hex: 0x2B7FFF),
            "沪深300": Color(hex: 0xFF9500)
        ])
    }

    private var lineChart: some View {
        Chart(seriesData) { p in
            lineMark(for: p)
        }
    }

    private func lineMark(for p: PerformanceChartPoint) -> some ChartContent {
        LineMark(
            x: .value("序号", p.index),
            y: .value("涨跌幅", p.value),
            series: .value("系列", p.series)
        )
        .interpolationMethod(.linear)
        .foregroundStyle(by: .value("系列", p.series))
        .lineStyle(StrokeStyle(lineWidth: 2))
    }
}

/// 业绩走势图 Y 轴修饰器，拆出以减轻编译器负担
private struct ChartYAxisModifier: ViewModifier {
    let axisGridColor: Color
    let axisLabelColor: Color

    func body(content: Content) -> some View {
        content.chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2]))
                    .foregroundStyle(axisGridColor)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(yAxisLabelText(v))
                            .font(.system(size: 9))
                            .foregroundStyle(axisLabelColor)
                    }
                }
            }
        }
    }

    private func yAxisLabelText(_ v: Double) -> String {
        String(format: "%.2f%%", v)
    }
}

/// 业绩走势双线折线图（本基金蓝线 + 沪深300橙线，起点0，横轴仅交易日）
private struct FundDailyPerformanceChartView: View {
    let fundPoints: [DailyPerformancePoint]
    let indexPoints: [DailyPerformancePoint]
    var darkMode: Bool = false

    private struct ChartPoint: Identifiable {
        let id: Int
        let date: String
        let fundReturn: Double
        let indexReturn: Double
    }

    private var hasIndexData: Bool { !indexPoints.isEmpty }

    /// 横轴日期：今年只显示 MM-dd，其他年份显示 yyyy-MM-dd
    private func formatChartAxisDate(_ ymd: String) -> String {
        let parts = ymd.split(separator: "-")
        guard parts.count >= 3 else { return ymd }
        let year = Int(parts[0]) ?? 0
        let currentYear = Calendar.current.component(.year, from: Date())
        if year == currentYear {
            return "\(parts[1])-\(parts[2])"
        }
        return "\(parts[0])-\(parts[1])-\(parts[2])"
    }

    /// 合并数据：有沪深300时按日期对齐双线，无时仅本基金
    private var mergedData: [ChartPoint] {
        let indexByDate = Dictionary(uniqueKeysWithValues: indexPoints.map { ($0.date, $0.cumulativeReturn) })
        var result: [ChartPoint] = []
        for (i, p) in fundPoints.enumerated() {
            let idxRet = indexByDate[p.date] ?? .nan
            if hasIndexData && idxRet.isNaN { continue }
            result.append(ChartPoint(id: i, date: p.date, fundReturn: p.cumulativeReturn, indexReturn: idxRet.isNaN ? 0 : idxRet))
        }
        return result
    }

    private var seriesData: [PerformanceChartPoint] {
        var out: [PerformanceChartPoint] = []
        for p in mergedData {
            out.append(PerformanceChartPoint(id: "f_\(p.id)", index: p.id, date: p.date, value: p.fundReturn, series: "本基金"))
            if hasIndexData {
                out.append(PerformanceChartPoint(id: "i_\(p.id)", index: p.id, date: p.date, value: p.indexReturn, series: "沪深300"))
            }
        }
        return out
    }

    private var axisLabelColor: Color {
        .white
    }

    private var axisGridColor: Color {
        (darkMode ? Color(hex: 0xA1A1A1) : Color(hex: 0x717182)).opacity(0.2)
    }

    @ViewBuilder
    private var chartContent: some View {
        if mergedData.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                Text("暂无业绩数据").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            chartWithAxis
        }
    }

    private var chartYRange: (min: Double, max: Double) {
        let allReturns = mergedData.flatMap { [$0.fundReturn, $0.indexReturn] }
        let minY = (allReturns.min() ?? -5) - 1
        let maxY = (allReturns.max() ?? 5) + 1
        return (minY, maxY)
    }

    private var chartTickIndices: [Int] {
        guard !mergedData.isEmpty else { return [] }
        let last = mergedData.count - 1
        return [0, last / 2, last]
    }

    private var chartWithAxis: some View {
        chartWithAxisContent.modifier(ChartYAxisModifier(
            axisGridColor: axisGridColor,
            axisLabelColor: axisLabelColor
        ))
    }

    private var chartWithAxisContent: some View {
        ZStack(alignment: .bottom) {
            chartBody(minY: chartYRange.min, maxY: chartYRange.max, tickIndices: chartTickIndices)
            xAxisLabels(tickIndices: chartTickIndices)
        }
    }

    private func chartBody(minY: Double, maxY: Double, tickIndices: [Int]) -> some View {
        PerformanceChartView(
            seriesData: seriesData,
            minY: minY,
            maxY: maxY,
            tickIndices: tickIndices,
            mergedDataCount: mergedData.count,
            axisGridColor: axisGridColor
        )
        .padding(.bottom, 18)
    }

    private let plotLeadingInset: CGFloat = 28
    private let labelMinWidth: CGFloat = 52

    @ViewBuilder
    private func xAxisLabels(tickIndices: [Int]) -> some View {
        if tickIndices.count >= 3 {
            let last = tickIndices[2]
            let mid = tickIndices[1]
            GeometryReader { geo in
                let w = geo.size.width
                let plotW = w - plotLeadingInset
                let leftX = plotLeadingInset + (last > 0 ? CGFloat(tickIndices[0]) / CGFloat(last) * plotW : 0)
                let midX = plotLeadingInset + (last > 0 ? CGFloat(mid) / CGFloat(last) * plotW : plotW / 2)
                let rightX = w
                HStack(spacing: 0) {
                    Color.clear.frame(width: leftX)
                    axisLabel(mergedData[tickIndices[0]].date)
                        .frame(width: labelMinWidth, alignment: .leading)
                    axisLabel(mergedData[tickIndices[1]].date)
                        .frame(maxWidth: .infinity, alignment: .center)
                    axisLabel(mergedData[tickIndices[2]].date)
                        .frame(width: labelMinWidth, alignment: .trailing)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }
            .frame(height: 20)
        }
    }

    private func axisLabel(_ dateStr: String) -> some View {
        Text(formatChartAxisDate(dateStr))
            .font(.system(size: 9))
            .foregroundColor(axisLabelColor)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    var body: some View {
        chartContent
    }
}

private struct FundEditorView: View {
    let editing: FundPosition?
    @ObservedObject var viewModel: FundViewModel
    let displayName: String?
    let onDelete: (_ id: String) -> Void
    let onSave: (_ editingID: String?, _ code: String, _ cost: Double, _ shares: Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var cost = ""
    @State private var shares = ""
    @State private var isSaving = false
    @State private var showInvalidCodeAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: 0x1C1C1E).ignoresSafeArea()
                VStack(spacing: 0) {
                    ZStack {
                        HStack {
                            Button("取消") { dismiss() }
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color(hex: 0x2B7FFF))
                                .frame(minWidth: 72, alignment: .leading)
                            Spacer()
                            Button("保存") {
                                guard let c = Double(cost), let s = Double(shares) else { return }
                                guard !isSaving else { return }
                                isSaving = true
                                Task {
                                    let valid = await viewModel.validateFundCode(code)
                                    await MainActor.run {
                                        isSaving = false
                                        if valid {
                                            onSave(editing?.id, code, c, s)
                                        } else {
                                            showInvalidCodeAlert = true
                                        }
                                    }
                                }
                            }
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isValid && !isSaving ? Color(hex: 0x2B7FFF) : Color(hex: 0xA1A1A1).opacity(0.3))
                            .disabled(!isValid || isSaving)
                            .frame(minWidth: 72, alignment: .trailing)
                        }
                        Text(editing == nil ? "添加持仓" : "编辑持仓")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 49)
                    .background(Color(hex: 0x0A0A0A))
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color(hex: 0x262626).opacity(0.2)).frame(height: 1)
                    }

                    ScrollView {
                        VStack(spacing: 12) {
                            HStack(spacing: 10) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.4))
                                TextField("输入基金代码", text: $code)
                                    .keyboardType(.numberPad)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white)
                                    .tint(.white)
                                if !code.isEmpty {
                                    Button {
                                        code = ""
                                    } label: {
                                        Text("✕")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.4))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 52.5)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(hex: 0x0A0A0A))
                                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: 0x262626).opacity(0.2), lineWidth: 1))
                                    .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                            )

                            if let displayName, editing != nil {
                                HStack(spacing: 10) {
                                    Image(systemName: "checkmark.circle")
                                        .font(.system(size: 16))
                                        .foregroundStyle(Color(hex: 0x51A2FF))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(displayName)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(Color(hex: 0xDBEAFE))
                                        Text("基金类型信息")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color(hex: 0x51A2FF).opacity(0.6))
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 17)
                                .frame(height: 67)
                                .background(
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(Color(hex: 0x1C398E).opacity(0.2))
                                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0x1447E6).opacity(0.3), lineWidth: 1))
                                )
                            }

                            VStack(spacing: 0) {
                                rowField(title: "持仓成本", prefix: nil, text: $cost)
                                Divider().overlay(Color(hex: 0x262626).opacity(0.15))
                                rowField(title: "持有份额", prefix: nil, text: $shares)
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(hex: 0x0A0A0A))
                                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: 0x262626).opacity(0.2), lineWidth: 1))
                                    .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                            )

                            if let editing {
                                Button {
                                    onDelete(editing.id)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 16))
                                        Text("删除持仓")
                                            .font(.system(size: 15, weight: .medium))
                                    }
                                    .foregroundStyle(Color(hex: 0xFB2C36))
                                    .frame(maxWidth: .infinity, minHeight: 52.5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(Color(hex: 0x0A0A0A))
                                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: 0x82181A).opacity(0.5), lineWidth: 1))
                                            .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    }
                }
            }
        }
        .onAppear {
            guard let editing else { return }
            code = editing.fundCode
            cost = NumberFormat.fixed(editing.costPrice, digits: 4)
            shares = NumberFormat.fixed(editing.shares, digits: 4)
        }
        .alert("基金代码无效", isPresented: $showInvalidCodeAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text("请检查基金代码是否正确，无法从服务器获取该基金数据")
        }
    }

    private var isValid: Bool {
        FundPosition.normalizeCode(code).count == 6 && (Double(cost) ?? 0) > 0 && (Double(shares) ?? 0) > 0
    }

    private func rowField(title: String, prefix: String?, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(.white)
            Spacer()
            if let prefix {
                Text(prefix)
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.5))
            }
            TextField("", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .tint(.white)
        }
        .padding(.horizontal, 16)
        .frame(height: 51.5)
    }
}

private struct AIAnalysisPageView: View {
    @ObservedObject var viewModel: FundViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            (dark ? Color(hex: 0x0A0A0A) : Color.white).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .medium))
                            Text("返回")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundStyle(Color(hex: 0x2B7FFF))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("AI 智能分析")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Color.clear.frame(width: 32, height: 24)
                }
                .padding(.horizontal, 16)
                .frame(height: 49)
                .background(Color(hex: 0x0A0A0A))

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            Task { await viewModel.runAIAnalysis(mode: .realtime, auto: false) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                Text(viewModel.isAiRunning ? "分析中..." : "重新分析")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 54.5)
                            .background(
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(LinearGradient(colors: [Color(hex: 0x8E00FF), Color(hex: 0x4F39F6)], startPoint: .leading, endPoint: .trailing))
                                    .shadow(color: Color(hex: 0xAD46FF).opacity(0.25), radius: 16, y: 8)
                            )
                        }
                        .disabled(viewModel.isAiRunning)
                        .buttonStyle(.plain)

                        aiOutputCard(dark: dark)
                        aiRiskCard(dark: dark)

                        Text(viewModel.aiStatus.replacingOccurrences(of: "自动分析完成：", with: "分析时间："))
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity)
                            .foregroundStyle((dark ? Color(hex: 0xA1A1A1) : Color(hex: 0x717182)).opacity(0.4))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }
            }
        }
        .swipeBackGesture(onBack: { dismiss() })
    }

    private func aiOutputCard(dark: Bool) -> some View {
        let textColor = dark ? Color(hex: 0xDBEAFE).opacity(0.85) : Color(hex: 0x1C398E).opacity(0.85)
        let headingColor = dark ? Color(hex: 0xDBEAFE) : Color(hex: 0x1C398E)
        return VStack(alignment: .leading, spacing: 12) {
            Label("AI 分析报告", systemImage: "sparkles")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(headingColor)

            if viewModel.aiOutput.isEmpty && !viewModel.isAiRunning {
                Text("当前暂无分析结果，请点击\"重新分析\"获取建议。")
                    .font(.system(size: 14))
                    .foregroundStyle(dark ? Color(hex: 0xDBEAFE).opacity(0.75) : Color(hex: 0x1C398E).opacity(0.8))
            } else {
                MarkdownBlockView(raw: viewModel.aiOutput, textColor: textColor, headingColor: headingColor, accentColor: Color(hex: 0x2B7FFF))
                if viewModel.isAiRunning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(dark ? Color(hex: 0xDBEAFE).opacity(0.6) : Color(hex: 0x1C398E).opacity(0.6))
                        Text("正在生成...")
                            .font(.system(size: 12))
                            .foregroundStyle(dark ? Color(hex: 0xDBEAFE).opacity(0.5) : Color(hex: 0x1C398E).opacity(0.5))
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    dark
                        ? LinearGradient(colors: [Color(hex: 0x1C398E).opacity(0.2), Color(hex: 0x59168B).opacity(0.15), Color(hex: 0x312C85).opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [Color(hex: 0xEFF6FF), Color(hex: 0xFAF5FF), Color(hex: 0xEEF2FF)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(dark ? Color(hex: 0x193CB8).opacity(0.3) : Color(hex: 0xDBEAFE).opacity(0.8), lineWidth: 1))
        )
    }

    private func aiRiskCard(dark: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(dark ? Color(hex: 0xFEE685).opacity(0.7) : Color(hex: 0xE17100))
            Text("风险提示：AI 分析仅供参考，不构成投资建议。投资有风险，入市须谨慎。")
                .font(.system(size: 12))
                .foregroundStyle(dark ? Color(hex: 0xFEE685).opacity(0.7) : Color(hex: 0x7B3306).opacity(0.8))
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(dark ? Color(hex: 0x7B3306).opacity(0.2) : Color(hex: 0xFFFBEB))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(dark ? Color(hex: 0x973C00).opacity(0.3) : Color(hex: 0xFEF3C6), lineWidth: 1))
        )
    }
}

private struct MarkdownBlockView: View {
    let raw: String
    let textColor: Color
    let headingColor: Color
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(raw.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                renderLine(line)
            }
        }
    }

    @ViewBuilder
    private func renderLine(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 4)
        } else if trimmed.hasPrefix("### ") {
            inlineMarkdown(String(trimmed.dropFirst(4)))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(headingColor)
                .padding(.top, 6)
        } else if trimmed.hasPrefix("## ") {
            inlineMarkdown(String(trimmed.dropFirst(3)))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(headingColor)
                .padding(.top, 8)
        } else if trimmed.hasPrefix("# ") {
            inlineMarkdown(String(trimmed.dropFirst(2)))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(headingColor)
                .padding(.top, 10)
        } else if let olMatch = trimmed.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
            let content = String(trimmed[olMatch.upperBound...])
            let prefix = String(trimmed[..<olMatch.upperBound])
            HStack(alignment: .top, spacing: 0) {
                inlineMarkdown(prefix)
                    .font(.system(size: 14))
                    .foregroundStyle(textColor)
                    .frame(width: 24, alignment: .leading)
                inlineMarkdown(content)
                    .font(.system(size: 14))
                    .foregroundStyle(textColor)
                    .lineSpacing(5)
            }
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.system(size: 14))
                    .foregroundStyle(textColor)
                    .frame(width: 10, alignment: .leading)
                inlineMarkdown(String(trimmed.dropFirst(2)))
                    .font(.system(size: 14))
                    .foregroundStyle(textColor)
                    .lineSpacing(5)
            }
        } else if trimmed.hasPrefix("---") || trimmed.hasPrefix("***") {
            Divider().overlay(headingColor.opacity(0.2)).padding(.vertical, 4)
        } else {
            inlineMarkdown(trimmed)
                .font(.system(size: 14))
                .foregroundStyle(textColor)
                .lineSpacing(5)
        }
    }

    private func inlineMarkdown(_ text: String) -> Text {
        if let attr = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(text)
    }
}

private extension View {
    /// 从屏幕左边缘右滑返回上一页（仅左侧窄条响应，避免影响输入框等交互）
    func swipeBackGesture(onBack: @escaping () -> Void) -> some View {
        overlay(alignment: .leading) {
            Color.clear
                .frame(width: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            if value.translation.width > 80 { onBack() }
                        }
                )
        }
    }
}

private extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
