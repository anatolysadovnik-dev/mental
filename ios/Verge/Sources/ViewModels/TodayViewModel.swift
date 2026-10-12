import Foundation
import SwiftUI

@MainActor
final class TodayViewModel: ObservableObject {
    @Published private(set) var day: DayResponse?
    @Published private(set) var enrollment: EnrollmentSummary?
    @Published private(set) var modules: [ModuleSummary] = []

    @Published private(set) var isLoading = false
    /// Отдельный флаг: закрытие дня не должно гасить весь экран в спиннер.
    @Published private(set) var isSubmitting = false
    @Published var error: APIError?

    // ответы вечерней сессии
    @Published var taskStatus: TaskStatus?
    @Published var taskAnswer = ""
    @Published var quizAnswer: String?
    @Published var reflections: [String] = []

    @Published var showWeekIntro = false

    private let api: RidgeAPIProtocol
    /// Хранится, чтобы отменять на исчезновении экрана — в Rhythmos отмены не было вовсе.
    private var loadTask: Task<Void, Never>?

    init(api: RidgeAPIProtocol = RidgeAPI.shared) {
        self.api = api
    }

    deinit { loadTask?.cancel() }

    var hasRoute: Bool { enrollment != nil }
    var eid: Int? { enrollment?.enrollmentId }

    /// Шаги текущей сессии, собранные бэкендом (единый источник истины с ботом).
    var steps: [DayStep] { day?.steps ?? [] }

    var session: DaySession { day?.session ?? .morning }

    /// Сегодняшний день уже закрывали — открывать новый нельзя.
    var isDoneToday: Bool { day?.doneToday == true && session == .morning }

    var reflectionPrompts: [String] {
        steps.filter { $0.kind == .freeText }.compactMap(\.prompt)
    }

    var quizStep: DayStep? { steps.first { $0.kind == .quiz } }
    var focusStep: DayStep? { steps.first { $0.kind == .focustask } }
    var audioStep: DayStep? { steps.first { $0.kind == .audio } }
    var textStep: DayStep? { steps.first { $0.kind == .text } }
    var intentSteps: [DayStep] { steps.filter { $0.kind == .info } }

    // MARK: - Загрузка

    func load() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.performLoad() }
    }

    func cancelLoading() {
        loadTask?.cancel()
    }

    private func performLoad() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let enrollments = try await api.enrollments()
            // Одновременно идёт только одна программа (так же подаёт бот, и бэкенд
            // теперь отдаёт 409 на попытку начать вторую). Берём активную.
            enrollment = enrollments.first {
                $0.status == .active || $0.status == .selfcheckDue
            } ?? enrollments.first { $0.status == .completed }

            guard let eid = enrollment?.enrollmentId else {
                day = nil
                return
            }
            let response = try await api.daySteps(eid: eid)
            try Task.checkCancellation()
            apply(response)
        } catch is CancellationError {
            return
        } catch let e as APIError {
            error = e
        } catch {
            self.error = .server(status: 0, message: error.localizedDescription)
        }
    }

    private func apply(_ response: DayResponse) {
        day = response
        // Вводный экран недели — один раз за неделю, а не при каждой загрузке дня 1
        // (бот отправляет это сообщением в чат, повтор там не мешает; шит — мешает).
        if response.day == 1, response.weekIntro?.introScreen?.isEmpty == false,
           let eid = enrollment?.enrollmentId, let week = response.week,
           !hasSeenWeekIntro(eid: eid, week: week) {
            showWeekIntro = true
            markWeekIntroSeen(eid: eid, week: week)
        }
        // подготовить пустые ответы под число вопросов рефлексии
        let promptCount = response.steps.filter { $0.kind == .freeText }.count
        if reflections.count != promptCount {
            reflections = Array(repeating: "", count: promptCount)
        }
    }

    private func hasSeenWeekIntro(eid: Int, week: Int) -> Bool {
        UserDefaults.standard.bool(forKey: weekIntroSeenKey(eid: eid, week: week))
    }

    private func markWeekIntroSeen(eid: Int, week: Int) {
        UserDefaults.standard.set(true, forKey: weekIntroSeenKey(eid: eid, week: week))
    }

    private func weekIntroSeenKey(eid: Int, week: Int) -> String {
        "ridge_week_intro_seen_\(eid)_\(week)"
    }

    func refresh() async {
        await performLoad()
    }

    // MARK: - Действия дня

    func openDay() async {
        guard let eid, !isSubmitting else { return }
        isSubmitting = true
        error = nil
        defer { isSubmitting = false }
        do {
            _ = try await api.openDay(eid: eid)
            Haptics.success()
            await performLoad()
        } catch let e as APIError {
            error = e
            Haptics.error()
        } catch {
            self.error = .server(status: 0, message: error.localizedDescription)
        }
    }

    /// Закрытие дня продвигает маршрут и **не идемпотентно** на бэкенде: два вызова
    /// раньше означали два дня. Бэкенд теперь возвращает `already_closed`, но защита
    /// от повторного нажатия нужна и здесь — не полагаемся на одну сторону.
    func closeDay() async -> Bool {
        guard let eid, !isSubmitting else { return false }
        isSubmitting = true
        error = nil
        defer { isSubmitting = false }
        do {
            let result = try await api.closeDay(
                eid: eid,
                taskStatus: taskStatus,
                taskAnswer: taskAnswer.isEmpty ? nil : taskAnswer,
                quizAnswer: quizAnswer,
                reflection: reflections.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            if result.alreadyClosed == true {
                // день уже закрывали — не ошибка, просто обновляем экран
                await performLoad()
                return true
            }
            Haptics.success()
            resetAnswers()
            await performLoad()
            return true
        } catch let e as APIError {
            error = e
            Haptics.error()
            return false
        } catch {
            self.error = .server(status: 0, message: error.localizedDescription)
            return false
        }
    }

    private func resetAnswers() {
        taskStatus = nil
        taskAnswer = ""
        quizAnswer = nil
        reflections = []
    }

    // MARK: - Выбор маршрута

    func loadModules(language: String) async {
        modules = (try? await api.modules(lang: language)) ?? []
    }

    func enroll(in code: String) async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await api.enroll(moduleCode: code)
            await performLoad()
        } catch let e as APIError {
            error = e
        } catch {
            self.error = .server(status: 0, message: error.localizedDescription)
        }
    }

    // MARK: - Заметка

    func addNote(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? await api.addNote(trimmed, moduleCode: enrollment?.module)
    }
}
