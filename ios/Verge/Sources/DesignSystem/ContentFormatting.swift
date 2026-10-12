import SwiftUI

/// Контент модулей `bound`/`real` писался для бота: единственным инструментом разметки
/// там были эмодзи в начале строки (❓ — вопрос, 🔸 — пункт списка, 🧭/🎯/⚡/🌊/🌿/🔍/🗺️ —
/// декоративный акцент абзаца). В приложении есть нормальная типографика и отступы,
/// поэтому эти маркеры не показываем как есть, а превращаем в вид строки — экран
/// не трогаем (ANX и боевая часть бота эмодзи не теряют, это чисто экранное форматирование).
enum ContentLine {
    case paragraph(String)
    case question(String)
    case bullet(String)

    var text: String {
        switch self {
        case .paragraph(let s), .question(let s), .bullet(let s): return s
        }
    }
}

enum ContentFormatter {
    private static let questionGlyph: Character = "❓"
    private static let bulletGlyph: Character = "🔸"

    /// YAML фолдит одиночные переносы строк в пробел и оставляет перенос только на
    /// границе абзаца/пункта — поэтому после `components(separatedBy:)` по `\n`
    /// каждая строка уже целый абзац или целый пункт списка.
    static func parse(_ raw: String) -> [ContentLine] {
        raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                if line.first == questionGlyph {
                    return .question(stripLeadingGlyph(line))
                }
                if line.first == bulletGlyph {
                    return .bullet(stripLeadingGlyph(line))
                }
                return .paragraph(stripLeadingDecoration(line))
            }
    }

    /// Та же разборка, но в одну строку (без переносов) — для свёрнутого превью карточки.
    static func plainPreview(_ raw: String) -> String {
        parse(raw).map(\.text).joined(separator: " ")
    }

    private static func stripLeadingGlyph(_ line: String) -> String {
        String(line.dropFirst().drop(while: \.isWhitespace))
    }

    /// Срезает декоративный эмодзи-маркер абзаца (🧭/🎯/⚡/🌊/🌿/🔍/🗺️ и т.п., не только
    /// перечисленные — любой ведущий эмодзи-символ). Смысловой нагрузки не несёт,
    /// в приложении его заменяет обычный межабзацный отступ.
    private static func stripLeadingDecoration(_ line: String) -> String {
        guard let first = line.unicodeScalars.first, first.properties.isEmoji,
              let ch = line.first, !ch.isLetter, !ch.isNumber else { return line }
        return String(line.dropFirst().drop(while: \.isWhitespace))
    }
}

/// Рендерит многоабзацный контент бот-эры с правильной типографикой вместо сырых эмодзи:
/// вопросы — отдельной акцентной строкой, пункты — обычным списком, остальное — абзацами.
struct ContentText: View {
    let raw: String
    var accent: Color = Theme.warm.terracotta
    var color: Color?
    /// Переопределение шрифта абзацев (кроме вопросов) — используется для
    /// визуально крупного «фокуса дня» (см. `ContentCard.emphasized`).
    var font: Font?

    @Environment(\.theme) private var t

    var body: some View {
        let lines = ContentFormatter.parse(raw)
        VStack(alignment: .leading, spacing: t.spacing.s) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .paragraph(let text):
                    Text(text)
                        .font(font ?? t.font.bodyReading)
                        .foregroundStyle(color ?? t.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .question(let text):
                    Text(text)
                        .font(t.font.bodyEmphasized)
                        .foregroundStyle(t.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .bullet(let text):
                    HStack(alignment: .top, spacing: t.spacing.s) {
                        Circle()
                            .fill(accent.opacity(0.5))
                            .frame(width: 4, height: 4)
                            .padding(.top, 7)
                            .accessibilityHidden(true)
                        Text(text)
                            .font(font ?? t.font.bodyReading)
                            .foregroundStyle(color ?? t.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            // без этого отступа перенос строки упирается в самый край
                            // карточки и выглядит как обрыв слова, а не перенос.
                            .padding(.trailing, 6)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
