import SwiftUI

/// Закрытие дня: статус задания → квиз → три вопроса рефлексии.
///
/// Последовательность приходит с бэкенда (`/day-steps`), а не строится здесь — это
/// тот же список шагов, что рендерит Telegram-бот. Проходим по нему один шаг за раз.
struct DayFlowView: View {
    @ObservedObject var vm: TodayViewModel
    let onFinish: () -> Void

    @Environment(\.theme) private var t
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var didSubmit = false

    /// Шаги вечерней сессии, кроме служебных.
    private var flowSteps: [DayStep] {
        vm.steps.filter { $0.kind == .focustask || $0.kind == .quiz || $0.kind == .freeText }
    }

    private var currentStep: DayStep? {
        flowSteps.indices.contains(index) ? flowSteps[index] : nil
    }

    private var isLast: Bool { index >= flowSteps.count - 1 }

    /// Ответ обязателен только на шаге статуса задания: рефлексия и квиз — по желанию
    /// (сохранение добровольно, §8 архитектуры).
    private var canAdvance: Bool {
        guard let step = currentStep else { return false }
        if step.kind == .focustask, step.asksStatus == true {
            return vm.taskStatus != nil
        }
        return true
    }

    var body: some View {
        NavigationStack {
            ZStack {
                t.paper.ignoresSafeArea()

                VStack(spacing: 0) {
                    ProgressDashes(total: max(flowSteps.count, 1), current: index + 1)
                        .padding(.horizontal, t.spacing.xl)
                        .padding(.top, t.spacing.m)

                    ScrollView {
                        VStack(alignment: .leading, spacing: t.spacing.xl) {
                            if let error = vm.error {
                                ErrorBanner(error: error)
                            }
                            if let step = currentStep {
                                stepContent(step)
                                    .id(index)
                            }
                        }
                        .padding(t.spacing.xl)
                    }

                    bottomBar
                }
            }
            .navigationTitle(Text("today.closeDay"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(didSubmit)
    }

    // MARK: - Шаг

    @ViewBuilder
    private func stepContent(_ step: DayStep) -> some View {
        switch step.kind {
        case .focustask:
            taskStatusStep(step)
        case .quiz:
            quizStep(step)
        case .freeText:
            reflectionStep(step)
        default:
            EmptyView()
        }
    }

    private func taskStatusStep(_ step: DayStep) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.l) {
            if let task = step.task {
                ContentCard(label: L10n("today.task").text,
                            title: nil,
                            text: task.text,
                            subtasks: task.subtasks,
                            accent: t.sage,
                            icon: "checkmark.square",
                            textStyle: .system)
            }

            Text("today.taskQuestion")
                .font(t.font.titleS)
                .foregroundStyle(t.ink)

            VStack(spacing: t.spacing.s) {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    ChoiceCard(text: L10n(status.titleKey).text,
                               icon: status.symbol,
                               isSelected: vm.taskStatus == status) {
                        vm.taskStatus = status
                    }
                }
            }
        }
    }

    private func quizStep(_ step: DayStep) -> some View {
        VStack(alignment: .leading, spacing: t.spacing.l) {
            LabelTag(text: L10n("today.quiz").text, color: t.dustyBlue)

            if let question = step.question {
                Text(question)
                    .font(t.font.titleS)
                    .foregroundStyle(t.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Варианты списком: их бывает 5, 6 и 7 — сегменты нечитаемы
            VStack(spacing: t.spacing.s) {
                ForEach(Array(step.options.enumerated()), id: \.offset) { _, option in
                    ChoiceCard(text: option, isSelected: vm.quizAnswer == option) {
                        vm.quizAnswer = option
                    }
                }
            }
        }
    }

    private func reflectionStep(_ step: DayStep) -> some View {
        // индекс среди свободных вопросов — по нему пишем ответ в нужную ячейку
        let reflectionIndex = flowSteps[0...index].filter { $0.kind == .freeText }.count - 1

        return VStack(alignment: .leading, spacing: t.spacing.l) {
            LabelTag(text: L10n("today.reflection").text, color: t.terracotta)

            if let prompt = step.prompt {
                Text(prompt)
                    .font(t.font.titleS)
                    .foregroundStyle(t.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if vm.reflections.indices.contains(reflectionIndex) {
                VoiceTextEditor(
                    text: Binding(
                        // при закрытии дня vm.reflections обнуляется раньше, чем этот
                        // View успевает исчезнуть — get/set могут получить вызов уже
                        // после сброса массива, поэтому проверяем границы и здесь, а
                        // не только в условии выше (это защищало только создание View).
                        get: { vm.reflections.indices.contains(reflectionIndex) ? vm.reflections[reflectionIndex] : "" },
                        set: { newValue in
                            guard vm.reflections.indices.contains(reflectionIndex) else { return }
                            vm.reflections[reflectionIndex] = newValue
                        }
                    ),
                    placeholder: "today.reflectionPlaceholder")
            }
        }
    }

    // MARK: - Нижняя панель

    private var bottomBar: some View {
        HStack(spacing: t.spacing.m) {
            if index > 0 {
                GhostButton(title: "common.back", icon: "chevron.left") {
                    index -= 1
                }
                .frame(maxWidth: 140)
            }
            AccentButton(title: isLast ? "today.closeDay" : "common.next",
                         isLoading: vm.isSubmitting,
                         isDisabled: !canAdvance || didSubmit) {
                advance()
            }
        }
        .padding(.horizontal, t.spacing.xl)
        .padding(.vertical, t.spacing.l)
        .background(t.paper)
        .overlay(alignment: .top) { Divider().foregroundStyle(t.border) }
    }

    private func advance() {
        guard !didSubmit else { return }           // защита от двойного тапа
        if isLast {
            didSubmit = true
            Task {
                let ok = await vm.closeDay()
                if ok {
                    onFinish()
                    dismiss()
                } else {
                    didSubmit = false              // дать повторить после ошибки
                }
            }
        } else {
            index += 1
        }
    }
}

// MARK: - Поле с голосовым вводом

/// Текстовое поле с диктовкой. Локаль распознавания следует выбранному языку —
/// не прибита к `ru_RU`.
struct VoiceTextEditor: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey

    @EnvironmentObject private var language: LanguageStore
    @Environment(\.theme) private var t
    @StateObject private var recorder = SpeechRecorder()

    var body: some View {
        VStack(alignment: .leading, spacing: t.spacing.s) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(t.font.body)
                        .foregroundStyle(t.inkDim)
                        .padding(.horizontal, t.spacing.m)
                        .padding(.vertical, t.spacing.m + 2)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(t.font.body)
                    .foregroundStyle(t.ink)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(t.spacing.s)
            }
            .background(t.surface)
            .clipShape(RoundedRectangle(cornerRadius: t.corners.input))
            .overlay(
                RoundedRectangle(cornerRadius: t.corners.input)
                    .strokeBorder(t.border, lineWidth: 0.5)
            )

            HStack {
                Button {
                    if recorder.isRecording {
                        recorder.stop()
                    } else {
                        recorder.start(locale: language.current.locale, existing: text)
                    }
                } label: {
                    Label(recorder.isRecording ? "today.voiceStop" : "today.voiceInput",
                          systemImage: recorder.isRecording ? "stop.circle" : "mic")
                        .font(t.font.caption)
                        .foregroundStyle(recorder.isRecording ? t.safety : t.terracotta)
                }
                .accessibilityLabel(Text(recorder.isRecording ? "today.voiceStop" : "today.voiceInput"))

                Spacer()

                if let message = recorder.errorMessage {
                    Text(message)
                        .font(t.font.caption)
                        .foregroundStyle(t.inkDim)
                }
            }
        }
        .onChange(of: recorder.transcript) { _, new in
            if recorder.isRecording, !new.isEmpty { text = new }
        }
        .onDisappear { recorder.stop() }
    }
}

#Preview {
    DayFlowView(vm: TodayViewModel()) {}
        .environmentObject(LanguageStore.shared)
        .environment(\.theme, .warm)
}
