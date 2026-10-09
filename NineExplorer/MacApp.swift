// MacApp.swift — NineExplorer for macOS.
//
// macOS has no native iPhone look, so this file draws one: iOS grouped-list
// colors, rounded cards, large titles, an iOS search field and chevron rows.
// Shared model/service code lives in NineExplorer.swift.
//
// Runs as an .app bundle (make mac-app) or as a bare executable, which also
// accepts connection flags:
//   NineExplorer [--proto auto|9P2000|9P2000.L] [--uname u] [--uid n] [--aname a] [--msize n] [host:port]
//   (no host:port: show the connect screen; flags prefill it)

import SwiftUI
import AppKit

// MARK: - Command line

extension Config {
    static func usage() -> Never {
        fputs("""
        usage: NineExplorer [flags] [tcp://host:port | host:port]

        With no server argument, a connect screen is shown (flags prefill it).

        flags:
          --proto <p>     9P2000 | 9P2000.L | auto (default auto: try 9P2000, then 9P2000.L)
          --uname <name>  attach user name (default $USER; may be "")
          --uid <n>       numeric uid for 9P2000.L attach (default: none)
          --aname <path>  attach name / export (default "")
          --msize <n>     requested msize (default 65536)

        """, stderr)
        exit(2)
    }

    /// Parse flags. `hasFlags` is true if any connection flag was given.
    static func fromCommandLine() -> (config: Config, hasTarget: Bool, hasFlags: Bool) {
        var c = Config()
        var args = Array(CommandLine.arguments.dropFirst())
        var target: String?
        var hasFlags = false
        func value() -> String {
            args.removeFirst()
            guard let v = args.first else { usage() }
            return v
        }
        while let a = args.first {
            switch a {
            case "-h", "--help": usage()
            case "--proto":
                c.proto = value(); hasFlags = true
                guard ["auto", NineP.version, NineP.version9P2000L].contains(c.proto) else { usage() }
            case "--uname": c.uname = value(); hasFlags = true
            case "--uid": guard let n = UInt32(value()) else { usage() }; c.uid = n; hasFlags = true
            case "--aname": c.aname = value(); hasFlags = true
            case "--msize": guard let n = UInt32(value()) else { usage() }; c.msize = n; hasFlags = true
            default:
                if a.hasPrefix("-NS") || a.hasPrefix("-Apple") || a.hasPrefix("-psn_") {
                    // AppKit / Xcode / Finder launch arguments
                    if !a.hasPrefix("-psn_") { args.removeFirst() }
                } else if a.hasPrefix("-") {
                    usage()
                } else {
                    target = a
                }
            }
            if !args.isEmpty { args.removeFirst() }
        }
        guard let t = target else { return (c, false, hasFlags) }
        guard let (h, p) = parseHostPort(t) else { usage() }
        c.host = h; c.port = p
        return (c, true, hasFlags)
    }
}

// MARK: - Look & feel (iOS grouped style, drawn by hand)

extension Color {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static let groupedBackground = dynamic(light: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.969, alpha: 1),
                                           dark: .black)
    static let cardBackground = dynamic(light: .white,
                                        dark: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1))
    static let rowPressed = dynamic(light: NSColor(white: 0.85, alpha: 1), dark: NSColor(white: 0.23, alpha: 1))
    static let fieldBackground = dynamic(light: NSColor(srgbRed: 0.463, green: 0.463, blue: 0.502, alpha: 0.12),
                                         dark: NSColor(srgbRed: 0.463, green: 0.463, blue: 0.502, alpha: 0.24))
}

struct GroupedSection<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header.uppercased())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            VStack(spacing: 0) { content }
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.horizontal, 16)
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.rowPressed : Color.clear)
    }
}

struct InsetDivider: View {
    var leading: CGFloat = 16
    var body: some View { Divider().padding(.leading, leading) }
}

struct SearchField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.fieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Icon + title + subtitle + chevron, like an iOS navigation row.
struct ChevronRow<Icon: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

struct FieldRow: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var mono = false

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 96, alignment: .leading)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

// MARK: - Connect screen

struct ConnectView: View {
    @EnvironmentObject var model: AppModel
    @State private var form: ServerForm
    @State private var recents: [Config] = Recents.load()

    init(initial: Config, preferInitial: Bool) {
        // Flags from the command line win; otherwise start from the last server used.
        if preferInitial {
            _form = State(initialValue: ServerForm(initial))
        } else if let last = Recents.load().first {
            _form = State(initialValue: ServerForm(last))
        } else {
            _form = State(initialValue: ServerForm(initial, blankHost: true))
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    SymbolTile(symbol: "externaldrive.connected.to.line.below.fill", size: 76)
                    Text("Connect to Server").font(.system(size: 28, weight: .bold))
                    Text("Browse files on a 9P file server.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 28)

                GroupedSection(header: "Server", footer: form.problem) {
                    FieldRow(label: "Host", text: $form.host, placeholder: "hostname or IP")
                    InsetDivider()
                    FieldRow(label: "Port", text: $form.port, placeholder: "564")
                }

                GroupedSection(header: "Protocol", footer: form.protoFooter) {
                    Picker("Protocol", selection: $form.proto) {
                        ForEach(ServerForm.protocols, id: \.tag) { Text($0.label).tag($0.tag) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(12)
                }

                GroupedSection(header: "Account", footer: ServerForm.accountFooter) {
                    FieldRow(label: "User", text: $form.uname, placeholder: "none")
                    InsetDivider()
                    FieldRow(label: "UID", text: $form.uid, placeholder: "optional")
                    InsetDivider()
                    FieldRow(label: "Export", text: $form.aname, placeholder: "default", mono: true)
                }

                GroupedSection(header: "Advanced") {
                    FieldRow(label: "Max Message", text: $form.msize, placeholder: "65536")
                }

                Button(action: connect) {
                    Text("Connect")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(form.config == nil ? Color.gray.opacity(0.35) : Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(form.config == nil)
                .keyboardShortcut(.defaultAction)
                .padding(.horizontal, 16)

                if !recents.isEmpty {
                    GroupedSection(header: "Recent", footer: "Right-click a server to remove it.") {
                        ForEach(Array(recents.enumerated()), id: \.element.key) { i, r in
                            Button { Task { await model.connect(r) } } label: {
                                ChevronRow(title: r.endpoint, subtitle: r.recentSubtitle) {
                                    SymbolTile(symbol: "server.rack", color: .indigo)
                                }
                            }
                            .buttonStyle(RowButtonStyle())
                            .contextMenu {
                                Button("Fill In Form") { form = ServerForm(r) }
                                Button("Remove", role: .destructive) {
                                    Recents.remove(r)
                                    recents = Recents.load()
                                }
                            }
                            if i < recents.count - 1 { InsetDivider(leading: 58) }
                        }
                    }
                }
            }
            .padding(.bottom, 28)
        }
        .background(Color.groupedBackground)
        .onSubmit(connect)
    }

    func connect() {
        guard let c = form.config else { return }
        Task { await model.connect(c) }
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var model: AppModel
    let preferInitialConfig: Bool

    var body: some View {
        Group {
            switch model.status {
            case .setup:
                ConnectView(initial: model.cfg, preferInitial: preferInitialConfig)

            case .connecting:
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Connecting to \(model.cfg.endpoint)\u{2026}")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.groupedBackground)

            case .failed(let msg):
                VStack(spacing: 14) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("Can\u{2019}t Connect").font(.title2.bold())
                    Text("\(model.cfg.endpoint)\n\(msg)")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 32)
                    Button("Try Again") { Task { await model.connect() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button("Edit Server") { model.disconnect() }
                        .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.groupedBackground)

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
        .task {
            if case .connecting = model.status { await model.connect() }   // server given on the command line
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
    @State private var loading = false
    @State private var query = ""

    var filtered: [Entry] {
        let all = entries ?? []
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: 34, weight: .bold))
                        .lineLimit(1)
                    SearchField(text: $query)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                content
            }
            .padding(.bottom, 24)
        }
        .background(Color.groupedBackground)
        .navigationTitle(title)
        .toolbar {
            if path == "." {
                ToolbarItem(placement: .navigation) {
                    Button { model.disconnect() } label: {
                        Label("Servers", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Disconnect and choose another server")
                }
            }
            ToolbarItem {
                Button { Task { await load() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .disabled(loading)
            }
        }
        .task { if entries == nil { await load() } }
    }

    @ViewBuilder var content: some View {
        if let error {
            GroupedSection {
                VStack(spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Retry") { Task { await load() } }
                }
                .padding(16)
            }
        } else if entries == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        } else if filtered.isEmpty {
            Text(query.isEmpty ? "This folder is empty." : "No results for \u{201C}\(query)\u{201D}.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else {
            let items = filtered
            GroupedSection(footer: model.footer(count: items.count)) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                    Button { model.nav.append(e) } label: {
                        ChevronRow(title: e.name, subtitle: Fmt.subtitle(e)) { FileIcon(entry: e) }
                    }
                    .buttonStyle(RowButtonStyle())
                    if i < items.count - 1 { InsetDivider(leading: 58) }
                }
            }
        }
    }

    func load() async {
        loading = true
        defer { loading = false }
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
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    FileIcon(entry: entry, size: 72)
                    Text(entry.name)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("\(Fmt.kind(entry)) \u{00B7} \(Fmt.size(entry.size))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 16)
                .padding(.horizontal, 16)

                GroupedSection(header: "Information") {
                    let rows = Fmt.infoRows(entry)
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        InfoRow(label: r.0, value: r.1, mono: r.2)
                        if i < rows.count - 1 { InsetDivider() }
                    }
                }

                GroupedSection(header: "Preview", footer: truncated ? FilePreview.truncatedNote : nil) {
                    previewContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
            .padding(.bottom, 24)
        }
        .background(Color.groupedBackground)
        .navigationTitle(entry.name)
        .toolbar {
            ToolbarItem {
                Button {
                    if let s = preview?.text {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(s, forType: .string)
                    }
                } label: { Image(systemName: "doc.on.doc") }
                .help("Copy Text")
                .disabled(preview?.text == nil)
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
                Text(dump)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched as a bare executable (no .app bundle), become a regular
        // foreground app so the window gets focus and a Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct NineExplorerMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    private static let launch = Config.fromCommandLine()
    @StateObject private var model = AppModel(cfg: launch.config, autoConnect: launch.hasTarget)

    var body: some Scene {
        WindowGroup("9P Explorer") {
            RootView(preferInitialConfig: Self.launch.hasFlags || Self.launch.hasTarget)
                .environmentObject(model)
                .frame(minWidth: 340, idealWidth: 390, minHeight: 560, idealHeight: 844)
        }
        .defaultSize(width: 390, height: 844)
        .windowResizability(.contentMinSize)
    }
}
