import AnokhaCore
import AppKit
import SwiftUI

private enum LogViewMode: String, CaseIterable, Identifiable {
    case output
    case errors
    case both

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct JobLogsView: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: JobSnapshot
    let service: JobService

    @State private var mode: LogViewMode = .output
    @State private var output = JobLogContent(text: "", modifiedAt: nil, byteCount: 0)
    @State private var errors = JobLogContent(text: "", modifiedAt: nil, byteCount: 0)
    @State private var searchText = ""
    @State private var follow = true
    @State private var confirmClear = false
    @State private var clearError: String?

    private var job: JobDefinition { snapshot.record.definition }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Logs — \(job.name)")
                        .font(.title2.bold())
                    Text(metadataSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            HStack {
                Picker("Stream", selection: $mode) {
                    ForEach(LogViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .accessibilityIdentifier("log-stream")

                TextField("Search logs", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("log-search")

                Toggle("Follow", isOn: $follow)
                    .toggleStyle(.switch)

                Button {
                    copyVisible()
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                }

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([service.paths.logDirectory(for: job.id)])
                } label: {
                    Label("Reveal", systemImage: "folder")
                }

                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .accessibilityIdentifier("clear-logs")
            }
            .padding(12)

            Divider()

            switch mode {
            case .output:
                LogPane(title: "Standard Output", text: filtered(output.text), follow: follow)
            case .errors:
                LogPane(title: "Standard Error", text: filtered(errors.text), follow: follow)
            case .both:
                VSplitView {
                    LogPane(title: "Standard Output", text: filtered(output.text), follow: follow)
                    LogPane(title: "Standard Error", text: filtered(errors.text), follow: follow)
                }
                .overlay(alignment: .topTrailing) {
                    Text("Streams are separate; ordering is not fabricated.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .confirmationDialog("Clear captured logs?", isPresented: $confirmClear) {
            Button("Clear Logs", role: .destructive) { clearLogs() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This truncates the selected job’s app-owned output and error files. The job keeps running.")
        }
        .alert("Could Not Clear Logs", isPresented: Binding(
            get: { clearError != nil },
            set: { if !$0 { clearError = nil } }
        )) {
            Button("OK", role: .cancel) { clearError = nil }
        } message: {
            Text(clearError ?? "Unknown error")
        }
    }

    private var metadataSummary: String {
        let modified = [output.modifiedAt, errors.modifiedAt].compactMap { $0 }.max()
        let size = output.byteCount + errors.byteCount
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        if let modified {
            return "\(sizeText) on disk · files last changed \(modified.formatted(date: .abbreviated, time: .standard))"
        }
        return "No captured output yet"
    }

    private func refresh() async {
        let service = self.service
        let job = self.job
        let contents = await Task.detached(priority: .utility) {
            (
                service.logService.read(job: job, stream: .standardOutput, maxBytes: 512 * 1_024),
                service.logService.read(job: job, stream: .standardError, maxBytes: 512 * 1_024)
            )
        }.value
        let nextOutput = bounded(contents.0)
        let nextErrors = bounded(contents.1)
        if output != nextOutput { output = nextOutput }
        if errors != nextErrors { errors = nextErrors }
    }

    private func bounded(_ content: JobLogContent) -> JobLogContent {
        let maxCharacters = 512 * 1_024
        guard content.text.count > maxCharacters else { return content }
        let suffix = content.text.suffix(maxCharacters)
        return JobLogContent(
            text: "[Earlier in-memory content omitted; the full bounded files remain on disk.]\n" + suffix,
            modifiedAt: content.modifiedAt,
            byteCount: content.byteCount
        )
    }

    private func filtered(_ text: String) -> String {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(query) }
            .joined(separator: "\n")
    }

    private func copyVisible() {
        let text: String
        switch mode {
        case .output: text = filtered(output.text)
        case .errors: text = filtered(errors.text)
        case .both:
            text = "=== Standard Output ===\n\(filtered(output.text))\n\n=== Standard Error ===\n\(filtered(errors.text))"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func clearLogs() {
        let service = self.service
        let job = self.job
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try service.logService.clear(job: job)
                }.value
                await refresh()
            } catch {
                clearError = error.localizedDescription
            }
        }
    }
}

private struct LogPane: View {
    let title: String
    let text: String
    let follow: Bool
    private let bottomID = "log-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    Text(text.isEmpty ? "No output captured." : text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(10)
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .onChange(of: text) {
                    if follow { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onAppear {
                    if follow { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
            }
        }
    }
}
