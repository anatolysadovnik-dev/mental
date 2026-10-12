import SwiftUI

/// Вкладка «Пройденный путь» — новая, в Rhythmos её нет.
///
/// Собирается из существующих эндпоинтов Mental: `status` (зоны недель, прогресс),
/// `week-insight` и `insight` (ИИ-разборы, для которых в Rhythmos был только клиент,
/// но не экран) и `final-products/list` (личные итоги).
struct PathView: View {
    let goToToday: () -> Void

    @StateObject private var vm = PathViewModel()
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.theme) private var t

    var body: some View {
        ZStack {
            t.paper.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: t.spacing.xl) {
                    if let error = vm.error {
                        ErrorBanner(error: error) { Task { await vm.load() } }
                    }

                    if vm.isLoading && vm.status == nil {
                        ProgressView().tint(t.terracotta)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if let status = vm.status {
                        progressSection(status)
                        weeksSection(status)
                        insightsSection
                        achievementsSection
                    } else {
                        EmptyStateCard(icon: "map",
                                       title: "path.empty",
                                       message: "path.emptyBody",
                                       actionTitle: "today.chooseRoute",
                                       action: goToToday)
                    }
                }
                .padding(t.spacing.xl)
            }
            .refreshable { await vm.load() }
        }
        .navigationTitle(Text("path.title"))
        .task { await vm.load() }
    }

    // MARK: - Прогресс

    private func progressSection(_ status: EnrollmentStatusResponse) -> some View {
        // Счётчик «1 из 42 дней» раньше был самым крупным элементом экрана — герой
        // теперь полоса прогресса и название текущей недели, а счётчик —
        // мелкая подпись снизу.
        let currentTitle = status.weekTitles.first { $0.week == status.week }?.title
        return PageCard {
            Text(status.name)
                .font(t.font.displaySerif(20))
                .foregroundStyle(t.ink)

            if status.status == .active || status.status == .selfcheckDue {
                VStack(alignment: .leading, spacing: 2) {
                    LabelTag(text: L10n("today.weekDay").format(status.week, status.day), color: t.terracotta)
                    if let currentTitle, !currentTitle.isEmpty {
                        Text(currentTitle)
                            .font(t.font.bodyEmphasized)
                            .foregroundStyle(t.ink)
                    }
                }
            }

            // total_weeks/total_days/days_total захардкожены в бэкенде (6/7/42) —
            // берём оттуда, а не считаем сами
            ProgressView(value: Double(status.daysCompleted),
                         total: Double(max(status.daysTotal, 1)))
                .tint(t.terracotta)

            Text(L10n("path.progress").format(status.daysCompleted, status.daysTotal))
                .font(t.font.caption)
                .foregroundStyle(t.inkMuted)
        }
    }

    // MARK: - Недели — вертикальная дорожка

    /// Раньше здесь был ряд из шести одинаковых серых плашок без имён —
    /// теперь у каждой недели есть название и понятное состояние
    /// (пройдено/текущая/впереди), читается как карта пути, а не как ряд прямоугольников.
    private func weeksSection(_ status: EnrollmentStatusResponse) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            LabelTag(text: L10n("path.weeks").text, color: t.inkMuted)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(1...max(status.totalWeeks, 1), id: \.self) { week in
                    weekRow(week, status: status)
                }
            }
        }
    }

    private enum WeekState {
        case done(Zone?)
        case current
        case upcoming

        var isCurrent: Bool { if case .current = self { return true }; return false }
        var isUpcoming: Bool { if case .upcoming = self { return true }; return false }

        var accessibilityValue: Text {
            switch self {
            case .done(let zone?): return Text(L10n(zone.titleKey))
            case .done(nil): return Text("path.weekDone")
            case .current: return Text("path.weekCurrent")
            case .upcoming: return Text("a11y.notSelected")
            }
        }
    }

    private func state(for week: Int, status: EnrollmentStatusResponse) -> WeekState {
        if let zone = status.weeks.first(where: { $0.week == week })?.zone {
            return .done(zone)
        }
        if status.status == .completed {
            return .done(nil)
        }
        if week == status.week, status.status == .active || status.status == .selfcheckDue {
            return .current
        }
        return .upcoming
    }

    private func weekRow(_ week: Int, status: EnrollmentStatusResponse) -> some View {
        let title = status.weekTitles.first { $0.week == week }?.title
        let weekState = state(for: week, status: status)
        let isLast = week == status.totalWeeks

        return HStack(alignment: .top, spacing: t.spacing.m) {
            VStack(spacing: 0) {
                weekMarker(week, state: weekState)
                if !isLast {
                    Rectangle()
                        .fill(isPast(weekState) ? t.terracotta.opacity(0.3) : t.inkWhisper.opacity(0.5))
                        .frame(width: 2)
                        .frame(minHeight: 24)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n("path.week").format(week))
                    .font(t.font.labelS)
                    .foregroundStyle(weekState.isCurrent ? t.terracotta : t.inkDim)
                Text(title?.isEmpty == false ? title! : L10n("path.weekPlaceholder").text)
                    .font(weekState.isCurrent ? t.font.bodyEmphasized : t.font.body)
                    .foregroundStyle(weekState.isUpcoming ? t.inkMuted : t.ink)
            }
            .padding(.top, 3)

            Spacer(minLength: 0)

            if case .done(let zone?) = weekState {
                Circle().fill(t.zoneColor(zone)).frame(width: 8, height: 8)
                    .padding(.top, 10)
                    .accessibilityHidden(true)
            }
        }
        .padding(.bottom, isLast ? 0 : t.spacing.m)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n("path.week").format(week)))
        .accessibilityValue(weekState.accessibilityValue)
    }

    private func weekMarker(_ week: Int, state: WeekState) -> some View {
        ZStack {
            switch state {
            case .done(let zone):
                Circle().fill(zone.map { t.zoneColor($0) } ?? t.sage)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            case .current:
                Circle().fill(t.terracotta.opacity(0.14))
                    .overlay(Circle().strokeBorder(t.terracotta, lineWidth: 1.5))
                Text("\(week)")
                    .font(t.font.labelS)
                    .foregroundStyle(t.terracotta)
            case .upcoming:
                Circle().fill(t.surfaceSecondary)
                    .overlay(Circle().strokeBorder(t.border, lineWidth: 0.5))
                Text("\(week)")
                    .font(t.font.labelS)
                    .foregroundStyle(t.inkDim)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    private func isPast(_ state: WeekState) -> Bool {
        if case .done = state { return true }
        return false
    }

    // MARK: - ИИ-разборы

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            InsightCard(title: "path.weekInsight",
                        icon: "chart.bar.doc.horizontal",
                        accent: t.dustyBlue,
                        state: vm.weekInsight) {
                Task { await vm.loadWeekInsight() }
            }

            if vm.status?.status == .completed {
                InsightCard(title: "path.programInsight",
                            icon: "sparkles.rectangle.stack",
                            accent: t.terracotta,
                            state: vm.programInsight) {
                    Task { await vm.loadProgramInsight() }
                }
            }
        }
    }

    // MARK: - Личные итоги

    @ViewBuilder
    private var achievementsSection: some View {
        if !vm.finalProducts.isEmpty {
            VStack(alignment: .leading, spacing: t.spacing.m) {
                LabelTag(text: L10n("path.achievements").text, color: t.amber)
                ForEach(vm.finalProducts) { product in
                    NavigationLink {
                        FinalProductView(product: product)
                    } label: {
                        PageCard {
                            HStack(spacing: t.spacing.m) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 18))
                                    .foregroundStyle(t.amber)
                                    .accessibilityHidden(true)
                                Text(product.moduleName ?? product.module ?? "")
                                    .font(t.font.bodyEmphasized)
                                    .foregroundStyle(t.ink)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(t.inkDim)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Карточка разбора

enum InsightState {
    case idle
    case loading
    case ready(String)
    case disabled
}

struct InsightCard: View {
    let title: L10n
    let icon: String
    let accent: Color
    let state: InsightState
    let onLoad: () -> Void

    @Environment(\.theme) private var t

    var body: some View {
        PageCard {
            HStack(spacing: t.spacing.s) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                LabelTag(text: title.text, color: accent)
            }

            switch state {
            case .idle:
                GhostButton(title: "path.insightLoad", icon: "sparkles", action: onLoad)
            case .loading:
                HStack(spacing: t.spacing.s) {
                    ProgressView().tint(accent)
                    Text("common.loading")
                        .font(t.font.caption)
                        .foregroundStyle(t.inkDim)
                }
            case .ready(let text):
                Text(text)
                    .font(t.font.body)
                    .foregroundStyle(t.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            case .disabled:
                Text("path.insightDisabled")
                    .font(t.font.caption)
                    .foregroundStyle(t.inkDim)
            }
        }
    }
}

/// Финальный продукт: массив многострочных строк, где ПЕРВАЯ строка — заголовок,
/// остальное — подсказка. Разделяем по первому переводу строки.
struct FinalProductView: View {
    let product: FinalProductItem

    @Environment(\.theme) private var t

    var body: some View {
        ZStack {
            t.paper.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: t.spacing.l) {
                    ForEach(Array(product.sections.enumerated()), id: \.offset) { index, section in
                        let parts = section.split(separator: "\n", maxSplits: 1,
                                                  omittingEmptySubsequences: false)
                        let heading = parts.first.map(String.init) ?? ""
                        let body = parts.count > 1 ? String(parts[1]) : nil

                        ContentCard(label: "\(index + 1)",
                                    title: heading,
                                    text: body,
                                    accent: t.amber)
                            .staggerIn(index: min(index, 8))
                    }
                }
                .padding(t.spacing.xl)
            }
        }
        .navigationTitle(Text(product.moduleName ?? "path.achievements"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - ViewModel

@MainActor
final class PathViewModel: ObservableObject {
    @Published private(set) var status: EnrollmentStatusResponse?
    @Published private(set) var finalProducts: [FinalProductItem] = []
    @Published private(set) var weekInsight: InsightState = .idle
    @Published private(set) var programInsight: InsightState = .idle
    @Published private(set) var isLoading = false
    @Published var error: APIError?

    private let api: RidgeAPIProtocol
    private var eid: Int?

    init(api: RidgeAPIProtocol = RidgeAPI.shared) {
        self.api = api
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let enrollments = try await api.enrollments()
            // показываем активный маршрут; если активного нет — последний завершённый
            let target = enrollments.first { $0.status == .active || $0.status == .selfcheckDue }
                ?? enrollments.first { $0.status == .completed }
            guard let target else {
                status = nil
                return
            }
            eid = target.enrollmentId
            status = try await api.enrollmentStatus(eid: target.enrollmentId)
            finalProducts = (try? await api.finalProducts()) ?? []
        } catch let e as APIError {
            error = e
        } catch {
            self.error = .server(status: 0, message: error.localizedDescription)
        }
    }

    /// `enabled: false` приходит, когда на бэкенде не настроен ключ LLM.
    private static func state(from response: InsightResponse) -> InsightState {
        guard response.enabled, let text = response.text, !text.isEmpty else {
            return .disabled
        }
        return .ready(text)
    }

    /// Разборы грузим по требованию: это обращение к сильной модели, не для каждого входа.
    func loadWeekInsight() async {
        guard let eid else { return }
        weekInsight = .loading
        do {
            let response = try await api.weekInsight(eid: eid)
            weekInsight = Self.state(from: response)
        } catch {
            weekInsight = .disabled
        }
    }

    func loadProgramInsight() async {
        guard let eid else { return }
        programInsight = .loading
        do {
            let response = try await api.programInsight(eid: eid)
            programInsight = Self.state(from: response)
        } catch {
            programInsight = .disabled
        }
    }
}

#Preview {
    NavigationStack { PathView {} }
        .environmentObject(LanguageStore.shared)
        .environment(\.theme, .warm)
}
