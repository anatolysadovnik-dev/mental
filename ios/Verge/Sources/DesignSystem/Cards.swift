import SwiftUI

// MARK: - PageCard

/// Базовая карточка-подложка.
struct PageCard<Content: View>: View {
    var padding: CGFloat = Theme.warm.spacing.l
    @ViewBuilder let content: () -> Content

    @Environment(\.theme) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: t.spacing.m) {
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: t.corners.card))
        .overlay(
            RoundedRectangle(cornerRadius: t.corners.card)
                .strokeBorder(t.border, lineWidth: 0.5)
        )
    }
}

// MARK: - ContentCard

/// Раскрывающаяся карточка с цветной полосой 3pt слева — образец `PlanItemCard` Rhythmos,
/// самый переиспользуемый компонент оттуда. В Ridge на ней стоят фокус, задание и аудио.
/// Шрифт основного текста карточки: `serif` — для «читательского» контента (фокус,
/// рефлексия), `system` — для списков и задач, где засечки мешают быстро сканировать
/// текст глазами (см. замечание о перегруженности курсивом в задачах).
enum ContentTextStyle {
    case serif
    case system
}

struct ContentCard: View {
    let label: String
    let title: String?
    /// Основной текст. Назван `text`, а не `body`: `body` — требование View.
    let text: String?
    var subtasks: [String] = []
    var accent: Color = Theme.warm.terracotta
    var icon: String?
    /// Визуальный «герой» экрана (фокус дня, см. композицию `TodayView`) — крупнее
    /// соседних карточек: это единственное место, где используется такое усиление,
    /// чтобы на экране дня был один явный центр внимания, а не ряд одинаковых блоков.
    var emphasized: Bool = false
    var textStyle: ContentTextStyle = .serif
    /// `nil` — карточка не раскрывается (короткий текст показан целиком).
    var isExpanded: Bool?
    var onTap: (() -> Void)?

    @Environment(\.theme) private var t

    private var expandable: Bool { isExpanded != nil }
    private var expanded: Bool { isExpanded ?? true }

    var body: some View {
        Group {
            if expandable {
                Button {
                    Haptics.selection()
                    onTap?()
                } label: { content }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(expandable
            ? Text(expanded ? "common.close" : "common.continue")
            : Text(""))
    }

    private var content: some View {
        HStack(alignment: .top, spacing: t.spacing.m) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: emphasized ? 4 : 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: t.spacing.s) {
                HStack(spacing: t.spacing.s) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(accent)
                            .accessibilityHidden(true)
                    }
                    LabelTag(text: label, color: accent)
                    Spacer(minLength: 0)
                    if expandable {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(t.inkMuted.opacity(0.5))
                            .accessibilityHidden(true)
                    }
                }

                if let title, !title.isEmpty {
                    Text(title)
                        .font(emphasized ? t.font.titleM : t.font.titleS)
                        .foregroundStyle(t.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let text, !text.isEmpty {
                    if expanded {
                        ContentText(raw: text, accent: accent, font: bodyFont)
                    } else {
                        // Свёрнуто — эмодзи-маркеры не несут смысла в однострочном
                        // превью, поэтому здесь просто очищенный текст, без блоков.
                        Text(ContentFormatter.plainPreview(text))
                            .font(bodyFont)
                            .foregroundStyle(t.inkMuted)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if expanded, !subtasks.isEmpty {
                    VStack(alignment: .leading, spacing: t.spacing.xs) {
                        ForEach(Array(subtasks.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: t.spacing.s) {
                                Circle()
                                    .fill(accent.opacity(0.5))
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 7)
                                    .accessibilityHidden(true)
                                Text(item)
                                    .font(bodyFont)
                                    .foregroundStyle(t.inkMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.trailing, 6)
                            }
                        }
                    }
                    .padding(.top, t.spacing.xs)
                }
            }
        }
        .padding(emphasized ? t.spacing.xl : t.spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: t.corners.card))
        .overlay(
            RoundedRectangle(cornerRadius: t.corners.card)
                .strokeBorder(t.border, lineWidth: 0.5)
        )
        .animation(.spring(duration: 0.32, bounce: 0.12), value: expanded)
    }

    private var emphasizedFont: Font { .system(size: 18, design: .serif) }

    private var bodyFont: Font {
        if emphasized { return emphasizedFont }
        return textStyle == .system ? t.font.body : t.font.bodyReading
    }
}

// MARK: - AccentCard

/// То же оформление, что у `ContentCard` (полоса-акцент + подложка), но без заголовка —
/// для карточек с собственной внутренней композицией (плеер аудио, текстовая практика),
/// чтобы вся «семья» карточек дня выглядела одним визуальным языком, а не вперемешку.
struct AccentCard<Content: View>: View {
    var accent: Color = Theme.warm.terracotta
    @ViewBuilder var content: () -> Content

    @Environment(\.theme) private var t

    var body: some View {
        HStack(alignment: .top, spacing: t.spacing.m) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: t.spacing.m) {
                content()
            }
        }
        .padding(t.spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: t.corners.card))
        .overlay(
            RoundedRectangle(cornerRadius: t.corners.card)
                .strokeBorder(t.border, lineWidth: 0.5)
        )
    }
}

// MARK: - Hero

/// Шапка экрана «Сегодня»: 152pt (компактно — заголовок дня живёт отдельно под шапкой),
/// градиент по времени суток, подпись-волна,
/// иконка времени суток справа-сверху и текстовый стек снизу-слева.
/// Заменяет собой навбар (`.navigationBarHidden(true)`).
struct HeroHeader: View {
    let dateLine: String
    let greeting: String
    let context: String?
    @Environment(\.theme) private var t
    @Environment(\.colorScheme) private var scheme

    private var timeOfDay: TimeOfDay { TimeOfDay.current() }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: timeOfDay.colors(dark: scheme == .dark),
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            WaveSignature()
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                .frame(height: 80)
                .offset(y: 20)
                .accessibilityHidden(true)

            Image(systemName: timeOfDay.symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityHidden(true)
                .padding(t.spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            VStack(alignment: .leading, spacing: t.spacing.xs) {
                Text(dateLine)
                    .labelUppercase()
                    .foregroundStyle(.white.opacity(0.8))
                Text(greeting)
                    .font(t.font.displaySerif(22))
                    .foregroundStyle(.white)
                if let context {
                    Text(context)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(t.spacing.xl)
        }
        .frame(height: 152)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Время суток — только для оформления шапки. К логике дня отношения не имеет:
/// «утро/вечер» в продукте это два набора вопросов, а не часы (см. `DaySession`).
enum TimeOfDay {
    case morning, day, evening, night

    static func current(_ date: Date = Date()) -> TimeOfDay {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<11:  return .morning
        case 11..<17: return .day
        case 17..<22: return .evening
        default:      return .night
        }
    }

    var symbol: String {
        switch self {
        case .morning: return "sunrise"
        case .day:     return "sun.max"
        case .evening: return "sunset"
        case .night:   return "moon.stars"
        }
    }

    var greetingKey: L10n {
        switch self {
        case .morning: return "today.greeting.morning"
        case .day:     return "today.greeting.day"
        case .evening: return "today.greeting.evening"
        case .night:   return "today.greeting.night"
        }
    }

    func colors(dark: Bool) -> [Color] {
        if dark {
            switch self {
            case .morning: return [Color(red: 0.36, green: 0.27, blue: 0.22),
                                   Color(red: 0.23, green: 0.20, blue: 0.19)]
            case .day:     return [Color(red: 0.30, green: 0.28, blue: 0.24),
                                   Color(red: 0.20, green: 0.19, blue: 0.18)]
            case .evening: return [Color(red: 0.34, green: 0.22, blue: 0.20),
                                   Color(red: 0.20, green: 0.17, blue: 0.19)]
            case .night:   return [Color(red: 0.19, green: 0.19, blue: 0.25),
                                   Color(red: 0.13, green: 0.13, blue: 0.17)]
            }
        }
        switch self {
        case .morning: return [Color(red: 0.85, green: 0.62, blue: 0.45),
                               Color(red: 0.78, green: 0.55, blue: 0.44)]
        case .day:     return [Color(red: 0.79, green: 0.58, blue: 0.42),
                               Color(red: 0.65, green: 0.56, blue: 0.47)]
        case .evening: return [Color(red: 0.72, green: 0.45, blue: 0.38),
                               Color(red: 0.48, green: 0.40, blue: 0.45)]
        case .night:   return [Color(red: 0.33, green: 0.34, blue: 0.44),
                               Color(red: 0.22, green: 0.23, blue: 0.31)]
        }
    }
}

/// Спокойная волна-подпись поверх градиента.
struct WaveSignature: Shape {
    var amplitude: CGFloat = 8
    var frequency: CGFloat = 1.8

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 1, rect.height > 1 else { return path }
        let midY = rect.midY
        path.move(to: CGPoint(x: 0, y: midY))
        var x: CGFloat = 0
        while x <= rect.width {
            let angle = (x / rect.width) * .pi * 2 * frequency
            path.addLine(to: CGPoint(x: x, y: midY + sin(angle) * amplitude))
            x += 4
        }
        return path
    }
}

// MARK: - Previews

#Preview("Карточки") {
    ScrollView {
        VStack(spacing: 16) {
            ContentCard(label: "Фокус дня",
                        title: "Замечать автоматическое согласие",
                        text: "Сегодня важно начать замечать моменты, когда вы соглашаетесь быстрее, чем успеваете подумать.",
                        accent: Theme.warm.terracotta,
                        icon: "target")
            ContentCard(label: "Задание дня",
                        title: nil,
                        text: "В течение дня отметьте три ситуации.",
                        subtasks: ["Где было легко сказать «нет»", "Где не получилось", "Что почувствовали"],
                        accent: Theme.warm.sage,
                        icon: "checkmark.square",
                        isExpanded: true) {}
        }
        .padding()
    }
    .background(Theme.warm.paper)
}

#Preview("Шапка") {
    VStack(spacing: 0) {
        HeroHeader(dateLine: "ПН · 7 СЕН",
                   greeting: "Доброе утро",
                   context: "Неделя 2 · День 3")
        Spacer()
    }
    .background(Theme.warm.paper)
    .ignoresSafeArea()
}
