import Foundation

/// Модели ответов Mental API.
///
/// Соглашение (как в Rhythmos): у каждой структуры **явный** `CodingKeys`, а не
/// `keyDecodingStrategy = .convertFromSnakeCase`. Так видно точное имя поля на проводе,
/// и переименование на бэкенде ловится компилятором, а не в рантайме.
///
/// Всё, что бэкенд отдаёт свободным JSON (`quiz`, `passport`, `subtasks`, `reflection`,
/// `intent_questions`, `key_themes`), декодируется мягко: поля опциональные, массивы
/// с дефолтом `[]`. Валидации на бэкенде нет — клиент не должен падать от пустоты.

// MARK: - Авторизация

struct AuthResponse: Codable, Sendable {
    let accessToken: String
    let tokenType: String
    let expiresAt: String?
    let userId: Int
    let language: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresAt = "expires_at"
        case userId = "user_id"
        case language
    }
}

struct MeResponse: Codable, Sendable {
    let userId: Int
    let language: String
    let timezone: String
    let providers: [String]

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case language, timezone, providers
    }
}

struct LinkCodeResponse: Codable, Sendable {
    let code: String
    let expiresInSeconds: Int

    enum CodingKeys: String, CodingKey {
        case code
        case expiresInSeconds = "expires_in_seconds"
    }
}

struct LinkResult: Codable, Sendable {
    let userId: Int
    let merged: Bool

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case merged
    }
}

// MARK: - Каталог программ

struct ModuleSummary: Codable, Identifiable, Sendable {
    let code: String
    let name: String
    let subtitle: String?
    let contentVersion: String?
    let passport: Passport?

    var id: String { code }

    enum CodingKeys: String, CodingKey {
        case code, name, subtitle, passport
        case contentVersion = "content_version"
    }
}

/// Паспорт программы (§4 архитектуры) — словарь длинных строк.
struct Passport: Codable, Sendable {
    let name: String?
    let intro: String?
    let forWhom: [String]?
    let extraSupport: String?
    let why: String?
    let whatUserGets: [String]?
    let mainResult: String?
    let important: String?

    enum CodingKeys: String, CodingKey {
        case name, intro, why, important
        case forWhom = "for_whom"
        case extraSupport = "extra_support"
        case whatUserGets = "what_user_gets"
        case mainResult = "main_result"
    }
}

struct EnrollmentSummary: Codable, Identifiable, Sendable {
    let enrollmentId: Int
    let module: String
    let name: String
    let status: EnrollmentStatus
    let week: Int
    let day: Int
    let mode: String

    var id: Int { enrollmentId }

    enum CodingKeys: String, CodingKey {
        case enrollmentId = "enrollment_id"
        case module, name, status, week, day, mode
    }
}

struct EnrollResponse: Codable, Sendable {
    let enrollmentId: Int
    let module: String
    let name: String
    let mode: String
    let week: Int
    let day: Int
    let status: EnrollmentStatus

    enum CodingKeys: String, CodingKey {
        case enrollmentId = "enrollment_id"
        case module, name, mode, week, day, status
    }
}

// MARK: - День

/// Ответ `/day-steps`: тот же день, что `/today`, но уже разложенный в шаги.
///
/// Три формы различаются по `status` — переключаться нужно ДО обращения к полям:
/// `completed` (2 поля) · `selfcheck_due` (2 поля) · активный день (полный payload).
struct DayResponse: Codable, Sendable {
    let status: String
    let doneToday: Bool?
    let session: DaySession?
    let week: Int?
    let day: Int?
    let dayTitle: String?
    let weekIntro: WeekIntro?
    let steps: [DayStep]

    enum CodingKeys: String, CodingKey {
        case status, session, week, day, steps
        case doneToday = "done_today"
        case dayTitle = "day_title"
        case weekIntro = "week_intro"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        doneToday = try c.decodeIfPresent(Bool.self, forKey: .doneToday)
        session = try c.decodeIfPresent(DaySession.self, forKey: .session)
        week = try c.decodeIfPresent(Int.self, forKey: .week)
        day = try c.decodeIfPresent(Int.self, forKey: .day)
        dayTitle = try c.decodeIfPresent(String.self, forKey: .dayTitle)
        weekIntro = try c.decodeIfPresent(WeekIntro.self, forKey: .weekIntro)
        steps = try c.decodeIfPresent([DayStep].self, forKey: .steps) ?? []
    }

    var isActive: Bool { status == "active" }
    var isSelfcheckDue: Bool { status == "selfcheck_due" }
    var isCompleted: Bool { status == "completed" }
}

/// Вводный экран недели — показывается один раз, в день 1 (как в боте).
struct WeekIntro: Codable, Sendable {
    let title: String?
    let introScreen: String?
    let meaning: String?
    let goal: String?
    let result: String?
    let keyThemes: [String]

    enum CodingKeys: String, CodingKey {
        case title, meaning, goal, result
        case introScreen = "intro_screen"
        case keyThemes = "key_themes"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        introScreen = try c.decodeIfPresent(String.self, forKey: .introScreen)
        meaning = try c.decodeIfPresent(String.self, forKey: .meaning)
        goal = try c.decodeIfPresent(String.self, forKey: .goal)
        result = try c.decodeIfPresent(String.self, forKey: .result)
        keyThemes = try c.decodeIfPresent([String].self, forKey: .keyThemes) ?? []
    }
}

/// Один шаг прохождения дня. Поля зависят от `kind`, поэтому почти все опциональны.
struct DayStep: Codable, Identifiable, Sendable {
    let kind: DayStepKind
    let role: String?
    /// Предрендеренный текст для Telegram. iOS его игнорирует и верстает по полям —
    /// он содержит HTML-разметку бота.
    let text: String?
    let question: String?
    let prompt: String?
    let focus: String?
    let task: DayTask?
    let asksStatus: Bool?
    let options: [String]
    let code: String?
    let title: String?

    /// Стабильный идентификатор для `ForEach`: шаги приходят массивом без id,
    /// а порядок внутри дня фиксирован.
    let id = UUID()

    enum CodingKeys: String, CodingKey {
        case kind, role, text, question, prompt, focus, task, options, code, title
        case asksStatus = "asks_status"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(DayStepKind.self, forKey: .kind)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        question = try c.decodeIfPresent(String.self, forKey: .question)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        focus = try c.decodeIfPresent(String.self, forKey: .focus)
        task = try c.decodeIfPresent(DayTask.self, forKey: .task)
        asksStatus = try c.decodeIfPresent(Bool.self, forKey: .asksStatus)
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        code = try c.decodeIfPresent(String.self, forKey: .code)
        title = try c.decodeIfPresent(String.self, forKey: .title)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encodeIfPresent(text, forKey: .text)
    }
}

struct DayTask: Codable, Sendable {
    let text: String?
    let subtasks: [String]

    enum CodingKeys: String, CodingKey { case text, subtasks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        subtasks = try c.decodeIfPresent([String].self, forKey: .subtasks) ?? []
    }
}

struct OpenDayResponse: Codable, Sendable {
    let session: DaySession
    let week: Int
    let day: Int
}

struct CloseDayResponse: Codable, Sendable {
    let status: EnrollmentStatus
    let week: Int
    let day: Int
    /// `true`, если день уже закрывали сегодня — повторный вызов НЕ промотал день.
    let alreadyClosed: Bool?

    enum CodingKeys: String, CodingKey {
        case status, week, day
        case alreadyClosed = "already_closed"
    }
}

// MARK: - Самопроверка

struct SelfcheckQuestions: Codable, Sendable {
    let week: Int
    let questions: [SelfcheckQuestion]
    /// 5 «утренних» + 5 «вечерних» маркеров — спрашиваются РАЗ В НЕДЕЛЮ, блоком
    /// перед вопросами самопроверки, а не каждый день (коммит 9990668).
    let morningMarkers: [Marker]
    let eveningMarkers: [Marker]

    enum CodingKeys: String, CodingKey {
        case week, questions
        case morningMarkers = "morning_markers"
        case eveningMarkers = "evening_markers"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        week = try c.decode(Int.self, forKey: .week)
        questions = try c.decodeIfPresent([SelfcheckQuestion].self, forKey: .questions) ?? []
        morningMarkers = try c.decodeIfPresent([Marker].self, forKey: .morningMarkers) ?? []
        eveningMarkers = try c.decodeIfPresent([Marker].self, forKey: .eveningMarkers) ?? []
    }
}

struct SelfcheckQuestion: Codable, Identifiable, Sendable {
    let q: Int
    let question: String
    let options: [String]

    var id: Int { q }
}

struct Marker: Codable, Identifiable, Sendable {
    let idx: Int
    let question: String
    let options: [String]

    var id: Int { idx }
}

/// Результат самопроверки. Баллы скрыты намеренно (§16) — бэкенд их не отдаёт.
struct SelfcheckResult: Codable, Sendable {
    let zone: Zone
    let week: Int?
    let userText: String?
    let recommendation: String?
    /// Мягкие тематические блоки по критичным ответам. Не диагноз, не «красный флаг».
    let criticals: [String]
    let blocksProgression: Bool?

    enum CodingKeys: String, CodingKey {
        case zone, week, recommendation, criticals
        case userText = "user_text"
        case blocksProgression = "blocks_progression"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zone = try c.decode(Zone.self, forKey: .zone)
        week = try c.decodeIfPresent(Int.self, forKey: .week)
        userText = try c.decodeIfPresent(String.self, forKey: .userText)
        recommendation = try c.decodeIfPresent(String.self, forKey: .recommendation)
        blocksProgression = try c.decodeIfPresent(Bool.self, forKey: .blocksProgression)
        // бэкенд отдаёт либо массив строк, либо массив объектов с текстом — берём мягко
        if let strings = try? c.decodeIfPresent([String].self, forKey: .criticals) {
            criticals = strings ?? []
        } else if let objects = try? c.decodeIfPresent([CriticalBlock].self, forKey: .criticals) {
            criticals = (objects ?? []).compactMap(\.additionalText)
        } else {
            criticals = []
        }
    }
}

private struct CriticalBlock: Codable {
    let additionalText: String?
    enum CodingKeys: String, CodingKey { case additionalText = "additional_text" }
}

// MARK: - Путь / аналитика

struct EnrollmentStatusResponse: Codable, Sendable {
    let module: String
    let name: String
    let status: EnrollmentStatus
    let week: Int
    let day: Int
    let mode: String
    /// Захардкожены в бэкенде (6/7/42) и не выводятся из контента — не считать самим.
    let totalWeeks: Int
    let totalDays: Int
    let daysCompleted: Int
    let daysTotal: Int
    let startedAt: String?
    let weeks: [WeekZone]
    /// Названия недель — отдельное поле от `weeks` (то содержит только пройденные
    /// недели с зоной); нужно для «Пути», чтобы показать все недели маршрута.
    let weekTitles: [WeekTitle]

    enum CodingKeys: String, CodingKey {
        case module, name, status, week, day, mode, weeks
        case totalWeeks = "total_weeks"
        case totalDays = "total_days"
        case daysCompleted = "days_completed"
        case daysTotal = "days_total"
        case startedAt = "started_at"
        case weekTitles = "week_titles"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        module = try c.decode(String.self, forKey: .module)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(EnrollmentStatus.self, forKey: .status)
        week = try c.decode(Int.self, forKey: .week)
        day = try c.decode(Int.self, forKey: .day)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "normal"
        totalWeeks = try c.decodeIfPresent(Int.self, forKey: .totalWeeks) ?? 6
        totalDays = try c.decodeIfPresent(Int.self, forKey: .totalDays) ?? 7
        daysCompleted = try c.decodeIfPresent(Int.self, forKey: .daysCompleted) ?? 0
        daysTotal = try c.decodeIfPresent(Int.self, forKey: .daysTotal) ?? 42
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        weeks = try c.decodeIfPresent([WeekZone].self, forKey: .weeks) ?? []
        weekTitles = try c.decodeIfPresent([WeekTitle].self, forKey: .weekTitles) ?? []
    }
}

struct WeekZone: Codable, Identifiable, Sendable {
    let week: Int
    let zone: Zone

    var id: Int { week }
}

struct WeekTitle: Codable, Identifiable, Sendable {
    let week: Int
    let title: String?

    var id: Int { week }
}

/// Ответ ИИ-разборов. `enabled == false`, если ключ LLM не настроен.
struct InsightResponse: Codable, Sendable {
    let enabled: Bool
    let text: String?
}

struct FinalProductItem: Codable, Identifiable, Sendable {
    let id: Int
    let module: String?
    let moduleName: String?
    let createdAt: String?
    let sections: [String]

    enum CodingKeys: String, CodingKey {
        case id, module, sections
        case moduleName = "module_name"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        module = try c.decodeIfPresent(String.self, forKey: .module)
        moduleName = try c.decodeIfPresent(String.self, forKey: .moduleName)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        sections = try c.decodeIfPresent([String].self, forKey: .sections) ?? []
    }
}

// MARK: - Дневник

struct JournalEntry: Codable, Identifiable, Sendable {
    let id: Int
    let sourceType: JournalSourceType
    let moduleCode: String?
    let moduleName: String?
    let week: Int?
    let day: Int?
    let text: String
    /// Наивный ISO без таймзоны — парсится как локальное время (см. `DateParsing`).
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, week, day, text
        case sourceType = "source_type"
        case moduleCode = "module_code"
        case moduleName = "module_name"
        case createdAt = "created_at"
    }
}

struct JournalList: Codable, Sendable {
    let entries: [JournalEntry]
}

// MARK: - Интейк (входная самооценка, слой D)

struct IntakeResponse: Codable, Sendable {
    let version: String?
    /// Обязателен к показу: снимает тревогу и юридически важен («результат не является
    /// диагнозом»). Не пропускать экран, даже если текст длинный.
    let clientIntro: String?
    let answerScale: [IntakeScaleOption]
    let startButton: String?
    let questions: [IntakeQuestion]

    enum CodingKeys: String, CodingKey {
        case version, questions
        case clientIntro = "client_intro"
        case answerScale = "answer_scale"
        case startButton = "start_button"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        clientIntro = try c.decodeIfPresent(String.self, forKey: .clientIntro)
        startButton = try c.decodeIfPresent(String.self, forKey: .startButton)
        questions = try c.decodeIfPresent([IntakeQuestion].self, forKey: .questions) ?? []
        // шкала приходит либо массивом строк, либо массивом {value,text} — принимаем оба
        if let objects = try? c.decodeIfPresent([IntakeScaleOption].self, forKey: .answerScale) {
            answerScale = objects ?? IntakeScaleOption.fallback
        } else if let strings = try? c.decodeIfPresent([String].self, forKey: .answerScale) {
            answerScale = (strings ?? []).enumerated().map {
                IntakeScaleOption(value: $0.offset, text: $0.element)
            }
        } else {
            answerScale = IntakeScaleOption.fallback
        }
    }
}

struct IntakeScaleOption: Codable, Identifiable, Sendable {
    let value: Int
    let text: String

    var id: Int { value }

    /// Шкала 0–4 из §12.1 архитектуры — фолбэк, если бэкенд её не прислал.
    static let fallback: [IntakeScaleOption] = [
        .init(value: 0, text: "совсем не про меня"),
        .init(value: 1, text: "редко бывает"),
        .init(value: 2, text: "иногда бывает"),
        .init(value: 3, text: "часто про меня"),
        .init(value: 4, text: "почти всегда про меня"),
    ]
}

struct IntakeQuestion: Codable, Identifiable, Sendable {
    let n: Int
    let direction: String
    let text: String

    var id: Int { n }

    var directionEnum: Direction? { Direction(rawValue: direction.uppercased()) }
}

/// Результат интейка: ведущее направление + 2 доп. фокуса + рекомендованная программа.
/// Право выбора остаётся за пользователем — автоперехода быть не должно (§12).
struct IntakeResult: Codable, Sendable {
    let leading: String?
    let focus1: String?
    let focus2: String?
    let isSoft: Bool?
    let recommendedModule: String?
    /// Имя направления (не модуля) — нужно для «🔒 <тема> — скоро», когда программы ещё нет.
    let leadingName: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case leading, focus1, focus2
        case isSoft = "is_soft"
        case recommendedModule = "leading_module"
        case leadingName = "leading_name"
        case text = "result_text"
    }
}

// MARK: - Настройки и аудио

struct UserSettings: Codable, Sendable {
    let timezone: String?
    let language: String?
    let morning: ReminderSlot?
    let afternoon: ReminderSlot?
    let evening: ReminderSlot?
}

struct ReminderSlot: Codable, Sendable {
    let hour: Int
    let minute: Int
}

struct AudioResolve: Codable, Sendable {
    let code: String
    let title: String?
    let language: String?
    let mime: String?
    /// `nil`, пока не настроен `audio_public_base_url` — тогда файл берётся
    /// с `/api/v1/audio/{code}/file?lang=…`.
    let url: String?
    let fallback: Bool?

    enum CodingKeys: String, CodingKey {
        case code, title, language, mime, url, fallback
    }
}

/// Текстовая практика — независимая от аудио сущность (своё тело, свой `day_range`).
/// В отличие от аудио, тело приходит целиком в ответе — файла нет.
struct TextResolve: Codable, Sendable {
    let code: String
    let title: String?
    let language: String?
    let body: String
    let fallback: Bool?

    enum CodingKeys: String, CodingKey {
        case code, title, language, body, fallback
    }
}

struct AskAIResponse: Codable, Sendable {
    let enabled: Bool?
    let text: String?
    let answer: String?

    /// Бэкенд называет поле по-разному в разных ветках — берём что есть.
    var message: String? { text ?? answer }
}
