import SwiftUI

/// Вкладка «Я» — настройки.
struct MeView: View {
    @StateObject private var vm = MeViewModel()
    @EnvironmentObject private var auth: AuthViewModel
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.theme) private var t

    @State private var showLinkSheet = false
    @State private var confirmChangeRoute = false
    @State private var showModulePicker = false

    var body: some View {
        ZStack {
            t.paper.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: t.spacing.xl) {
                    if let error = vm.error {
                        ErrorBanner(error: error) { Task { await vm.load() } }
                    }

                    currentRouteSection
                    remindersSection
                    languageSection
                    accountSection
                    aboutSection
                }
                .padding(t.spacing.xl)
            }
        }
        .navigationTitle(Text("me.title"))
        .task { await vm.load() }
        .sheet(isPresented: $showLinkSheet) { LinkCodeSheet() }
        .sheet(isPresented: $showModulePicker) {
            ModulePickerSheet(modules: vm.modules) { code in
                showModulePicker = false
                Task { await vm.enroll(in: code) }
            }
        }
        .alert(Text("me.changeRoute"), isPresented: $confirmChangeRoute) {
            Button("common.cancel", role: .cancel) {}
            Button("me.changeRoute", role: .destructive) {
                // паритет с ботом (route_switch_yes): сбросить прогресс и сразу же
                // предложить выбрать новую программу, а не оставлять пустой экран.
                Task {
                    guard await vm.abandonActiveRoute() else { return }
                    await vm.loadModules(language: language.current.rawValue)
                    showModulePicker = true
                }
            }
        } message: {
            Text("me.changeRouteWarning")
        }
    }

    // MARK: - Текущий маршрут

    @ViewBuilder
    private var currentRouteSection: some View {
        if let active = vm.activeEnrollment {
            VStack(alignment: .leading, spacing: t.spacing.m) {
                LabelTag(text: L10n("me.currentRoute").text, color: t.terracotta)
                PageCard {
                    Text(active.name)
                        .font(t.font.bodyEmphasized)
                        .foregroundStyle(t.ink)
                    Text(L10n("today.weekDay").format(active.week, active.day))
                        .font(t.font.caption)
                        .foregroundStyle(t.inkMuted)
                }
                // Одновременно идёт только одна программа — смена через сброс текущей.
                Button(role: .destructive) {
                    confirmChangeRoute = true
                } label: {
                    Text("me.changeRoute")
                        .font(t.font.caption)
                        .foregroundStyle(t.safety)
                }
            }
        }
    }

    // MARK: - Напоминания

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            LabelTag(text: L10n("me.reminders").text, color: t.inkMuted)
            PageCard {
                TimeRow(title: "onboarding.reminders.morning", time: $vm.morning)
                Divider().foregroundStyle(t.border)
                TimeRow(title: "onboarding.reminders.afternoon", time: $vm.afternoon)
                Divider().foregroundStyle(t.border)
                TimeRow(title: "onboarding.reminders.evening", time: $vm.evening)
            }
            AccentButton(title: "common.save", isLoading: vm.isSaving) {
                Task { await vm.saveReminders() }
            }
        }
    }

    // MARK: - Язык

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            LabelTag(text: L10n("me.language").text, color: t.inkMuted)
            VStack(spacing: t.spacing.s) {
                ForEach(AppLanguage.allCases) { lang in
                    ChoiceCard(text: "\(lang.flag)  \(lang.nativeName)",
                               subtitle: lang.isAvailable ? nil : L10n("common.soon").text,
                               isSelected: language.current == lang,
                               isDisabled: !lang.isAvailable) {
                        language.set(lang)
                        Task { await vm.saveLanguage(lang) }
                    }
                }
            }
        }
    }

    // MARK: - Аккаунт

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            LabelTag(text: L10n("me.account").text, color: t.inkMuted)
            PageCard {
                if !auth.providers.isEmpty {
                    HStack {
                        Text("me.linkedChannels")
                            .font(t.font.body)
                            .foregroundStyle(t.inkMuted)
                        Spacer()
                        Text(auth.providers.joined(separator: ", "))
                            .font(t.font.caption)
                            .foregroundStyle(t.inkDim)
                    }
                }
                // Связка каналов: чтобы человек в боте и в приложении был одним
                // пользователем, а не двумя с разным прогрессом.
                if !auth.providers.contains("telegram") {
                    GhostButton(title: "auth.linkTelegram", icon: "link") {
                        showLinkSheet = true
                    }
                }
            }
            Button(role: .destructive) {
                Task {
                    await PushService.shared.unregister()
                    auth.signOut()
                }
            } label: {
                Text("me.signOut")
                    .font(t.font.body)
                    .foregroundStyle(t.safety)
            }
        }
    }

    // MARK: - О приложении

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: t.spacing.s) {
            LabelTag(text: L10n("me.about").text, color: t.inkMuted)
            Text("me.disclaimer")
                .font(t.font.caption)
                .foregroundStyle(t.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                // verbatim: имя продукта и номер версии не переводятся
                Text(verbatim: "Ridge \(version)")
                    .font(t.font.labelS)
                    .foregroundStyle(t.inkWhisper)
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
final class MeViewModel: ObservableObject {
    @Published var morning = DateComponents(hour: 10, minute: 0)
    @Published var afternoon = DateComponents(hour: 14, minute: 0)
    @Published var evening = DateComponents(hour: 20, minute: 0)

    @Published private(set) var activeEnrollment: EnrollmentSummary?
    @Published private(set) var modules: [ModuleSummary] = []
    @Published private(set) var isSaving = false
    @Published var error: APIError?

    private let api: RidgeAPIProtocol

    init(api: RidgeAPIProtocol = RidgeAPI.shared) {
        self.api = api
    }

    func load() async {
        do {
            let enrollments = try await api.enrollments()
            activeEnrollment = enrollments.first {
                $0.status == .active || $0.status == .selfcheckDue
            }
        } catch let e as APIError {
            error = e
        } catch {
            self.error = .server(status: 0, message: error.localizedDescription)
        }
    }

    /// Слоты сохраняются по одному за вызов — так устроен эндпоинт.
    func saveReminders() async {
        isSaving = true
        defer { isSaving = false }
        for (slot, time) in [("morning", morning), ("afternoon", afternoon), ("evening", evening)] {
            try? await api.updateSettings(slot: slot, hour: time.hour, minute: time.minute,
                                          timezone: TimeZone.current.identifier, language: nil)
        }
        Haptics.success()
    }

    /// Язык дублируется на сервер: не-каталожные эндпоинты берут его из
    /// `User.preferred_language`, а не из query.
    func saveLanguage(_ lang: AppLanguage) async {
        try? await api.updateSettings(slot: nil, hour: nil, minute: nil,
                                      timezone: nil, language: lang.rawValue)
    }

    @discardableResult
    func abandonActiveRoute() async -> Bool {
        do {
            try await api.abandonActive()
            await load()
            Haptics.success()
            return true
        } catch let e as APIError {
            error = e
            return false
        } catch {
            self.error = .server(status: 0, message: error.localizedDescription)
            return false
        }
    }

    func loadModules(language: String) async {
        modules = (try? await api.modules(lang: language)) ?? []
    }

    /// Выбор новой программы сразу после сброса текущей (см. showModulePicker в MeView).
    func enroll(in code: String) async {
        do {
            _ = try await api.enroll(moduleCode: code)
            await load()
            Haptics.success()
        } catch let e as APIError {
            error = e
        } catch {
            self.error = .server(status: 0, message: error.localizedDescription)
        }
    }
}

#Preview {
    NavigationStack { MeView() }
        .environmentObject(AuthViewModel())
        .environmentObject(LanguageStore.shared)
        .environment(\.theme, .warm)
}
