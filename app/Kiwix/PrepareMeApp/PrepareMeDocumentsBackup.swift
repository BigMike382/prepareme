#if os(macOS)
import AppKit
import PrepareMeShared
import SwiftUI

/// Essential Documents' backups on the Mac (docs/documents.md, "Backups and restore"; plan 2026-10-24, phase 4): the
/// recovery password that makes the spare (owner, 2026-10-24: kept in the Passwords app), Use the Recovery Password…
/// on a new Mac, Test a Restore…, and Settings › Backups' lines. None of it needs the section open but the password's
/// making; nothing here writes a log.

/// Above the list while the store has no spare: the backups can't be opened anywhere else until it has one.
struct DocumentsSpareBanner: View {
    @State private var model = DocumentsModel.shared

    var body: some View {
        if model.state == .open, !model.hasSpare {
            VStack(alignment: .leading, spacing: 8) {
                Text(DocumentsWords.noSpare).foregroundStyle(PrepareMeColors.caution)
                    .fixedSize(horizontal: false, vertical: true)
                Button(DocumentsWords.makeSpare) { model.startSpare() }.pmAction(fullWidth: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(PrepareMeColors.accentBg, in: RoundedRectangle(cornerRadius: PrepareMeCorners.panel))
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }
}

/// Make a Recovery Password…: the password shown once, to save in Passwords, then pasted back before it's set.
struct DocumentsSpareSheet: View {
    let password: String
    let replacing: Bool
    @State private var model = DocumentsModel.shared
    @State private var checking = false
    @State private var copied = false
    @State private var pasted = ""
    @State private var wrong = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !checking {
                Text(DocumentsWords.spareTitle).font(.pmHeadline)
                Text(password)
                    .font(.system(size: 24, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(PrepareMeColors.panel, in: RoundedRectangle(cornerRadius: PrepareMeCorners.panel))
                    .overlay(RoundedRectangle(cornerRadius: PrepareMeCorners.panel).stroke(PrepareMeColors.line))
                Text(DocumentsWords.spareSteps).fixedSize(horizontal: false, vertical: true)
                if replacing {
                    Text(DocumentsWords.spareNewNote).foregroundStyle(PrepareMeColors.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if copied { Text(DocumentsWords.spareCopied).foregroundStyle(PrepareMeColors.text2) }
                HStack {
                    Button("Copy") {
                        model.copySpare()
                        copied = true
                    }
                    .pmAction(fullWidth: false)
                    Spacer()
                    Button("Cancel", role: .cancel) { model.spareDraft = nil }.keyboardShortcut(.cancelAction)
                    Button("Next") { checking = true }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text(DocumentsWords.spareCheckTitle).font(.pmHeadline)
                Text(DocumentsWords.spareCheckBody).fixedSize(horizontal: false, vertical: true)
                SecureField("Recovery password", text: $pasted)
                if wrong { Text(DocumentsWords.spareMismatch).foregroundStyle(PrepareMeColors.red) }
                HStack {
                    Button("Back") { checking = false }
                    Spacer()
                    Button("Cancel", role: .cancel) { model.spareDraft = nil }.keyboardShortcut(.cancelAction)
                    Button("Set Recovery Password") { wrong = !model.saveSpare(pasted: pasted) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(pasted.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onDisappear { pasted = "" }
    }
}

/// Use the Recovery Password…, from the locked screen: the spare opened with the pasted password.
struct DocumentsRecoverSheet: View {
    @State private var model = DocumentsModel.shared
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(DocumentsWords.recoverButton.dropLast()).font(.pmHeadline)
            Text(DocumentsWords.recoverBody).fixedSize(horizontal: false, vertical: true)
            SecureField("Recovery password", text: $password)
            if let message = model.message { Text(message).foregroundStyle(PrepareMeColors.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.recovering = false
                    model.message = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Open") { model.recover(password: password) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onDisappear { password = "" }
    }
}

/// Test a Restore…: the iCloud copy, or a folder the owner picks (the USB drive's), opened with the password alone.
struct DocumentsRestoreSheet: View {
    let done: () -> Void
    @State private var model = DocumentsModel.shared
    @State private var fromICloud = true
    @State private var folder: URL?
    @State private var password = ""
    @State private var running = false
    @State private var line: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(DocumentsWords.testRestore.dropLast()).font(.pmHeadline)
            Text(DocumentsWords.testRestoreBody).fixedSize(horizontal: false, vertical: true)
            Picker("Copy", selection: $fromICloud) {
                Text(DocumentsWords.fromICloud).tag(true)
                Text(DocumentsWords.fromFolder).tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if !fromICloud {
                HStack {
                    Button("Choose…") { choose() }.pmAction(fullWidth: false)
                    if let folder { Text(folder.path).foregroundStyle(PrepareMeColors.text2).lineLimit(1).truncationMode(.head) }
                }
            }
            SecureField("Recovery password", text: $password)
            if running { ProgressView().controlSize(.small) }
            if let line { Text(line).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.cancelAction)
                Button("Test") { test() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || password.isEmpty || (!fromICloud && folder == nil))
            }
        }
        .padding(20)
        .frame(width: 560)
        .onDisappear { password = "" }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Test This Copy"
        panel.message = DocumentsWords.fromFolder
        if panel.runModal() == .OK { folder = panel.url }
    }

    private func test() {
        guard let copy = fromICloud ? model.backupFolder : folder else { return }
        running = true
        line = nil
        Task {
            line = await model.testRestore(copy, iCloud: fromICloud, password: password)
            running = false
        }
    }
}

/// Settings › Backups' Essential Documents: the iCloud copy and the last Test a restore, then its button.
struct DocumentsBackupSection: View {
    @State private var model = DocumentsModel.shared
    @State private var testing = false

    var body: some View {
        Section(pmTitle: DocumentsWords.title) {
            ForEach(DocumentsWords.backupLines(model.backupStatus, test: model.restoreRecord, hasSpare: model.hasSpare),
                    id: \.text) { line in
                Text(line.text)
                    .font(.pmNote)
                    .foregroundStyle(line.caution ? PrepareMeColors.caution : PrepareMeColors.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(DocumentsWords.testRestore) { testing = true }.pmAction()
        }
        .onAppear { model.refreshBackup() }
        .sheet(isPresented: $testing) { DocumentsRestoreSheet { testing = false } }
    }
}

/// The documents screen's phase 4 sheets, beside its other dialogs.
struct DocumentsBackupDialogs: ViewModifier {
    @Bindable var model: DocumentsModel

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { model.spareDraft.map(Draft.init) }, set: { if $0 == nil { model.spareDraft = nil } })) {
                DocumentsSpareSheet(password: $0.password, replacing: model.hasSpare)
            }
            .sheet(isPresented: $model.recovering) { DocumentsRecoverSheet() }
            .sheet(isPresented: $model.testingRestore) { DocumentsRestoreSheet { model.testingRestore = false } }
    }

    struct Draft: Identifiable {
        let password: String
        var id: String { password }
    }
}
#endif
