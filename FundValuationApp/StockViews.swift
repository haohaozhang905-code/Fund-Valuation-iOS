import SwiftUI

private enum StockVisual {
    static let pageBackground = Color(hex: 0x1C1C1E)
    static let topBarBackground = Color(hex: 0x0A0A0A)
    static let cardBackground = Color(hex: 0x0A0A0A)
    static let elevatedBackground = Color(hex: 0x2C2C2E)
    static let selectedBackground = Color(hex: 0x2C2C2E)
    static let separator = Color(hex: 0x262626).opacity(0.2)
    static let secondaryText = Color(hex: 0xA1A1A1)
    static let accent = Color(hex: 0x2B7FFF)
}

struct StockTabView: View {
    @ObservedObject var viewModel: StockViewModel
    var onPortfolioChanged: () -> Void = {}

    @State private var showEditor = false
    @State private var editingPosition: StockPosition?
    @State private var selectedSnapshot: StockSnapshot?

    var body: some View {
        VStack(spacing: 16) {
            summarySection
            sortHeaderRow
            listSection
        }
        .fullScreenCover(isPresented: $showEditor) {
            StockEditorView(
                editing: editingPosition,
                viewModel: viewModel,
                displayName: editingPosition.flatMap { position in
                    viewModel.snapshots.first(where: { $0.id == position.id })?.name
                },
                onDelete: { id in
                    viewModel.deletePosition(id)
                    onPortfolioChanged()
                    showEditor = false
                },
                onSave: { id, symbol, cost, shares, displayName in
                    if viewModel.addOrUpdatePosition(editingID: id, symbol: symbol, averageCost: cost, shares: shares, displayName: displayName) {
                        onPortfolioChanged()
                        showEditor = false
                        Task { await viewModel.refreshAll() }
                    }
                }
            )
        }
        .fullScreenCover(item: $selectedSnapshot) { snap in
            StockDetailPageView(
                snap: snap,
                viewModel: viewModel,
                position: viewModel.positions.first(where: { $0.id == snap.id }),
                onClose: { selectedSnapshot = nil },
                onDelete: { id in
                    viewModel.deletePosition(id)
                    onPortfolioChanged()
                    selectedSnapshot = nil
                },
                onSave: { id, symbol, cost, shares, displayName in
                    if viewModel.addOrUpdatePosition(editingID: id, symbol: symbol, averageCost: cost, shares: shares, displayName: displayName) {
                        onPortfolioChanged()
                        Task { await viewModel.refreshAll() }
                    }
                }
            )
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("美股资产")
                .font(.system(size: 10))
                .tracking(1.1)
                .foregroundStyle(Color.white.opacity(0.45))

            Text(NumberFormat.usd(viewModel.summary.totalMarketValue))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)

            HStack(spacing: 0) {
                StockAssetMetric(
                    title: "当日盈亏",
                    value: NumberFormat.signedUSD(viewModel.summary.totalTodayProfit),
                    subValue: NumberFormat.signedPercent(viewModel.summary.totalTodayRate),
                    divider: false
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1, height: 56)
                    .padding(.horizontal, 16)
                StockAssetMetric(
                    title: "累计盈亏",
                    value: NumberFormat.signedUSD(viewModel.summary.totalHoldingProfit),
                    subValue: NumberFormat.signedPercent(viewModel.summary.totalHoldingRate),
                    divider: false
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, 78)

            Text("行情更新 \(USMarketHours.combinedDisplayTime(viewModel.summary.latestUpdatedAt))")
                .font(.system(size: 10))
                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.5))
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 11)
        .frame(height: 150)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            Text(viewModel.summary.marketState.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(hex: 0xDBEAFE))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1C398E).opacity(0.75)))
                .padding(.trailing, 16)
                .padding(.top, 16)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                editingPosition = nil
                showEditor = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(Color(hex: 0x2C2C2E))
                            .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.bottom, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 6)
        )
    }

    private var sortHeaderRow: some View {
        HStack(spacing: 0) {
            Spacer()
            Button {
                viewModel.toggleSort(.todayProfit)
            } label: {
                sortLabel("当日盈亏", field: .todayProfit)
            }
            .buttonStyle(.plain)
            .frame(width: 82, alignment: .trailing)

            Button {
                viewModel.toggleSort(.holdingProfit)
            } label: {
                sortLabel("累计盈亏", field: .holdingProfit)
            }
            .buttonStyle(.plain)
            .frame(width: 82, alignment: .trailing)
        }
        .frame(height: 23)
        .padding(.horizontal, 16)
        .padding(.top, -4)
        .padding(.bottom, -8)
    }

    private func sortLabel(_ title: String, field: StockSortField) -> some View {
        HStack(spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.37)
                .textCase(.uppercase)
            Image(systemName: sortIcon(for: field))
                .font(.system(size: 10))
        }
        .foregroundStyle(StockVisual.secondaryText.opacity(viewModel.sortField == field ? 0.82 : 0.48))
    }

    private func sortIcon(for field: StockSortField) -> String {
        if viewModel.sortField == field {
            return viewModel.sortOrder == .desc ? "chevron.down" : "chevron.up"
        }
        return "chevron.up.chevron.down"
    }

    private var listSection: some View {
        let snapshots = viewModel.sortedSnapshots
        return VStack(spacing: 0) {
            if viewModel.positions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("暂无美股持仓")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("添加股票代码、平均成本价与股数后查看盈亏")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snap in
                    Button {
                        selectedSnapshot = snap
                    } label: {
                        StockListRowView(snap: snap)
                    }
                    .buttonStyle(.plain)
                    if index < snapshots.count - 1 {
                        Divider().overlay(StockVisual.separator)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StockVisual.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(StockVisual.separator, lineWidth: 1))
        )
    }
}

private struct StockAssetMetric: View {
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

private struct StockListRowView: View {
    let snap: StockSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(snap.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        if snap.isStale {
                            Text("旧")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color(hex: 0xFEE685))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x7B3306).opacity(0.55)))
                        }
                    }
                    Text(snap.name)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.55))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(NumberFormat.usd(snap.regularPrice))
                            .foregroundStyle(priceVsCostColor)
                        Text("/")
                            .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.35))
                        Text(NumberFormat.usd(snap.averageCost))
                            .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.62))
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(NumberFormat.signedUSD(snap.todayProfit))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colorFor(snap.todayProfit))
                    Text(NumberFormat.signedPercent(snap.todayChangePercent))
                        .font(.system(size: 12))
                        .foregroundStyle(colorFor(snap.todayProfit))
                }
                .frame(width: 82, alignment: .trailing)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(NumberFormat.signedUSD(snap.holdingProfit))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colorFor(snap.holdingProfit))
                    Text(NumberFormat.signedPercent(snap.holdingProfitPercent))
                        .font(.system(size: 12))
                        .foregroundStyle(colorFor(snap.holdingProfit))
                }
                .frame(width: 82, alignment: .trailing)
            }

            Text(footerText)
                .font(.system(size: 10))
                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.45))
                .lineLimit(1)

            if let extendedText {
                Text(extendedText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(hex: 0xDBEAFE).opacity(0.75))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 82)
    }

    private var footerText: String {
        let shares = NumberFormat.quantity(snap.shares)
        let value = NumberFormat.usd(snap.marketValue)
        let time = USMarketHours.shortDisplayTime(snap.updatedAt)
        if let error = snap.errorMessage, snap.regularPrice == nil {
            return "\(error) · \(shares)股"
        }
        return "\(shares)股 · 市值 \(value) · 常规价更新 \(time)"
    }

    private var priceVsCostColor: Color {
        guard let price = snap.regularPrice else { return Color(hex: 0xA1A1A1).opacity(0.62) }
        return price >= snap.averageCost ? Color(hex: 0xFB2C36) : Color(hex: 0x00A63E)
    }

    private var extendedText: String? {
        guard let extendedPrice = snap.extendedPrice else { return nil }
        return "\(snap.marketState.displayName) \(NumberFormat.usd(extendedPrice)) \(NumberFormat.signedPercent(snap.extendedChangePercent)) · 估算 \(NumberFormat.signedUSD(snap.extendedHoldingProfit))"
    }

    private func colorFor(_ v: Double?) -> Color {
        guard let v else { return .secondary }
        if v > 0 { return Color(hex: 0xFB2C36) }
        if v < 0 { return Color(hex: 0x00A63E) }
        return .secondary
    }
}

private struct StockDetailPageView: View {
    let snap: StockSnapshot
    @ObservedObject var viewModel: StockViewModel
    let position: StockPosition?
    let onClose: () -> Void
    let onDelete: (_ id: String) -> Void
    let onSave: (_ editingID: String?, _ symbol: String, _ cost: Double, _ shares: Double, _ displayName: String?) -> Void

    @State private var klineData: StockKLineData?
    @State private var showEditor = false
    @State private var klineRange: StockKLineRange = .m3
    @State private var isKlineLoading = false
    @State private var klineRetryID = 0

    private var currentSnap: StockSnapshot {
        viewModel.snapshots.first(where: { $0.id == snap.id }) ?? snap
    }

    var body: some View {
        ZStack(alignment: .top) {
            StockVisual.pageBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                navBar
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        headerSection
                        detailsGrid
                        extendedSection
                        klineSection
                        quoteInfoSection
                    }
                }
            }
            if showEditor, let position {
                StockEditorView(
                    editing: position,
                    viewModel: viewModel,
                    displayName: currentSnap.name,
                    onDelete: { id in
                        onDelete(id)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showEditor = false
                        }
                    },
                    onSave: { id, symbol, cost, shares, displayName in
                        onSave(id, symbol, cost, shares, displayName)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showEditor = false
                        }
                    },
                    onCancel: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showEditor = false
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
                .zIndex(2)
            }
        }
        .swipeBackGesture(onBack: onClose)
        .task(id: "\(currentSnap.symbol)_\(klineRange.rawValue)_\(klineRetryID)") {
            let hasCached = viewModel.hasCachedKLine(symbol: currentSnap.symbol, count: klineRange.tradingDays)
            isKlineLoading = !hasCached
            if !hasCached {
                klineData = nil
            }
            klineData = await viewModel.fetchKLine(symbol: currentSnap.symbol, count: klineRange.tradingDays)
            isKlineLoading = false
        }
    }

    private var navBar: some View {
        ZStack {
            HStack {
                Button(action: onClose) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                        Text("返回")
                    }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(StockVisual.accent)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 72, alignment: .leading)
                Spacer()
                Button {
                    if position != nil {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showEditor = true
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                        Text("编辑")
                    }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(StockVisual.accent)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 72, alignment: .trailing)
                .disabled(position == nil)
            }
            Text("持仓详情")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .frame(height: 49)
        .background(StockVisual.topBarBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(StockVisual.separator).frame(height: 1)
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(currentSnap.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StockVisual.secondaryText.opacity(0.72))
                Text(currentSnap.marketState.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StockVisual.accent.opacity(0.92))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(StockVisual.selectedBackground))
            }
            Text(currentSnap.name)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
            HStack(alignment: .top) {
                metricBlock("当前价格", NumberFormat.usd(currentSnap.regularPrice), color: .white)
                priceChangeBlock
            }
            Text("更新 \(USMarketHours.detailDisplayTime(currentSnap.updatedAt))")
                .font(.system(size: 11))
                .foregroundStyle(StockVisual.secondaryText.opacity(0.5))
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .background(StockVisual.cardBackground)
    }

    private var detailsGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                detailCell("持仓市值", NumberFormat.usd(currentSnap.marketValue))
                detailCell("持仓股数", NumberFormat.quantity(currentSnap.shares))
                detailCell("平均成本", NumberFormat.usd(currentSnap.averageCost), showRightDivider: false)
            }
            Divider().overlay(StockVisual.separator)
            HStack(spacing: 0) {
                detailCell("当日盈亏", NumberFormat.signedUSD(currentSnap.todayProfit), color: colorFor(currentSnap.todayProfit))
                detailCell("累计盈亏", NumberFormat.signedUSD(currentSnap.holdingProfit), color: colorFor(currentSnap.holdingProfit))
                detailCell("持仓收益率", NumberFormat.signedPercent(currentSnap.holdingProfitPercent), color: colorFor(currentSnap.holdingProfit), showRightDivider: false)
            }
        }
        .frame(height: 124)
        .background(StockVisual.cardBackground)
    }

    @ViewBuilder
    private var extendedSection: some View {
        if currentSnap.extendedPrice != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(currentSnap.marketState.displayName)行情")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                Text("\(NumberFormat.usd(currentSnap.extendedPrice)) \(NumberFormat.signedUSD(currentSnap.extendedChange)) \(NumberFormat.signedPercent(currentSnap.extendedChangePercent))")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(colorFor(currentSnap.extendedChange))
                Text("按扩展时段估算：市值 \(NumberFormat.usd(currentSnap.extendedMarketValue))，盈亏 \(NumberFormat.signedUSD(currentSnap.extendedHoldingProfit))")
                    .font(.system(size: 12))
                    .foregroundStyle(StockVisual.secondaryText.opacity(0.62))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StockVisual.cardBackground)
        }
    }

    private var quoteInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("行情信息")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
            infoRow("数据源", currentSnap.providerName)
            infoRow("常规价格基准", NumberFormat.usd(currentSnap.previousClose))
            infoRow("本地刷新时间", USMarketHours.combinedDisplayTime(currentSnap.fetchedAt))
            if let error = currentSnap.errorMessage {
                infoRow("状态", error)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StockVisual.cardBackground)
    }

    @ViewBuilder
    private var klineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("K 线走势")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                Text(isKlineLoading ? "加载中" : klineRange.rawValue)
                    .font(.system(size: 11))
                    .foregroundStyle(StockVisual.secondaryText.opacity(0.55))
            }

            if let kline = klineData, !kline.items.isEmpty {
                StockCandlestickChartView(
                    points: kline.items,
                    darkMode: true
                )
                .frame(height: 220)
            } else {
                klineLoadingPlaceholder
            }

            HStack(spacing: 0) {
                legendDot(color: Color(hex: 0xFB2C36), label: "收 > 开")
                Spacer()
                legendDot(color: Color(hex: 0x00A63E), label: "收 < 开")
                Spacer()
                legendDot(color: Color(hex: 0xA1A1A1).opacity(0.5), label: "成交量")
            }
            .padding(.horizontal, 4)

            klineRangeSelector
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StockVisual.cardBackground)
    }

    private var klineLoadingPlaceholder: some View {
        VStack(spacing: 8) {
            if isKlineLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color(hex: 0xA1A1A1))
                Text("正在加载 \(klineRange.rawValue) K 线")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.65))
            } else {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.5))
                Text("暂无 K 线数据")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.65))
                Button {
                    klineRetryID += 1
                } label: {
                    Text("重试")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x2C2C2E)))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
    }

    private var priceChangeBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("价格变动")
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.5))
            Text(NumberFormat.signedUSD(currentSnap.todayChange))
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(colorFor(currentSnap.todayChange))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(NumberFormat.signedPercent(currentSnap.todayChangePercent))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colorFor(currentSnap.todayChange).opacity(0.82))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var klineRangeSelector: some View {
        GeometryReader { geo in
            let w = max(1, (geo.size.width - 8) / CGFloat(StockKLineRange.allCases.count))
            HStack(spacing: 2) {
                ForEach(StockKLineRange.allCases, id: \.self) { range in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            klineRange = range
                        }
                    } label: {
                        Text(range.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(klineRange == range ? .white : StockVisual.secondaryText.opacity(0.7))
                            .frame(width: w)
                            .padding(.vertical, 6)
                            .background(klineRange == range ? StockVisual.selectedBackground : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 36)
    }

    private func metricBlock(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.5))
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailCell(_ title: String, _ value: String, color: Color = .white, showRightDivider: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.55))
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.leading, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            if showRightDivider {
                Rectangle().fill(Color(hex: 0x262626).opacity(0.1)).frame(width: 1)
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.55))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.trailing)
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.55))
        }
    }

    private func colorFor(_ v: Double?) -> Color {
        guard let v else { return .white }
        if v > 0 { return Color(hex: 0xFB2C36) }
        if v < 0 { return Color(hex: 0x00A63E) }
        return .white
    }
}

private struct StockEditorView: View {
    private enum Field: Hashable {
        case symbol
        case cost
        case shares
    }

    let editing: StockPosition?
    @ObservedObject var viewModel: StockViewModel
    let displayName: String?
    let onDelete: (_ id: String) -> Void
    let onSave: (_ editingID: String?, _ symbol: String, _ cost: Double, _ shares: Double, _ displayName: String?) -> Void
    var onCancel: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var symbol = ""
    @State private var cost = ""
    @State private var shares = ""
    @State private var showInvalidAlert = false
    @State private var searchResults: [StockSearchResult] = []
    @State private var isSearching = false
    @State private var selectedDisplayName: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var hasSearched = false
    @FocusState private var focusedField: Field?

    init(
        editing: StockPosition?,
        viewModel: StockViewModel,
        displayName: String?,
        onDelete: @escaping (_ id: String) -> Void,
        onSave: @escaping (_ editingID: String?, _ symbol: String, _ cost: Double, _ shares: Double, _ displayName: String?) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self.editing = editing
        self.viewModel = viewModel
        self.displayName = displayName
        self.onDelete = onDelete
        self.onSave = onSave
        self.onCancel = onCancel
        _symbol = State(initialValue: editing?.symbol ?? "")
        _cost = State(initialValue: editing.map { NumberFormat.fixed($0.averageCost, digits: 4) } ?? "")
        _shares = State(initialValue: editing.map { NumberFormat.quantity($0.shares) } ?? "")
        _selectedDisplayName = State(initialValue: displayName)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: 0x1C1C1E).ignoresSafeArea()
                VStack(spacing: 0) {
                    navBar
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 12) {
                            symbolField
                            searchResultsSection
                            recognizedCard
                            inputRows
                            deleteButton
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    }
                }
            }
        }
        .onChange(of: symbol) { newValue in
            selectedDisplayName = nil
            scheduleSearch(for: newValue)
        }
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 80_000_000)
                focusedField = .symbol
            }
        }
        .alert("股票代码无效", isPresented: $showInvalidAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text("请检查股票代码、平均成本价与股数是否正确。")
        }
        .swipeBackGesture(onBack: {
            if let onCancel {
                onCancel()
            } else {
                dismiss()
            }
        })
    }

    private var navBar: some View {
        ZStack {
            HStack {
                Button("取消") {
                    if let onCancel {
                        onCancel()
                    } else {
                        dismiss()
                    }
                }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(hex: 0x2B7FFF))
                    .frame(minWidth: 72, alignment: .leading)
                Spacer()
                Button("保存") {
                    guard let c = Double(cost), let s = Double(shares), isValid else {
                        showInvalidAlert = true
                        return
                    }
                    onSave(editing?.id, symbol, c, s, selectedDisplayName)
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isValid ? Color(hex: 0x2B7FFF) : Color(hex: 0xA1A1A1).opacity(0.3))
                .disabled(!isValid)
                .frame(minWidth: 72, alignment: .trailing)
            }
            Text(editing == nil ? "添加美股持仓" : "编辑美股持仓")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .frame(height: 49)
        .background(Color(hex: 0x0A0A0A))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: 0x262626).opacity(0.2)).frame(height: 1)
        }
    }

    private var symbolField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.4))
            TextField("输入股票代码", text: $symbol)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .tint(.white)
                .focused($focusedField, equals: .symbol)
            if !symbol.isEmpty {
                Button {
                    symbol = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52.5)
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = .symbol
        }
        .background(cardBackground(cornerRadius: 18))
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        if isSearching || !searchResults.isEmpty || canSaveManualSymbol {
            VStack(spacing: 0) {
                if isSearching {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color(hex: 0xA1A1A1))
                        Text("搜索中...")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.65))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                }

                if canSaveManualSymbol {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color(hex: 0x51A2FF))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("手动添加 \(StockPosition.normalizeSymbol(symbol))")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("搜索源暂无匹配，保存后可继续追踪持仓")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.6))
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 54)
                }

                ForEach(searchResults) { result in
                    Button {
                        symbol = result.symbol
                        selectedDisplayName = result.description
                        searchResults = []
                        isSearching = false
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.displaySymbol)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(result.description)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.6))
                                    .lineLimit(1)
                            }
                            Spacer()
                            if !result.type.isEmpty {
                                Text(result.type)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color(hex: 0xA1A1A1).opacity(0.45))
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 54)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if result.id != searchResults.last?.id {
                        Divider().overlay(Color(hex: 0x262626).opacity(0.15))
                    }
                }
            }
            .background(cardBackground(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private var recognizedCard: some View {
        if let name = selectedDisplayName ?? displayName, !name.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(hex: 0x51A2FF))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(hex: 0xDBEAFE))
                    Text("美股持仓")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0x51A2FF).opacity(0.6))
                }
                Spacer()
            }
            .padding(.horizontal, 17)
            .frame(height: 67)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(hex: 0x1C398E).opacity(0.2))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: 0x1447E6).opacity(0.3), lineWidth: 1))
            )
        }
    }

    private var inputRows: some View {
        VStack(spacing: 0) {
            rowField(title: "平均成本", prefix: "$", text: $cost, field: .cost)
            Divider().overlay(Color(hex: 0x262626).opacity(0.15))
            rowField(title: "持仓股数", prefix: nil, text: $shares, field: .shares)
        }
        .background(cardBackground(cornerRadius: 18))
    }

    @ViewBuilder
    private var deleteButton: some View {
        if let editing {
            Button {
                onDelete(editing.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                    Text("删除持仓")
                }
                .font(.system(size: 15, weight: .medium))
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

    private var isValid: Bool {
        StockPosition.isValidSymbol(symbol)
            && hasSearched && !isSearching
            && (Double(cost) ?? 0) > 0 && (Double(shares) ?? 0) > 0
    }

    private var canSaveManualSymbol: Bool {
        hasSearched
            && !isSearching
            && searchResults.isEmpty
            && StockPosition.isValidSymbol(symbol)
    }

    private func scheduleSearch(for raw: String) {
        searchTask?.cancel()
        let query = StockPosition.normalizeSymbol(raw)
        guard query.count >= 1 else {
            searchResults = []
            isSearching = false
            hasSearched = false
            return
        }
        hasSearched = false
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            let results = await viewModel.searchSymbols(query: query)
            guard !Task.isCancelled else { return }
            searchResults = results
            if let first = results.first {
                selectedDisplayName = first.description
            }
            isSearching = false
            hasSearched = true
        }
    }

    private func rowField(title: String, prefix: String?, text: Binding<String>, field: Field) -> some View {
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
                .focused($focusedField, equals: field)
        }
        .padding(.horizontal, 16)
        .frame(height: 51.5)
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = field
        }
    }

    private func cardBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(hex: 0x0A0A0A))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color(hex: 0x262626).opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
    }
}

private extension View {
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


// MARK: - K 线图

private enum StockKLineRange: String, CaseIterable {
    case d7 = "近7日"
    case m1 = "近1月"
    case m3 = "近3月"
    case m6 = "近6月"
    case y1 = "近1年"
    case y3 = "近3年"

    var tradingDays: Int {
        switch self {
        case .d7: return 7
        case .m1: return 21
        case .m3: return 63
        case .m6: return 126
        case .y1: return 252
        case .y3: return 756
        }
    }
}

private struct CandleChartPoint {
    let index: Int
    let date: String
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Int
}

/// 简易 K 线图（蜡烛图）：红涨绿跌
private struct StockCandlestickChartView: View {
    let points: [StockKLinePoint]
    let darkMode: Bool

    private var chartPoints: [CandleChartPoint] {
        points.sorted { $0.date < $1.date }.enumerated().map { i, p in
            CandleChartPoint(index: i, date: p.date, open: p.open, high: p.high, low: p.low, close: p.close, volume: p.volume)
        }
    }

    private var priceRange: ClosedRange<Double> {
        let allPrices = points.flatMap { [$0.high, $0.low] }
        let minP = (allPrices.min() ?? 0) * 0.998
        let maxP = (allPrices.max() ?? 100) * 1.002
        return minP...maxP
    }

    private var volumeMax: Int {
        points.map(\.volume).max() ?? 1
    }

    var body: some View {
        let pts = chartPoints
        if pts.isEmpty {
            emptyPlaceholder
        } else {
            GeometryReader { geo in
                Canvas { context, size in
                    drawChart(points: pts, context: &context, size: size)
                }
                .overlay(alignment: .leading) {
                    yAxisLabels(size: geo.size)
                }
                .overlay(alignment: .bottom) {
                    xAxisLabels(points: pts)
                }
            }
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title2)
            Text("暂无 K 线数据")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var axisColor: Color {
        Color(hex: 0xA1A1A1).opacity(0.4)
    }

    private var gridColor: Color {
        Color(hex: 0xA1A1A1).opacity(0.12)
    }

    private var volumeBaselineColor: Color {
        Color(hex: 0xA1A1A1).opacity(0.18)
    }

    private func candleColor(for p: CandleChartPoint) -> Color {
        p.close >= p.open ? Color(hex: 0xFB2C36) : Color(hex: 0x00A63E)
    }

    private func volumeColor(for p: CandleChartPoint) -> Color {
        p.close >= p.open ? Color(hex: 0xFB2C36) : Color(hex: 0x00A63E)
    }

    private func fmt(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    private func formatAxisDate(_ ymd: String) -> String {
        let parts = ymd.split(separator: "-")
        guard parts.count >= 3 else { return ymd }
        return "\(parts[1])/\(parts[2])"
    }

    private func xTickIndices(_ pts: [CandleChartPoint]) -> [Int] {
        guard pts.count > 1 else { return [0] }
        let count = pts.count
        if count <= 10 {
            return [0, count - 1]
        }
        return [0, count / 2, count - 1]
    }

    private func drawChart(points pts: [CandleChartPoint], context: inout GraphicsContext, size: CGSize) {
        let leftInset: CGFloat = 44
        let rightInset: CGFloat = 8
        let topInset: CGFloat = 8
        let bottomInset: CGFloat = 20
        let gap: CGFloat = 12
        let volumeHeight = max(34, size.height * 0.22)
        let priceHeight = max(80, size.height - topInset - bottomInset - gap - volumeHeight)
        let priceRect = CGRect(x: leftInset, y: topInset, width: size.width - leftInset - rightInset, height: priceHeight)
        let volumeRect = CGRect(x: leftInset, y: priceRect.maxY + gap, width: priceRect.width, height: volumeHeight)

        let minPrice = priceRange.lowerBound
        let maxPrice = priceRange.upperBound
        let priceSpan = max(0.0001, maxPrice - minPrice)
        let count = max(1, pts.count)
        let slot = priceRect.width / CGFloat(count)
        let bodyWidth = min(max(slot * 0.46, 2.4), 7)

        for i in 0...3 {
            let y = priceRect.minY + CGFloat(i) / 3 * priceRect.height
            var path = Path()
            path.move(to: CGPoint(x: priceRect.minX, y: y))
            path.addLine(to: CGPoint(x: priceRect.maxX, y: y))
            context.stroke(path, with: .color(gridColor), style: StrokeStyle(lineWidth: 0.5, dash: [3, 5]))
        }

        var baseline = Path()
        baseline.move(to: CGPoint(x: volumeRect.minX, y: volumeRect.maxY))
        baseline.addLine(to: CGPoint(x: volumeRect.maxX, y: volumeRect.maxY))
        context.stroke(baseline, with: .color(volumeBaselineColor), lineWidth: 0.5)

        func yForPrice(_ price: Double) -> CGFloat {
            priceRect.maxY - CGFloat((price - minPrice) / priceSpan) * priceRect.height
        }

        for (index, point) in pts.enumerated() {
            let x = priceRect.minX + CGFloat(index) * slot + slot / 2
            let color = candleColor(for: point)
            let highY = yForPrice(point.high)
            let lowY = yForPrice(point.low)
            let openY = yForPrice(point.open)
            let closeY = yForPrice(point.close)
            let top = min(openY, closeY)
            let height = max(abs(closeY - openY), 1.6)

            var wick = Path()
            wick.move(to: CGPoint(x: x, y: highY))
            wick.addLine(to: CGPoint(x: x, y: lowY))
            context.stroke(wick, with: .color(color.opacity(0.9)), lineWidth: 1)

            let bodyRect = CGRect(x: x - bodyWidth / 2, y: top, width: bodyWidth, height: height)
            context.fill(Path(roundedRect: bodyRect, cornerRadius: 1.2), with: .color(color.opacity(0.95)))

            let volumeRatio = CGFloat(point.volume) / CGFloat(max(1, volumeMax))
            let volumeBarHeight = max(1, volumeRatio * volumeRect.height)
            let volumeRectForPoint = CGRect(
                x: x - bodyWidth / 2,
                y: volumeRect.maxY - volumeBarHeight,
                width: bodyWidth,
                height: volumeBarHeight
            )
            context.fill(Path(roundedRect: volumeRectForPoint, cornerRadius: 1), with: .color(color.opacity(0.22)))
        }
    }

    private func yAxisLabels(size: CGSize) -> some View {
        let labels = [priceRange.upperBound, (priceRange.upperBound + priceRange.lowerBound) / 2, priceRange.lowerBound]
        return VStack {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, value in
                Text("$\(fmt(value))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(axisColor)
                    .frame(width: 40, alignment: .leading)
                if value != labels.last {
                    Spacer()
                }
            }
        }
        .frame(width: 40, height: max(80, size.height * 0.7), alignment: .leading)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func xAxisLabels(points pts: [CandleChartPoint]) -> some View {
        let ticks = xTickIndices(pts)
        return HStack {
            ForEach(Array(ticks.enumerated()), id: \.offset) { offset, idx in
                Text(formatAxisDate(pts[idx].date))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(axisColor)
                    .frame(maxWidth: .infinity, alignment: offset == 0 ? .leading : (offset == ticks.count - 1 ? .trailing : .center))
            }
        }
        .padding(.leading, 44)
        .padding(.trailing, 8)
    }
}
