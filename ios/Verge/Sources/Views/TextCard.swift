import SwiftUI

/// Текстовая практика дня — самостоятельная сущность, параллельная аудио (см. `AudioCard`):
/// своя запись в БД (`text_assets`/`text_variants`), свой `day_range`, может быть
/// вместе с аудио дня, вместо него или не быть вовсе.
///
/// Тело приходит целиком с `/text/{code}/resolve` — в отличие от аудио, файла нет.
struct TextCard: View {
    let eid: Int
    let code: String
    let title: String?

    @EnvironmentObject private var language: LanguageStore
    @Environment(\.theme) private var t
    @State private var practiceBody: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        AccentCard(accent: t.sage) {
            HStack {
                LabelTag(text: L10n("today.text").text, color: t.sage)
                Spacer()
                if isLoading {
                    ProgressView().tint(t.terracotta)
                }
            }

            Text(title ?? code)
                .font(t.font.bodyEmphasized)
                .foregroundStyle(t.ink)

            if let practiceBody {
                ContentText(raw: practiceBody, accent: t.sage)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(t.font.caption)
                    .foregroundStyle(t.inkDim)
            }
        }
        .task {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let resolved = try await RidgeAPI.shared.resolveText(code: code, lang: language.current.rawValue)
            practiceBody = resolved.body
        } catch {
            errorMessage = L10n("error.notFound").text
        }
    }
}

#Preview {
    TextCard(eid: 1, code: "TEXT_BOUND_W1_T1", title: "Текстовая практика недели")
        .padding()
        .environmentObject(LanguageStore.shared)
        .environment(\.theme, .warm)
        .background(Theme.warm.paper)
}
