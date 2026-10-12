import SwiftUI

/// Главный экран: день маршрута.
///
/// Композиция взята с `TodayView` Rhythmos: hero-заголовок вместо навбара (компактный,
/// 152pt — заголовок дня живёт отдельно под ним), `ScrollView` с `.refreshable`,
/// статус-бар прикрыт блюр-подложкой при скролле, основное действие закреплено
/// внизу экрана (как в `DayFlowView`), а не в конце ленты. Содержание — из Mental.
///
/// Три состояния по `status`: `active` (утро/вечер), `selfcheck_due`, `completed`.
struct TodayView: View {
    @StateObject private var vm = TodayViewModel()
    @EnvironmentObject private var language: LanguageStore
    @EnvironmentObject private var auth: AuthViewModel
    @Environment(\.theme) private var t

    @State private var showAskAI = false
    @State private var showNote = false
    @State private var showEveningFlow = false
    @State private var showSelfcheck = false
    @State private var showModulePicker = false

    /// Куда вернулись при последнем скролле (см. `scrollAnchor(_:space:)`) — нужно,
    /// чтобы вернуться к тому же месту после сворачивания/возврата на экран.
    @State private var topAnchorID: String?
    private static let scrollSpace = "todayScroll"

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                t.paper.ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: t.spacing.xl) {
                                HeroHeader(dateLine: DateFormatting.heroDate(Date(), language: language.current),
                                           greeting: TimeOfDay.current().greetingKey.text,
                                           context: contextLine)

                                VStack(alignment: .leading, spacing: t.spacing.l) {
                                    if let error = vm.error {
                                        ErrorBanner(error: error) { vm.load() }
                                            .onAppear { if error.requiresSignOut { auth.handleUnauthorized() } }
                                    }

                                    content
                                }
                                .padding(.horizontal, t.spacing.xl)
                                .padding(.bottom, t.spacing.xl)
                            }
                        }
                        .coordinateSpace(name: Self.scrollSpace)
                        .onPreferenceChange(ScrollAnchorKey.self) { updateTopAnchor($0) }
                        .onChange(of: scrollRestoreTrigger) { _ in restoreScroll(using: scrollProxy) }
                        .refreshable { await vm.refresh() }
                    }

                    if let primary = primaryAction {
                        bottomBar(primary)
                    }
                }

                // Без системного navigation bar контент скроллится прямо под статус-бар/Dynamic
                // Island — эта подложка держит зону читаемой независимо от скролла.
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .frame(height: proxy.safeAreaInsets.top)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
        }
        .navigationBarHidden(true)             // hero заменяет навбар
        .task {
            vm.load()
            await vm.loadModules(language: language.current.rawValue)
        }
        .onDisappear { vm.cancelLoading() }
        .sheet(isPresented: $showAskAI) { AskAIView(context: aiContext) }
        .sheet(isPresented: $showNote) {
            NoteSheet { text in Task { await vm.addNote(text) } }
        }
        .sheet(isPresented: $showEveningFlow) {
            DayFlowView(vm: vm) { showEveningFlow = false }
        }
        .sheet(isPresented: $showSelfcheck) {
            if let eid = vm.eid {
                SelfcheckView(eid: eid) {
                    showSelfcheck = false
                    vm.load()
                }
            }
        }
        .sheet(isPresented: $showModulePicker) {
            ModulePickerSheet(modules: vm.modules) { code in
                showModulePicker = false
                Task { await vm.enroll(in: code) }
            }
        }
        // Вводный экран недели — отдельный шит, а не карточка в ленте (показывается
        // один раз, в день 1; флаг выставляет vm при загрузке дня).
        .sheet(isPresented: $vm.showWeekIntro) {
            if let intro = vm.day?.weekIntro {
                WeekIntroSheet(intro: intro, week: vm.day?.week ?? 1) {
                    vm.showWeekIntro = false
                }
            }
        }
    }

    private var contextLine: String? {
        guard let day = vm.day, day.isActive, let w = day.week, let d = day.day else {
            return vm.enrollment?.name
        }
        return L10n("today.weekDay").format(w, d)
    }

    private var aiContext: String? {
        guard let day = vm.day, day.isActive else { return nil }
        return [day.dayTitle, vm.focusStep?.focus].compactMap { $0 }.joined(separator: "\n")
    }

    // MARK: - Кнопка внизу экрана

    /// Единственное действие, которое двигает день вперёд (открыть/закрыть) —
    /// закреплено внизу экрана, видно без скролла (см. design-критику: раньше кнопка
    /// была в конце ленты и требовала скролла до низа).
    private struct PrimaryAction {
        let title: LocalizedStringKey
        var isLoading = false
        let action: () -> Void
    }

    private var primaryAction: PrimaryAction? {
        guard let day = vm.day, vm.hasRoute,
              !day.isCompleted, !day.isSelfcheckDue, !vm.isDoneToday else { return nil }
        if vm.session == .morning {
            return PrimaryAction(title: "today.openDay", isLoading: vm.isSubmitting) {
                Task { await vm.openDay() }
            }
        }
        return PrimaryAction(title: "today.closeDay") { showEveningFlow = true }
    }

    private func bottomBar(_ primary: PrimaryAction) -> some View {
        AccentButton(title: primary.title, isLoading: primary.isLoading, action: primary.action)
            .padding(.horizontal, t.spacing.xl)
            .padding(.vertical, t.spacing.m)
            .background(t.paper)
            .overlay(alignment: .top) { Divider().foregroundStyle(t.border) }
    }

    // MARK: - Сохранение позиции скролла

    /// Меняется только когда загружается действительно другой день/сессия — это триггер
    /// для однократной попытки восстановить сохранённый скролл (срабатывает и на первой
    /// загрузке, потому что значение меняется с "0-0-morning" на реальные id/день/сессию).
    private var scrollRestoreTrigger: String {
        "\(vm.eid ?? 0)-\(vm.day?.day ?? 0)-\(vm.session.rawValue)"
    }

    private var scrollAnchorStorageKey: String? {
        guard let eid = vm.eid, let day = vm.day?.day else { return nil }
        return "ridge_scroll_anchor_\(eid)_\(day)_\(vm.session.rawValue)"
    }

    /// Считаем якорем «верхним» тот, что ближе всего к верху видимой области (сразу
    /// под hero, поэтому допускаем небольшой отрицательный minY).
    private func updateTopAnchor(_ offsets: [String: CGFloat]) {
        let visible = offsets.filter { $0.value > -40 && $0.value < 300 }
        guard let nearest = visible.min(by: { abs($0.value) < abs($1.value) })?.key,
              nearest != topAnchorID else { return }
        topAnchorID = nearest
        if let key = scrollAnchorStorageKey {
            UserDefaults.standard.set(nearest, forKey: key)
        }
    }

    private func restoreScroll(using scrollProxy: ScrollViewProxy) {
        guard let key = scrollAnchorStorageKey,
              let saved = UserDefaults.standard.string(forKey: key) else { return }
        // Сразу после загрузки якоря ещё не расставлены по экрану — даём лейауту кадр.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            scrollProxy.scrollTo(saved, anchor: .top)
        }
    }

    // MARK: - Содержимое по состоянию

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.day == nil {
            ProgressView().tint(t.terracotta).frame(maxWidth: .infinity, minHeight: 160)
        } else if !vm.hasRoute {
            EmptyStateCard(icon: "compass.drawing",
                           title: "today.noRoute",
                           message: "today.noRouteBody",
                           actionTitle: "today.chooseRoute") { showModulePicker = true }
        } else if let day = vm.day {
            if day.isCompleted {
                completedState
            } else if day.isSelfcheckDue {
                selfcheckDueState(week: day.week ?? 0)
            } else if vm.isDoneToday {
                doneTodayState
            } else {
                activeDay(day)
            }
        }
    }

    private var completedState: some View {
        EmptyStateCard(icon: "flag.checkered",
                       title: "today.completed",
                       message: "today.completedBody")
    }

    private func selfcheckDueState(week: Int) -> some View {
        // Заголовок содержит номер недели, поэтому собираем строку сами:
        // интерполяция внутрь LocalizedStringKey испортила бы сам ключ.
        let title = L10n("today.selfcheckDue").format(week)
        return PageCard {
            VStack(spacing: t.spacing.m) {
                Image(systemName: "checklist")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(t.inkWhisper)
                    .accessibilityHidden(true)
                Text(title)
                    .font(t.font.titleS)
                    .foregroundStyle(t.ink)
                    .multilineTextAlignment(.center)
                Text("today.selfcheckDueBody")
                    .font(t.font.body)
                    .foregroundStyle(t.inkMuted)
                    .multilineTextAlignment(.center)
                AccentButton(title: "today.selfcheckStart") { showSelfcheck = true }
                    .padding(.top, t.spacing.xs)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, t.spacing.s)
        }
    }

    private var doneTodayState: some View {
        EmptyStateCard(icon: "moon.stars",
                       title: "today.dayDone",
                       message: "today.comeBackTomorrow")
    }

    @ViewBuilder
    private func activeDay(_ day: DayResponse) -> some View {
        if let title = day.dayTitle, !title.isEmpty {
            Text(title)
                .font(t.font.displaySerif(26))
                .foregroundStyle(t.ink)
                .fixedSize(horizontal: false, vertical: true)
                .scrollAnchor("title", space: Self.scrollSpace)
                .staggerIn(index: 0)
        }

        if vm.session == .morning {
            morningContent
        } else {
            eveningPrompt
        }
    }

    /// Утро: вопросы настройки (спец для недели 6) → фокус дня (главный, крупный блок) →
    /// задание → аудио/текст → заметка (кнопка «Открыть день» теперь закреплена внизу экрана,
    /// см. `primaryAction`/`bottomBar`).
    @ViewBuilder
    private var morningContent: some View {
        ForEach(Array(vm.intentSteps.enumerated()), id: \.element.id) { index, step in
            if let question = step.question {
                ContentCard(label: L10n("today.intent").text,
                            title: nil,
                            text: question,
                            accent: t.dustyBlue,
                            icon: "sparkle")
                    .staggerIn(index: index + 1)
            }
        }

        if let focus = vm.focusStep {
            // Фокус дня — единственное, ради чего открыт экран, поэтому он один
            // крупнее остальных блоков (см. design-критику: раньше всё было одного веса).
            ContentCard(label: L10n("today.focus").text,
                        title: nil,
                        text: focus.focus,
                        accent: t.terracotta,
                        icon: "target",
                        emphasized: true)
                .scrollAnchor("focus", space: Self.scrollSpace)
                .staggerIn(index: 2)

            if let task = focus.task {
                // Список и задание — служебный текст, не чтение: системный шрифт сканируется
                // быстрее серифа, который остаём только за фокусом (см. design-критику).
                ContentCard(label: L10n("today.task").text,
                            title: nil,
                            text: task.text,
                            subtasks: task.subtasks,
                            accent: t.sage,
                            icon: "checkmark.square",
                            textStyle: .system)
                    .scrollAnchor("task", space: Self.scrollSpace)
                    .staggerIn(index: 3)
            }
        }

        if let audio = vm.audioStep, let code = audio.code, let eid = vm.eid {
            AudioCard(eid: eid, code: code, title: audio.title)
                .scrollAnchor("audio", space: Self.scrollSpace)
                .staggerIn(index: 4)
        }

        if let text = vm.textStep, let code = text.code, let eid = vm.eid {
            TextCard(eid: eid, code: code, title: text.title)
                .scrollAnchor("text", space: Self.scrollSpace)
                .staggerIn(index: 4)
        }

        noteRow
            .scrollAnchor("note", space: Self.scrollSpace)
            .staggerIn(index: 5)
    }

    /// Вечер: закрыть день — статус задания, квиз, три рефлексии — открываются в шите `DayFlowView`,
    /// здесь только входное состояние + напоминание о задании.
    private var eveningPrompt: some View {
        VStack(alignment: .leading, spacing: t.spacing.l) {
            PageCard {
                HStack(spacing: t.spacing.m) {
                    Image(systemName: "sunset")
                        .font(.system(size: 20))
                        .foregroundStyle(t.terracotta)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("today.dayOpened")
                            .font(t.font.titleS)
                            .foregroundStyle(t.ink)
                        Text("today.dayOpenedBody")
                            .font(t.font.caption)
                            .foregroundStyle(t.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let focus = vm.focusStep, let task = focus.task {
                ContentCard(label: L10n("today.task").text,
                            title: nil,
                            text: task.text,
                            subtasks: task.subtasks,
                            accent: t.sage,
                            icon: "checkmark.square",
                            textStyle: .system)
                    .scrollAnchor("task", space: Self.scrollSpace)
            }

            noteRow
                .scrollAnchor("note", space: Self.scrollSpace)
        }
    }

    /// Дневник и ИИ — два равнозначных действия, оба настоящими кнопками (не ссылкой),
    /// чтобы было видно, что на них можно нажать.
    private var noteRow: some View {
        HStack(spacing: t.spacing.m) {
            GhostButton(title: "today.addNote", icon: "pencil") {
                showNote = true
            }
            GhostButton(title: "today.askAI", icon: "sparkles") {
                showAskAI = true
            }
        }
    }
}

// MARK: - Якоря скролла

private struct ScrollAnchorKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private extension View {
    /// Помечает позицию блока в именованном координатном пространстве скролла (для
    /// восстановления позиции при возврате на экран, см. `TodayView.restoreScroll`) и даёт
    /// ему стабильный `id` для `ScrollViewProxy.scrollTo`.
    func scrollAnchor(_ id: String, space: String) -> some View {
        self.id(id)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ScrollAnchorKey.self,
                                            value: [id: geo.frame(in: .named(space)).minY])
                }
            )
    }
}

// MARK: - Вводный экран недели

/// Отдельный шит (а не карточка в ленте дня) — показывается один раз, в день 1.
/// `meaning` сюда НЕ идёт — это методологическое поле для автора контента,
/// не пользовательский текст (см. bot/texts.py::week_intro).
struct WeekIntroSheet: View {
    let intro: WeekIntro
    let week: Int
    let onClose: () -> Void

    @Environment(\.theme) private var t

    var body: some View {
        NavigationStack {
            ZStack {
                t.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: t.spacing.l) {
                        LabelTag(text: "\(L10n("today.weekIntro").text) \(week)", color: t.terracotta)

                        if let title = intro.title {
                            Text(title)
                                .font(t.font.displaySerif(24))
                                .foregroundStyle(t.ink)
                        }
                        if let screen = intro.introScreen {
                            ContentText(raw: screen)
                        }
                        if let goal = intro.goal {
                            labelled("today.weekGoal", goal)
                        }
                        if let result = intro.result {
                            labelled("today.weekResult", result)
                        }
                        if !intro.keyThemes.isEmpty {
                            VStack(alignment: .leading, spacing: t.spacing.xs) {
                                LabelTag(text: L10n("today.keyThemes").text, color: t.inkMuted)
                                ForEach(Array(intro.keyThemes.enumerated()), id: \.offset) { _, theme in
                                    HStack(alignment: .top, spacing: t.spacing.s) {
                                        Circle()
                                            .fill(t.terracotta.opacity(0.5))
                                            .frame(width: 4, height: 4)
                                            .padding(.top, 7)
                                            .accessibilityHidden(true)
                                        Text(ContentFormatter.plainPreview(theme))
                                            .font(t.font.caption)
                                            .foregroundStyle(t.inkMuted)
                                    }
                                }
                            }
                        }

                        AccentButton(title: "common.continue", action: onClose)
                            .padding(.top, t.spacing.s)
                    }
                    .padding(t.spacing.xl)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.close") { onClose() }
                }
            }
        }
    }

    private func labelled(_ key: L10n, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabelTag(text: key.text, color: t.sage)
            ContentText(raw: text)
        }
    }
}

#Preview {
    NavigationStack { TodayView() }
        .environmentObject(AuthViewModel())
        .environmentObject(LanguageStore.shared)
        .environment(\.theme, .warm)
}
