import SwiftUI

/// Дизайн-система Ridge — палитра, типографика, отступы, радиусы.
///
/// Отличия от Rhythmos, откуда взят визуальный язык (осознанные, см. RIDGE-IOS-PROMPT §2):
///
/// 1. **Есть тёмная тема.** В Rhythmos все 25 colorset'ов имели один universal-вариант
///    без `appearances`, и добавлять тему потом оказалось дорого. Здесь каждый цвет
///    объявлен парой light/dark прямо в коде (`Color(light:dark:)`), а не в ассетах:
///    пара видна рядом, её нельзя забыть, и она не требует правки в UI Xcode.
/// 2. **Нет мёртвых токенов.** `Done`/`Partial`/`Skipped` в Rhythmos побайтово дублировали
///    `Sage`/`Amber`/`InkDim`, а четыре `*Label`-цвета не использовались вовсе. Здесь
///    статусные цвета — функции от семантических, отдельных значений нет.
/// 3. **`@Environment(\.theme)` используется честно.** В Rhythmos ключ был объявлен, но
///    каждый компонент брал `Theme.warm` напрямую. Здесь ключ есть и работает; `Theme.warm`
///    остался значением по умолчанию, а не обходным путём.
struct Theme: Sendable {
    static let warm = Theme()

    // MARK: - Палитра
    //
    // Светлые значения — из Rhythmos (§2 брифа), приведены точно. Тёмные подобраны так,
    // чтобы сохранить тёплый характер: не чёрный, а тёплый уголь; акцент чуть светлее и
    // менее насыщен — терракота исходной яркости на тёмном фоне «звенит».

    let paper: Color
    let surface: Color
    let surfaceSecondary: Color
    let ink: Color
    let inkMuted: Color
    let inkDim: Color
    let inkWhisper: Color
    let border: Color
    let borderStrong: Color
    let terracotta: Color
    let sage: Color
    let dustyBlue: Color
    let amber: Color
    let safety: Color

    private init() {
        paper            = Color(light: 0xFAF6F0, dark: 0x171513)
        surface          = Color(light: 0xFFFFFF, dark: 0x201D1A)
        surfaceSecondary = Color(light: 0xF5F1EB, dark: 0x2A2622)
        ink              = Color(light: 0x2B2823, dark: 0xF2EDE6)
        inkMuted         = Color(light: 0x6B6560, dark: 0xB5ADA4)
        inkDim           = Color(light: 0x9B958F, dark: 0x8A837B)
        inkWhisper       = Color(light: 0xD1CCC5, dark: 0x4A443E)
        border           = Color(light: 0xE8E3DC, dark: 0x322D28)
        borderStrong     = Color(light: 0xC8C2BA, dark: 0x4A443E)
        terracotta       = Color(light: 0xC97B5A, dark: 0xD98F6E)
        sage             = Color(light: 0x7A8B73, dark: 0x93A48B)
        dustyBlue        = Color(light: 0x7B8FA8, dark: 0x93A6BD)
        amber            = Color(light: 0xD9A05B, dark: 0xE0AE72)
        safety           = Color(light: 0xB4574A, dark: 0xD4796B)
    }

    // MARK: - Статусные цвета (§2.6: не заводим дублирующий слой токенов)

    /// Статус задания: Сделано / Частично / Не сделано.
    func statusColor(_ status: TaskStatus) -> Color {
        switch status {
        case .done:    return sage
        case .partial: return amber
        case .notDone: return inkDim
        }
    }

    /// Зона недели GREEN / YELLOW / RED (§7.2 архитектуры).
    func zoneColor(_ zone: Zone) -> Color {
        switch zone {
        case .green:  return sage
        case .yellow: return amber
        case .red:    return safety
        }
    }

    // MARK: - Типографика
    //
    // Три «личности» (замысел Rhythmos, сохраняем): serif-italic = рефлексивное,
    // rounded = числа, system = интерфейс. Кастомных шрифтов нет.

    struct Fonts: Sendable {
        func displaySerif(_ size: CGFloat = 28) -> Font {
            .system(size: size, design: .serif).italic()
        }

        var titleL: Font { .system(size: 24, weight: .medium) }
        var titleM: Font { .system(size: 22, weight: .medium) }
        var titleS: Font { .system(size: 17, weight: .medium) }

        var body: Font { .system(size: 15) }
        var bodyEmphasized: Font { .system(size: 15, weight: .medium) }
        var bodySerif: Font { .system(size: 15, design: .serif).italic() }
        /// Текст карточек-чтения (фокус/задание дня и т.п.) — без italic, в паре с
        /// `displaySerif` над ними: `body` рядом с serif-заголовком выглядел как два
        /// случайных шрифта вперемешку.
        var bodyReading: Font { .system(size: 16, design: .serif) }

        var caption: Font { .system(size: 13) }
        var labelS: Font { .system(size: 11, weight: .medium) }
        var labelUppercase: Font { .system(size: 11, weight: .medium) }
        var tab: Font { .system(size: 10, weight: .medium) }

        var numericL: Font { .system(size: 28, weight: .medium, design: .rounded) }
        var numericM: Font { .system(size: 17, weight: .medium, design: .rounded) }
    }

    let font = Fonts()

    // MARK: - Отступы

    struct Spacing: Sendable {
        let xs: CGFloat = 4
        let s: CGFloat = 8
        let m: CGFloat = 12
        let l: CGFloat = 16
        let xl: CGFloat = 20
        let section: CGFloat = 24
        let xxl: CGFloat = 28
        let safeTop: CGFloat = 12
    }

    let spacing = Spacing()

    // MARK: - Радиусы

    struct Corners: Sendable {
        let card: CGFloat = 14
        let cardLarge: CGFloat = 16
        let button: CGFloat = 14
        let input: CGFloat = 12
        /// Для «таблеток» на практике используется `Capsule()`; значение — для рамок.
        let pill: CGFloat = 100
    }

    let corners = Corners()
}

// MARK: - Color с парой light/dark

extension Color {
    /// Цвет с явными вариантами для светлой и тёмной темы.
    ///
    /// Пара задаётся здесь, а не в ассетах: оба значения видны рядом, и нельзя добавить
    /// цвет, забыв тёмный вариант, — ровно та ошибка, что случилась в Rhythmos.
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(rgbHex: dark)
                : UIColor(rgbHex: light)
        })
    }
}

extension UIColor {
    fileprivate convenience init(rgbHex hex: UInt32) {
        self.init(
            red:   CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue:  CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.warm
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Модификаторы

extension View {
    /// 11pt medium, uppercase, tracking 0.5 — заголовок секции.
    func labelUppercase() -> some View {
        self
            .font(Theme.warm.font.labelUppercase)
            .tracking(0.5)
            .textCase(.uppercase)
    }
}
