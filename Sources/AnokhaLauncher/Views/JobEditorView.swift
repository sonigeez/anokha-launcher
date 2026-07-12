import AnokhaCore
import AppKit
import SwiftUI

private struct ArgumentDraft: Identifiable {
    let id: UUID
    var value: String

    init(id: UUID = UUID(), value: String) {
        self.id = id
        self.value = value
    }
}

struct JobEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let presentation: EditorPresentation
    let onCancel: () -> Void
    let onSave: (JobDefinition, Bool) -> Void

    @State private var draft: JobDefinition
    @State private var commandKind: JobCommandKind
    @State private var shellCommand: String
    @State private var filePath: String
    @State private var arguments: [ArgumentDraft]

    init(
        presentation: EditorPresentation,
        onCancel: @escaping () -> Void,
        onSave: @escaping (JobDefinition, Bool) -> Void
    ) {
        self.presentation = presentation
        self.onCancel = onCancel
        self.onSave = onSave
        _draft = State(initialValue: presentation.definition)
        _commandKind = State(initialValue: presentation.definition.command.kind)
        switch presentation.definition.command {
        case .shell(let command):
            _shellCommand = State(initialValue: command)
            _filePath = State(initialValue: "")
            _arguments = State(initialValue: [])
        case .file(let path, let values):
            _shellCommand = State(initialValue: "")
            _filePath = State(initialValue: path)
            _arguments = State(initialValue: values.map { ArgumentDraft(value: $0) })
        }
    }

    private var normalizedDraft: JobDefinition {
        var value = draft
        switch commandKind {
        case .shell:
            value.command = .shell(command: shellCommand)
        case .file:
            value.command = .file(path: filePath, arguments: arguments.map(\.value))
        }
        return value
    }

    private var report: ValidationReport { normalizedDraft.validate() }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.expectedRevision == nil ? "New Job" : "Edit Job")
                        .font(.title2.bold())
                    Text("Nothing runs until you explicitly enable it.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                whatToRunSection
                whenToRunSection
                failureSection
                environmentSection
                logsSection
                reviewSection
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save Disabled") {
                    onSave(normalizedDraft, false)
                }
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("save-disabled")

                Button("Save & Enable") {
                    onSave(normalizedDraft, true)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!report.isValid)
                .accessibilityIdentifier("save-and-enable")
            }
            .padding(16)
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 620, idealHeight: 760)
        .interactiveDismissDisabled()
    }

    private var whatToRunSection: some View {
        Section("What to run") {
            TextField("Name", text: $draft.name)
                .accessibilityIdentifier("job-name")

            Picker("Type", selection: $commandKind) {
                ForEach(JobCommandKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("command-kind")

            if commandKind == .shell {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Command")
                    TextEditor(text: $shellCommand)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                        .accessibilityLabel("Shell command")
                        .accessibilityIdentifier("shell-command")
                    Text("Runs explicitly through /bin/zsh -lc. Shell syntax and your zsh login startup files apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    TextField("Executable or script", text: $filePath)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("file-path")
                    Button("Choose…") {
                        if let path = FilePanels.chooseExecutable() { filePath = path }
                    }
                    .accessibilityIdentifier("choose-file")
                    Button {
                        if !filePath.isEmpty {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal selected file in Finder")
                    .disabled(filePath.isEmpty)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Arguments").font(.headline)
                        Spacer()
                        Button {
                            arguments.append(ArgumentDraft(value: ""))
                        } label: {
                            Label("Add Argument", systemImage: "plus")
                        }
                        .accessibilityIdentifier("add-argument")
                    }

                    ForEach(Array(arguments.enumerated()), id: \.element.id) { index, argument in
                        HStack {
                            Text("\(index + 1)")
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .trailing)
                            TextField("Argument", text: argumentBinding(argument.id))
                                .font(.system(.body, design: .monospaced))
                                .accessibilityLabel("Argument \(index + 1)")
                            Button { moveArgument(argument.id, offset: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0)
                                .accessibilityLabel("Move argument \(index + 1) up")
                            Button { moveArgument(argument.id, offset: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(index == arguments.count - 1)
                                .accessibilityLabel("Move argument \(index + 1) down")
                            Button(role: .destructive) {
                                arguments.removeAll { $0.id == argument.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .accessibilityLabel("Remove argument \(index + 1)")
                        }
                    }
                }
            }

            HStack {
                TextField("Working directory (optional)", text: Binding(
                    get: { draft.workingDirectory ?? "" },
                    set: { draft.workingDirectory = $0.isEmpty ? nil : $0 }
                ))
                .font(.system(.body, design: .monospaced))
                .accessibilityIdentifier("working-directory")
                Button("Choose…") {
                    if let path = FilePanels.chooseDirectory() { draft.workingDirectory = path }
                }
                Button {
                    draft.workingDirectory = nil
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("Use home folder")
                .accessibilityLabel("Use home folder as working directory")
                .disabled(draft.workingDirectory == nil)
            }
            Text("If omitted, the job uses your home folder. Relative paths are resolved from there.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var whenToRunSection: some View {
        Section("When to run") {
            Picker("Start", selection: activationKindBinding) {
                ForEach(JobActivationKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .accessibilityIdentifier("activation-kind")

            if case .scheduled = draft.activation {
                ScheduleEditor(schedule: scheduleBinding)
                Text(scheduleDisclaimer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if draft.activation.kind == .atLogin {
                Text("Enabling runs the job now, and it becomes eligible again after you log in. It never runs before login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if draft.activation.kind == .manual {
                Text("The job stays dormant until you choose Run Now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var failureSection: some View {
        Section("Failure behavior") {
            if draft.activation.kind == .keepRunning {
                LabeledContent("After exit", value: "Always keep running")
                Text("The app-owned runner restarts the command after successful or unsuccessful exits. launchd also revives the runner if it stops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if draft.activation.kind == .manual {
                LabeledContent("After exit", value: "Remain stopped")
            } else {
                Picker("After exit", selection: $draft.restartPolicy) {
                    Text(RestartPolicy.never.title).tag(RestartPolicy.never)
                    Text(RestartPolicy.onFailure.title).tag(RestartPolicy.onFailure)
                }
                .accessibilityIdentifier("restart-policy")
            }

            if draft.restartPolicy != .never {
                Stepper(value: $draft.restartDelaySeconds, in: 10...3_600, step: 5) {
                    LabeledContent("Minimum restart delay", value: "\(draft.restartDelaySeconds) seconds")
                }
                Text("macOS may throttle a frantic failure loop for longer. Ten seconds is the minimum, not a loophole invitation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var environmentSection: some View {
        Section("Environment") {
            LabeledContent("Default PATH", value: JobDefinition.defaultPath)
                .font(.system(.callout, design: .monospaced))

            ForEach($draft.environment) { $variable in
                HStack {
                    TextField("Name", text: $variable.key)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 140)
                        .accessibilityLabel("Environment variable name")
                    Text("=").foregroundStyle(.secondary)
                    TextField("Plaintext value", text: $variable.value)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Environment variable value for \(variable.key)")
                    Button(role: .destructive) {
                        draft.environment.removeAll { $0.id == variable.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .accessibilityLabel("Remove environment variable \(variable.key)")
                }
            }

            Button {
                draft.environment.append(EnvironmentVariable(key: "", value: ""))
            } label: {
                Label("Add Variable", systemImage: "plus")
            }
            .accessibilityIdentifier("add-environment-variable")

            if !draft.environment.isEmpty {
                Label("Values are stored locally in plaintext. Do not use passwords, API tokens, or other secrets.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var logsSection: some View {
        Section("Logs") {
            LabeledContent("Standard output", value: "Captured")
            LabeledContent("Standard error", value: "Captured separately")
            LabeledContent("Maximum retained size", value: ByteCountFormatter.string(fromByteCount: Int64(draft.logPolicy.maximumTotalBytes), countStyle: .file))
            Text("The background runner keeps one 5 MB current file and one 5 MB backup per stream. Rotation works even while this app is closed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var reviewSection: some View {
        Section("Review") {
            LabeledContent("Behavior", value: normalizedDraft.policySummary)
            LabeledContent("Working directory", value: normalizedDraft.workingDirectory ?? "Home folder")
            LabeledContent("Environment", value: normalizedDraft.environment.isEmpty ? "Default PATH only" : "\(normalizedDraft.environment.count) custom value(s)")

            VStack(alignment: .leading, spacing: 6) {
                Text("Exact execution").font(.headline)
                if commandKind == .file {
                    Text(filePath.isEmpty ? "No file selected" : filePath)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    ForEach(Array(arguments.enumerated()), id: \.element.id) { index, argument in
                        LabeledContent("Argument \(index + 1)", value: argument.value)
                            .font(.system(.callout, design: .monospaced))
                    }
                } else {
                    Text(normalizedDraft.executionSummary)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            ForEach(report.errors) { issue in
                Label(issue.message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error: \(issue.message)")
            }
            ForEach(report.warnings) { issue in
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Warning: \(issue.message)")
            }
        }
    }

    private var activationKindBinding: Binding<JobActivationKind> {
        Binding(
            get: { draft.activation.kind },
            set: { kind in
                switch kind {
                case .atLogin:
                    draft.activation = .atLogin
                    if draft.restartPolicy == .always { draft.restartPolicy = .never }
                case .scheduled:
                    if case .scheduled = draft.activation {} else {
                        draft.activation = .scheduled(.daily(hour: 9, minute: 0))
                    }
                    if draft.restartPolicy == .always { draft.restartPolicy = .never }
                case .keepRunning:
                    draft.activation = .keepRunning
                    draft.restartPolicy = .always
                case .manual:
                    draft.activation = .manual
                    draft.restartPolicy = .never
                }
            }
        )
    }

    private var scheduleBinding: Binding<JobSchedule> {
        Binding(
            get: {
                guard case .scheduled(let schedule) = draft.activation else {
                    return .daily(hour: 9, minute: 0)
                }
                return schedule
            },
            set: { draft.activation = .scheduled($0) }
        )
    }

    private var scheduleDisclaimer: String {
        guard case .scheduled(let schedule) = draft.activation else { return "" }
        if case .interval = schedule {
            return "Uses the Mac’s local time. Interval firings are missed while the Mac sleeps or while the job is already running."
        }
        return "Uses the Mac’s local time. Calendar firings missed during sleep may be coalesced into one run after wake; replay is not guaranteed."
    }

    private func argumentBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { arguments.first(where: { $0.id == id })?.value ?? "" },
            set: { value in
                if let index = arguments.firstIndex(where: { $0.id == id }) {
                    arguments[index].value = value
                }
            }
        )
    }

    private func moveArgument(_ id: UUID, offset: Int) {
        guard let source = arguments.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard arguments.indices.contains(destination) else { return }
        arguments.swapAt(source, destination)
    }
}

private struct ScheduleEditor: View {
    @Binding var schedule: JobSchedule

    var body: some View {
        Picker("Schedule", selection: kindBinding) {
            ForEach(JobScheduleKind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }

        switch schedule {
        case .hourly(let minute):
            Stepper(value: intBinding(minute) { .hourly(minute: $0) }, in: 0...59) {
                LabeledContent("Minute", value: String(format: ":%02d", minute))
            }
        case .daily(let hour, let minute):
            TimeComponentEditor(hour: hour, minute: minute) { schedule = .daily(hour: $0, minute: $1) }
        case .weekdays(let days, let hour, let minute):
            HStack {
                ForEach(LaunchdWeekday.allCases) { day in
                    Toggle(day.shortName, isOn: Binding(
                        get: { days.contains(day) },
                        set: { selected in
                            var updated = days
                            if selected {
                                updated.insert(day)
                            } else {
                                updated.remove(day)
                            }
                            schedule = .weekdays(days: updated, hour: hour, minute: minute)
                        }
                    ))
                    .toggleStyle(.button)
                    .accessibilityLabel(day.shortName)
                }
            }
            TimeComponentEditor(hour: hour, minute: minute) { schedule = .weekdays(days: days, hour: $0, minute: $1) }
        case .monthly(let day, let hour, let minute):
            Stepper(value: intBinding(day) { .monthly(day: $0, hour: hour, minute: minute) }, in: 1...31) {
                LabeledContent("Day of month", value: "\(day)")
            }
            TimeComponentEditor(hour: hour, minute: minute) { schedule = .monthly(day: day, hour: $0, minute: $1) }
            if day > 28 {
                Text("Months without day \(day) are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .interval(let hours, let minutes):
            Stepper(value: intBinding(hours) { .interval(hours: $0, minutes: minutes) }, in: 0...168) {
                LabeledContent("Hours", value: "\(hours)")
            }
            Stepper(value: intBinding(minutes) { .interval(hours: hours, minutes: $0) }, in: 0...59) {
                LabeledContent("Minutes", value: "\(minutes)")
            }
        }
    }

    private var kindBinding: Binding<JobScheduleKind> {
        Binding(
            get: { schedule.kind },
            set: { kind in
                switch kind {
                case .hourly: schedule = .hourly(minute: 0)
                case .daily: schedule = .daily(hour: 9, minute: 0)
                case .weekdays: schedule = .weekdays(days: [.monday, .tuesday, .wednesday, .thursday, .friday], hour: 9, minute: 0)
                case .monthly: schedule = .monthly(day: 1, hour: 9, minute: 0)
                case .interval: schedule = .interval(hours: 1, minutes: 0)
                }
            }
        )
    }

    private func intBinding(_ value: Int, transform: @escaping (Int) -> JobSchedule) -> Binding<Int> {
        Binding(get: { value }, set: { schedule = transform($0) })
    }
}

private struct TimeComponentEditor: View {
    let hour: Int
    let minute: Int
    let update: (Int, Int) -> Void

    var body: some View {
        Stepper(value: Binding(get: { hour }, set: { update($0, minute) }), in: 0...23) {
            LabeledContent("Hour", value: String(format: "%02d", hour))
        }
        Stepper(value: Binding(get: { minute }, set: { update(hour, $0) }), in: 0...59) {
            LabeledContent("Minute", value: String(format: "%02d", minute))
        }
    }
}
