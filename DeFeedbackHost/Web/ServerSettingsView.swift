//
//  ServerSettingsView.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//

import SwiftUI

struct ServerSettingsView: View {

    let host: AudioHost
    let web: WebControlService

    @State private var port = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field { case port, username, password }

    var body: some View {
        Form {
            Section {
                Toggle("Enable web server", isOn: enabledBinding)

                LabeledContent("Port") {
                    TextField("", text: $port)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .port)
                        .onSubmit(applyPort)
                }
            } header: {
                Text("Web Control")
            } footer: {
                Text("""
                    Starts the web server available to the network (not just localhost). \
                    Port number must be above \(String(WebServerSettings.portRange.lowerBound)).
                    Web server must be enabled for Stream Deck integration to work.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Require sign-in", isOn: authBinding)

                TextField("Username", text: usernameBinding)
                    .focused($focusedField, equals: .username)
                    .disabled(!host.webServerSettings.requiresAuthentication)

                SecureField("Password", text: $password)
                    .focused($focusedField, equals: .password)
                    .disabled(!host.webServerSettings.requiresAuthentication)
                    .onSubmit(applyPassword)
                Toggle("Allow unauthenticated from localhost (i.e. Stream Deck connections)", isOn: unauthedLocalhost)
                    .disabled(!host.webServerSettings.requiresAuthentication)

            } header: {
                Text("Authentication")
            } footer: {
                securityFooter
            }

            Section("Status") {
                statusRows
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .task {
            port = String(host.webServerSettings.port)
            password = KeychainPassword.read() ?? ""
        }
        // wait to apply the settings until focus changes so every
        // keystroke doesn't try to save it.
        .onChange(of: focusedField) { previous, _ in
            switch previous {
            case .port: applyPort()
            case .password: applyPassword()
            case .username, nil: break
            }
        }
    }


    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding {
            host.webServerSettings.isEnabled
        } set: { newValue in
            applyPort()
            applyPassword()
            host.webServerSettings.isEnabled = newValue
            web.reconcile()
        }
    }

    private var authBinding: Binding<Bool> {
        Binding {
            host.webServerSettings.requiresAuthentication
        } set: { newValue in
            host.webServerSettings.requiresAuthentication = newValue
            if newValue { applyPassword() }
            web.reconcile()
        }
    }

    private var usernameBinding: Binding<String> {
        Binding {
            host.webServerSettings.username
        } set: { newValue in
            host.webServerSettings.username = newValue
            web.reconcile()
        }
    }

    private var unauthedLocalhost: Binding<Bool> {
        Binding {
            host.webServerSettings.unauthedLocalhostAllowed
        } set: { newValue in
            host.webServerSettings.unauthedLocalhostAllowed = newValue
            web.reconcile()
        }
    }


    // MARK: - Applying

    private func applyPort() {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)),
              WebServerSettings.portRange.contains(value) else {
            // revert if the port isnt valid
            port = String(host.webServerSettings.port)
            return
        }
        guard value != host.webServerSettings.port else { return }

        host.webServerSettings.port = value
        web.reconcile()
    }

    private func applyPassword() {
        guard password != (KeychainPassword.read() ?? "") else { return }
        KeychainPassword.write(password)
        web.reconcile()
    }


    // MARK: - Status

    @ViewBuilder
    private var statusRows: some View {
        if let message = web.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } else if web.isListening {
            LabeledContent("Address") {
                Text(web.reachableURL ?? "—")
                    .textSelection(.enabled)
                    .monospaced()
            }
            LabeledContent("Connected") {
                Text(web.connectedClients == 1
                     ? "1 browser"
                     : "\(web.connectedClients) browsers")
            }
        } else {
            Text("Not running")
                .foregroundStyle(.secondary)
        }
    }


    @ViewBuilder
    private var securityFooter: some View {
        let text = if !host.webServerSettings.isEnabled {
            "The web server is off."
        } else if host.webServerSettings.requiresAuthentication {
            """
            IMPORTANT! Credentials are sent unencrypted over HTTP and can be read by anyone on this network. Do not use this on an unsecured network!
            """
        } else {
            "NO AUTHENTICATION IS ENABLED.  Make sure your network is secure."
        }

        Text(text)
            .font(.caption)
            .foregroundStyle(host.webServerSettings.isEnabled && !host.webServerSettings.requiresAuthentication
                             ? .orange
                             : .secondary)
    }
}

#Preview {
    let host = AudioHost()
    return ServerSettingsView(host: host, web: WebControlService(host: host))
}
