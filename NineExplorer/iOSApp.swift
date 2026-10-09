// iOSApp.swift — NineExplorer for iOS.
//
// The same app as MacApp.swift, but built from native iOS components:
// Form, List(.insetGrouped), NavigationLink chevrons, large navigation titles,
// .searchable, pull-to-refresh, swipe actions, ContentUnavailableView,
// LabeledContent, ShareLink and UIPasteboard.
// Shared model/service code lives in NineExplorer.swift.
//
// It is also the watch's 9P gateway: WatchBridge answers WatchConnectivity
// requests from WatchApp.swift using this app's AppModel/NineService.

import SwiftUI
import UIKit
import Combine
import WatchConnectivity

// MARK: - Connect screen

func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// A form row: label on the left, right-aligned text field (like Settings).
struct FieldRow: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var keyboard: UIKeyboardType = .default
    var mono = false

    var body: some View {
        LabeledContent(label) {
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .font(mono ? .body.monospaced() : .body)
        }
    }
}

struct ConnectView: View {
    @EnvironmentObject var model: AppModel
    @State private var form: ServerForm
    @State private var recents: [Config] = Recents.load()

    init() {
        if let last = Recents.load().first {
            _form = State(initialValue: ServerForm(last))
        } else {
            _form = State(initialValue: ServerForm())
        }
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    SymbolTile(symbol: "externaldrive.connected.to.line.below.fill", size: 76)
                    Text("Browse files on a 9P file server.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                FieldRow(label: "Host", text: $form.host, placeholder: "hostname or IP", keyboard: .URL)
                FieldRow(label: "Port", text: $form.port, placeholder: "564", keyboard: .numberPad)
            } header: {
                Text("Server")
            } footer: {
                if let p = form.problem { Text(p).foregroundStyle(.red) }
            }

            Section {
                Picker("Protocol", selection: $form.proto) {
                    ForEach(ServerForm.protocols, id: \.tag) { Text($0.label).tag($0.tag) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } header: {
                Text("Protocol")
            } footer: {
                Text(form.protoFooter)
            }

            Section {
                FieldRow(label: "User", text: $form.uname, placeholder: "none")
                FieldRow(label: "UID", text: $form.uid, placeholder: "optional", keyboard: .numberPad)
                FieldRow(label: "Export", text: $form.aname, placeholder: "default", mono: true)
            } header: {
                Text("Account")
            } footer: {
                Text(ServerForm.accountFooter)
            }

            Section("Advanced") {
                FieldRow(label: "Max Message", text: $form.msize, placeholder: "65536", keyboard: .numberPad)
            }

            Section {
                Button(action: connect) {
                    Text("Connect")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .disabled(form.config == nil)
            }

            if !recents.isEmpty {
                Section {
                    ForEach(recents, id: \.key) { r in
                        Button { Task { await model.connect(r) } } label: {
                            HStack(spacing: 12) {
                                SymbolTile(symbol: "server.rack", color: .indigo)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.endpoint).foregroundStyle(.primary)
                                    Text(r.recentSubtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Edit") { form = ServerForm(r) }.tint(.blue)
                        }
                    }
                    .onDelete { idx in
                        idx.map { recents[$0] }.forEach(Recents.remove)
                        recents = Recents.load()
                    }
                } header: {
                    Text("Recent")
                } footer: {
                    Text("Swipe left to remove, right to edit.")
                }
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .scrollDismissesKeyboard(.interactively)
        .onSubmit(connect)
        .navigationTitle("Connect to Server")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done", action: dismissKeyboard)
            }
        }
    }

    func connect() {
        guard let c = form.config else { return }
        dismissKeyboard()
        Task { await model.connect(c) }
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.status {
        case .setup:
            NavigationStack { ConnectView() }

        case .connecting:
            NavigationStack {
                ProgressView("Connecting to \(model.cfg.endpoint)\u{2026}")
                    .navigationTitle("Connecting")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { model.disconnect() }
                        }
                    }
            }

        case .failed(let msg):
            NavigationStack {
                ContentUnavailableView {
                    Label("Can\u{2019}t Connect", systemImage: "network.slash")
                } description: {
                    Text("\(model.cfg.endpoint)\n\(msg)")
                } actions: {
                    Button("Try Again") { Task { await model.connect() } }
                        .buttonStyle(.borderedProminent)
                    Button("Edit Server") { model.disconnect() }
                }
            }

        case .connected:
            NavigationStack(path: $model.nav) {
                DirectoryView(path: ".", title: model.rootTitle)
                    .navigationDestination(for: Entry.self) { e in
                        if e.isDir {
                            DirectoryView(path: e.path, title: e.name)
                        } else {
                            FileView(entry: e)
                        }
                    }
            }
        }
    }
}

// MARK: - Directory

struct DirectoryView: View {
    @EnvironmentObject var model: AppModel
    let path: String
    let title: String

    @State private var entries: [Entry]?
    @State private var error: String?
    @State private var query = ""

    var filtered: [Entry] {
        let all = entries ?? []
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if let entries, !entries.isEmpty, !filtered.isEmpty {
                Section {
                    ForEach(filtered) { e in
                        NavigationLink(value: e) {
                            HStack(spacing: 12) {
                                FileIcon(entry: e)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(Fmt.subtitle(e))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                } footer: {
                    Text(model.footer(count: filtered.count))
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { overlay }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(path == "." ? .large : .inline)
        .searchable(text: $query, prompt: "Search")
        .refreshable { await load() }
        .toolbar {
            if path == "." {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.disconnect() } label: {
                        Label("Servers", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
        .task { if entries == nil { await load() } }
    }

    @ViewBuilder var overlay: some View {
        if let error {
            ContentUnavailableView {
                Label("Couldn\u{2019}t Load Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { Task { await load() } }
            }
        } else if entries == nil {
            ProgressView()
        } else if entries?.isEmpty == true {
            ContentUnavailableView("Empty Folder", systemImage: "folder",
                                   description: Text("This folder has no items."))
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    func load() async {
        do {
            entries = try await model.list(path)
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }
}

// MARK: - File

struct FileView: View {
    @EnvironmentObject var model: AppModel
    let entry: Entry

    @State private var preview: FilePreview?
    @State private var truncated = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    FileIcon(entry: entry, size: 72)
                    Text(entry.name)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("\(Fmt.kind(entry)) \u{00B7} \(Fmt.size(entry.size))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section("Information") {
                ForEach(Array(Fmt.infoRows(entry).enumerated()), id: \.offset) { _, r in
                    LabeledContent(r.0) {
                        Text(r.1)
                            .font(r.2 ? .body.monospaced() : .body)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                previewContent
            } header: {
                Text("Preview")
            } footer: {
                if truncated { Text(FilePreview.truncatedNote) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let s = preview?.text {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { UIPasteboard.general.string = s } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    ShareLink(item: s, subject: Text(entry.name))
                }
            }
        }
        .task { if preview == nil && error == nil { await load() } }
    }

    @ViewBuilder var previewContent: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else {
            switch preview {
            case nil:
                ProgressView().frame(maxWidth: .infinity)
            case .empty:
                Text("Empty file").foregroundStyle(.secondary)
            case .text(let s):
                Text(s)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            case .binary(let dump):
                ScrollView(.horizontal) {
                    Text(dump)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    func load() async {
        do {
            (preview, truncated) = try await model.preview(entry.path)
        } catch {
            self.error = "\(error)"
        }
    }
}

// MARK: - Watch bridge

/// Serves the watch app: answers its requests with 9P results from AppModel
/// and pushes the current server and recents as the application context.
@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    private let model: AppModel
    private var watchers: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        super.init()
        guard WCSession.isSupported() else { return }   // e.g. iPad
        let s = WCSession.default
        s.delegate = self
        s.activate()
        // Push state whenever the connection status changes (after the change lands).
        model.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pushContext() }
            .store(in: &watchers)
    }

    func pushContext() {
        let s = WCSession.default
        guard WCSession.isSupported(), s.activationState == .activated,
              s.isPaired, s.isWatchAppInstalled else { return }
        try? s.updateApplicationContext(model.watchContext.dict)
    }

    /// Handle one watch request (on the main actor, where AppModel lives).
    func handle(_ req: WatchProto.Request) async -> WatchProto.Reply {
        // Keep running briefly if the watch woke us in the background.
        let bg = UIApplication.shared.beginBackgroundTask(withName: "watch-request")
        defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }

        switch req.op {
        case .state:
            var r = WatchProto.Reply()
            r.title = model.rootTitle
            return r

        case .disconnect:
            model.disconnect()
            return WatchProto.Reply()

        case .connect, .list, .preview:
            // Make sure the phone is on the server the watch is browsing.
            if let server = req.server, !model.isConnected(to: server) {
                await model.connect(server)
            } else if req.server == nil, case .connected = model.status {
                // already connected; browse the current server
            } else if req.server == nil {
                await model.connect()
            }
            if case .failed(let e) = model.status { return WatchProto.Reply(error: e) }
            guard case .connected = model.status else { return WatchProto.Reply(error: "Not connected") }

            do {
                switch req.op {
                case .list:
                    let all = try await model.list(req.path)
                    var r = WatchProto.Reply()
                    r.entries = all.map(\.forWatch)
                    r.total = all.count
                    return r
                case .preview:
                    let (p, more) = try await model.preview(req.path, limit: WatchProto.previewLimit)
                    var r = WatchProto.Reply()
                    switch p {
                    case .text(let t): r.text = t
                    case .binary: r.binary = true
                    case .empty: r.text = ""
                    }
                    r.truncated = more
                    return r
                default:
                    var r = WatchProto.Reply()
                    r.title = model.rootTitle
                    return r
                }
            } catch {
                return WatchProto.Reply(error: "\(error)")
            }
        }
    }

    // MARK: WCSessionDelegate (called off the main thread)

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard let req = WatchProto.Request(message) else {
            replyHandler(WatchProto.Reply(error: "Bad request").dict)
            return
        }
        Task { @MainActor in
            replyHandler(await self.handle(req).dict)
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.pushContext() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.pushContext() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()   // switching between paired watches
    }
}

// MARK: - App

/// Owns the model and the watch bridge from launch, so a background wake-up
/// by the watch (before any UI exists) can be served.
@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, ObservableObject {
    let model = AppModel(cfg: Recents.load().first ?? Config(), autoConnect: false)
    private var bridge: WatchBridge?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        bridge = WatchBridge(model: model)
        return true
    }
}

@main
struct NineExplorerIOSApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(delegate.model)
        }
    }
}
