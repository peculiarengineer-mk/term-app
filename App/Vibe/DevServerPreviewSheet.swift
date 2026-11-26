import SwiftUI
import SSHKit
import Store
import TermUI

/// Sheet detecting listening ports on the remote host, auto-forwarding via `-L`, and previewing in-app.
struct DevServerPreviewSheet: View {
    private struct PreviewTarget: Identifiable {
        let id = UUID()
        let url: URL
    }

    let live: LiveSession

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearanceSettings.themeKey) private var themeName = AppearanceSettings.defaultThemeName

    @State private var ports: [ListeningPort] = []
    @State private var activeForwards: [ActivePortForward] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var forwardingPort: UInt16?
    @State private var customPortText = ""
    @State private var previewTarget: PreviewTarget?
    @State private var loadGeneration = 0
    @State private var didInitialLoad = false
    @State private var ownedForwardIDs: Set<UUID> = []
    @State private var previewTask: Task<Void, Never>?
    @FocusState private var isCustomPortFocused: Bool

    private var theme: TerminalTheme { TerminalTheme.preset(named: themeName) }
    private var palette: ProDesign.Palette { ProDesign.Palette(theme: theme) }
    private var sshConnection: SSHConnection? { live.session as? SSHConnection }
    private var devServerPorts: [ListeningPort] { ports.filter(\.isLikelyDevServer) }
    private var otherPorts: [ListeningPort] { ports.filter { !$0.isLikelyDevServer } }

    private var parsedCustomPort: UInt16? {
        let trimmed = customPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(trimmed), port > 0 else { return nil }
        return port
    }

    var body: some View {
        NavigationStack {
            List {
                if !devServerPorts.isEmpty {
                    Section("Dev Servers") {
                        ForEach(devServerPorts) { port in
                            portRow(port)
                        }
                    }
                }

                if !otherPorts.isEmpty {
                    Section("Other Listening Ports") {
                        ForEach(otherPorts) { port in
                            portRow(port)
                        }
                    }
                }

                if !isLoading && ports.isEmpty && loadError == nil {
                    Section {
                        ContentUnavailableView(
                            "No Listening Ports",
                            systemImage: "network.slash",
                            description: Text("No listening TCP ports detected on the remote host.")
                        )
                        .listRowBackground(Color.clear)
                    }
                }

                if !(isLoading && ports.isEmpty) && loadError == nil {
                    customPortSection
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if isLoading && ports.isEmpty {
                    ProgressView("Scanning listening ports…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError, ports.isEmpty {
                    ContentUnavailableView {
                        Label("Could Not Scan Ports", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Retry") {
                            Task { await reload() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accent)
                    }
                }
            }
            .refreshable {
                await reload()
            }
            .navigationTitle("Dev Server Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        AppHaptics.impact(.light)
                        Task { await reload() }
                    } label: {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoading || forwardingPort != nil)
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isCustomPortFocused = false }
                }
            }
            .task {
                guard !didInitialLoad else { return }
                didInitialLoad = true
                await reload()
            }
            .sheet(item: $previewTarget) { target in
                InAppSafariView(url: target.url, theme: theme)
                    .preferredColorScheme(AppearanceSettings.preferredColorScheme(for: theme))
                    .ignoresSafeArea()
            }
            .alert(
                "Preview Failed",
                isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(actionError ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
            let idsToStop = ownedForwardIDs
            ownedForwardIDs.removeAll()
            if !idsToStop.isEmpty, let connection = sshConnection {
                Task {
                    for id in idsToStop {
                        await connection.stopLocalForward(id: id)
                    }
                }
            }
        }
    }

    private var customPortSection: some View {
        Section {
            HStack(spacing: 10) {
                TextField("Port (e.g. 3000)", text: $customPortText)
                    .keyboardType(.numberPad)
                    .font(.system(.body, design: .monospaced))
                    .focused($isCustomPortFocused)

                Button {
                    guard let port = parsedCustomPort else { return }
                    startPreview(port: port, processName: nil, remoteHost: "127.0.0.1")
                } label: {
                    if let customPort = parsedCustomPort, forwardingPort == customPort {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Preview", systemImage: "safari")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(palette.accent)
                .disabled(parsedCustomPort == nil || forwardingPort != nil || sshConnection == nil)
            }
        } header: {
            Text("Custom Port")
        } footer: {
            Text("Creates an ephemeral local SSH tunnel (-L 0:127.0.0.1:port) and opens it in-app.")
        }
    }

    private func portRow(_ port: ListeningPort) -> some View {
        let existingForward = activeForward(for: port.port)
        let isBusy = forwardingPort == port.port
        let accent = port.isLikelyDevServer ? palette.accent : palette.neutral

        return Button {
            AppHaptics.impact(.light)
            startPreview(port: port.port, processName: port.processName, remoteHost: remoteHost(for: port))
        } label: {
            HStack(spacing: 12) {
                ProSquircleIcon(
                    symbolName: port.isLikelyDevServer ? "safari.fill" : "network",
                    tint: accent,
                    size: .row,
                    emphasis: existingForward != nil ? .selected : .standard,
                    theme: theme,
                    statusLED: existingForward != nil ? palette.healthy : nil
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(port.processName ?? (port.isLikelyDevServer ? "Dev Server" : "Listening Socket"))
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(":\(port.port)")
                            .font(.system(.caption, design: .monospaced).weight(.bold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(palette.pillFill(for: accent), in: Capsule())
                    }

                    HStack(spacing: 6) {
                        Text("\(port.address):\(port.port)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if let existingForward {
                            Text("· Tunneled :\(existingForward.boundLocalPort)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(palette.healthy)
                        }
                    }
                }

                Spacer(minLength: 8)

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "safari")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(forwardingPort != nil || sshConnection == nil)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let existingForward {
                Button(role: .destructive) {
                    Task { await stopForward(existingForward.id) }
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
            }
        }
        .contextMenu {
            Button("Open Preview", systemImage: "safari") {
                startPreview(port: port.port, processName: port.processName, remoteHost: remoteHost(for: port))
            }
            if let existingForward {
                Button("Stop Tunnel", systemImage: "stop.circle", role: .destructive) {
                    Task { await stopForward(existingForward.id) }
                }
            }
        }
    }

    private func remoteHost(for port: ListeningPort) -> String {
        port.address == "::1" ? "::1" : "127.0.0.1"
    }

    private func startPreview(port: UInt16, processName: String?, remoteHost: String) {
        previewTask?.cancel()
        previewTask = Task {
            await preview(port: port, processName: processName, remoteHost: remoteHost)
        }
    }

    private func activeForward(for remotePort: UInt16) -> ActivePortForward? {
        activeForwards.first { forward in
            forward.rule.remotePort == remotePort && isLoopbackHost(forward.rule.remoteHost)
        }
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "127.0.0.1" || normalized == "localhost" || normalized == "::1"
    }

    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        loadError = nil

        do {
            async let commandTask = live.session.exec(
                ListeningPortsHelper.listListeningPortsCommand(),
                timeout: .seconds(10)
            )
            async let forwardsTask: [ActivePortForward] = sshConnection?.activePortForwards() ?? []

            let (result, forwards) = try await (commandTask, forwardsTask)
            guard !Task.isCancelled, generation == loadGeneration else { return }

            ports = ListeningPortsHelper.parseListeningPorts(from: result.stdout)
            activeForwards = forwards
            isLoading = false
        } catch is CancellationError {
            if generation == loadGeneration {
                isLoading = false
            }
        } catch {
            guard generation == loadGeneration else { return }
            isLoading = false
            if ports.isEmpty {
                loadError = error.localizedDescription
            } else {
                actionError = error.localizedDescription
            }
        }
    }

    private func preview(port: UInt16, processName: String?, remoteHost: String) async {
        isCustomPortFocused = false
        guard let connection = sshConnection else {
            actionError = "An active SSH connection is required for port forwarding."
            return
        }

        forwardingPort = port
        defer { forwardingPort = nil }

        do {
            try Task.checkCancellation()
            let currentForwards = await connection.activePortForwards()
            try Task.checkCancellation()
            activeForwards = currentForwards

            let boundLocalPort: UInt16
            if let existing = currentForwards.first(where: {
                $0.rule.remotePort == port && isLoopbackHost($0.rule.remoteHost)
            }) {
                boundLocalPort = existing.boundLocalPort
            } else {
                let trimmedName = processName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let ruleName = trimmedName.isEmpty ? "Preview :\(port)" : "\(trimmedName) (:\(port))"
                let started = try await connection.startLocalForward(
                    PortForwardRule(
                        name: ruleName,
                        localPort: 0,
                        remoteHost: remoteHost,
                        remotePort: port
                    )
                )
                if Task.isCancelled {
                    await connection.stopLocalForward(id: started.id)
                    return
                }
                ownedForwardIDs.insert(started.id)
                boundLocalPort = started.boundLocalPort
                activeForwards = await connection.activePortForwards()
            }

            try Task.checkCancellation()
            guard let url = URL(string: "http://127.0.0.1:\(boundLocalPort)") else {
                actionError = "Could not build local preview URL for port \(boundLocalPort)."
                return
            }

            AppHaptics.notify(.success)
            previewTarget = PreviewTarget(url: url)
        } catch is CancellationError {
            return
        } catch {
            AppHaptics.notify(.error)
            actionError = "Could not forward port \(port): \(error.localizedDescription)"
        }
    }

    private func stopForward(_ id: UUID) async {
        guard let connection = sshConnection else { return }
        ownedForwardIDs.remove(id)
        await connection.stopLocalForward(id: id)
        activeForwards = await connection.activePortForwards()
        AppHaptics.notify(.warning)
    }
}
