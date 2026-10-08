import SwiftUI
import Contacts
import Security
import CryptoKit

struct Credentials: Codable {
    let server: String
    let token: String
}

enum Vault {
    static let service = "fr.cazenave.beatrix"
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "pairing"]
    }
    static func read() -> Credentials? {
        var values = query
        values[kSecReturnData as String] = true
        values[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(values as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }
    static func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let changes: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var values = query
            changes.forEach { values[$0.key] = $0.value }
            guard SecItemAdd(values as CFDictionary, nil) == errSecSuccess else {
                throw ClientError.message("Could not store pairing in Keychain.")
            }
        } else if status != errSecSuccess {
            throw ClientError.message("Could not update pairing in Keychain.")
        }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

enum ClientError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

struct Settings: Codable {
    var name = ""
    var greeting = ""
    var instructions = ""
    var voice = "alloy"
    var voices: [String] = []
    var email_enabled = false
    var email_to = ""
}
struct CallSummary: Codable, Identifiable {
    let id: String
    let started_at: String
    let caller_number: String?
    let caller_name: String?
    let email_status: String
    let status: String
}
struct ContactPayload: Codable {
    let id: String
    let name: String
    let phones: [String]
    let emails: [String]
}
struct PairResponse: Codable { let token: String }
struct APIError: Codable { let error: String }
struct StatusResponse: Codable { let service: String; let contacts: Int }
struct SyncResponse: Codable { let count: Int }
struct CallsResponse: Codable { let calls: [CallSummary] }
struct TranscriptResponse: Codable { let transcript: String }
struct OKResponse: Codable { let ok: Bool }

@MainActor
final class AssistantStore: ObservableObject {
    @Published var credentials = Vault.read()
    @Published var settings = Settings()
    @Published var calls: [CallSummary] = []
    @Published var contactCount = 0
    @Published var busy = false
    @Published var syncing = false
    @Published var message: String?
    @Published var error: String?
    private let session = URLSession(configuration: .ephemeral)
    var isPaired: Bool { credentials != nil }

    func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil,
                                pairingServer: String? = nil) async throws -> T {
        let address = pairingServer ?? credentials?.server ?? ""
        guard let root = URL(string: address), root.scheme == "https", root.host != nil,
              root.user == nil, root.password == nil, root.query == nil, root.fragment == nil else {
            throw ClientError.message("Enter your server’s HTTPS address.")
        }
        let url = root.appendingPathComponent("api").appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if pairingServer == nil, let token = credentials?.token {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ClientError.message("No response from the server.")
        }
        guard (200...299).contains(response.statusCode) else {
            let text = (try? JSONDecoder().decode(APIError.self, from: data))?.error
            throw ClientError.message(text ?? "Server error (\(response.statusCode)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func pair(server: String, code: String) async {
        busy = true
        defer { busy = false }
        do {
            let address = server.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = try JSONEncoder().encode(["code": code.trimmingCharacters(in: .whitespacesAndNewlines)])
            let result: PairResponse = try await request("pair", method: "POST", body: body, pairingServer: address)
            let pairing = Credentials(server: address, token: result.token)
            try Vault.save(pairing)
            credentials = pairing
            UserDefaults.standard.removeObject(forKey: "contactsDigest")
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        guard isPaired else { return }
        busy = true
        defer { busy = false }
        do {
            let settings: Settings = try await request("settings")
            let status: StatusResponse = try await request("status")
            let result: CallsResponse = try await request("calls")
            self.settings = settings
            contactCount = status.contacts
            calls = result.calls
        } catch { self.error = error.localizedDescription }
    }

    func save(_ draft: Settings) async {
        busy = true
        defer { busy = false }
        do {
            var values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as! [String: Any]
            values.removeValue(forKey: "voices")
            let body = try JSONSerialization.data(withJSONObject: values)
            let _: OKResponse = try await request("settings", method: "PUT", body: body)
            settings = draft
            message = "Settings saved. They apply to new calls."
        } catch { self.error = error.localizedDescription }
    }

    func synchronizeContacts(askPermission: Bool) async {
        guard isPaired, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let status = CNContactStore.authorizationStatus(for: .contacts)
            if status == .notDetermined && askPermission {
                let allowed = try await CNContactStore().requestAccess(for: .contacts)
                guard allowed else { throw ClientError.message("Contact access was not granted.") }
            }
            let current = CNContactStore.authorizationStatus(for: .contacts)
            var allowed = current == .authorized
            if #available(iOS 18.0, *) { allowed = allowed || current == .limited }
            guard allowed else {
                if askPermission { throw ClientError.message("Allow Contacts access in iPhone Settings.") }
                return
            }
            let contacts = try await Task.detached(priority: .utility) {
                let store = CNContactStore()
                let keys = [CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey,
                            CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey]
                let request = CNContactFetchRequest(keysToFetch: keys as [CNKeyDescriptor])
                var result: [ContactPayload] = []
                try store.enumerateContacts(with: request) { contact, _ in
                    let fullName = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                    result.append(ContactPayload(id: contact.identifier,
                        name: fullName.isEmpty ? contact.organizationName : fullName,
                        phones: contact.phoneNumbers.map { $0.value.stringValue },
                        emails: contact.emailAddresses.map { String($0.value) }))
                }
                return result.sorted { $0.id < $1.id }
            }.value
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let body = try encoder.encode(["contacts": contacts])
            let fingerprint = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            if !askPermission && UserDefaults.standard.string(forKey: "contactsDigest") == fingerprint { return }
            let result: SyncResponse = try await request("contacts", method: "PUT", body: body)
            contactCount = result.count
            UserDefaults.standard.set(fingerprint, forKey: "contactsDigest")
            UserDefaults.standard.set(true, forKey: "contactSyncEnabled")
            UserDefaults.standard.set(Date(), forKey: "lastContactSync")
            message = "Synced \(result.count) contacts."
        } catch { self.error = error.localizedDescription }
    }

    func disconnect() async {
        do {
            let _: OKResponse = try await request("device", method: "DELETE")
            Vault.clear()
            credentials = nil
            calls = []
            UserDefaults.standard.set(false, forKey: "contactSyncEnabled")
            UserDefaults.standard.removeObject(forKey: "contactsDigest")
        } catch { self.error = error.localizedDescription }
    }
}

@main
struct BeatrixApp: App {
    @StateObject private var store = AssistantStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active && store.isPaired && UserDefaults.standard.bool(forKey: "contactSyncEnabled") {
                        Task { await store.synchronizeContacts(askPermission: false) }
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AssistantStore
    var body: some View {
        Group {
            if store.isPaired {
                TabView {
                    SettingsView().tabItem { Label("Assistant", systemImage: "slider.horizontal.3") }
                    ContactsView().tabItem { Label("Contacts", systemImage: "person.crop.circle") }
                    CallsView().tabItem { Label("Calls", systemImage: "phone") }
                }
            } else { PairingView() }
        }
        .alert("Couldn’t complete request", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("Beatrix", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: { Text(store.message ?? "") }
    }
}

struct PairingView: View {
    @EnvironmentObject var store: AssistantStore
    @State private var server = ""
    @State private var code = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Your assistant") {
                    TextField("https://your-server.example", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Pairing code", text: $code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Button("Pair iPhone") { Task { await store.pair(server: server, code: code) } }
                        .disabled(store.busy || server.isEmpty || code.isEmpty)
                    Text("Use the single-use code generated on your server. Pairing expires after 10 minutes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if store.busy { ProgressView() }
            }.navigationTitle("Beatrix")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: AssistantStore
    @State private var draft = Settings()
    @State private var confirmDisconnect = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") { TextField("Assistant name", text: $draft.name) }
                Section("Voice") {
                    Picker("Voice", selection: $draft.voice) {
                        ForEach(draft.voices, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
                Section("Greeting") {
                    TextEditor(text: $draft.greeting).frame(minHeight: 90)
                    Text("Use {assistant_name} to insert the assistant’s name.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Instructions") { TextEditor(text: $draft.instructions).frame(minHeight: 160) }
                Section("Transcript emails") {
                    Toggle("Email after each call", isOn: $draft.email_enabled)
                    TextField("Recipient email", text: $draft.email_to)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button("Save changes") { Task { await store.save(draft) } }.disabled(store.busy)
                Section("Connection") {
                    Text(store.credentials?.server ?? "").font(.footnote)
                    Button("Disconnect this iPhone", role: .destructive) { confirmDisconnect = true }
                }
            }.navigationTitle("Your assistant")
            .task { await store.refresh(); draft = store.settings }
            .confirmationDialog("Disconnect and revoke this iPhone’s access?", isPresented: $confirmDisconnect) {
                Button("Disconnect", role: .destructive) { Task { await store.disconnect() } }
            }
        }
    }
}

struct ContactsView: View {
    @EnvironmentObject var store: AssistantStore
    @AppStorage("contactSyncEnabled") private var syncEnabled = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Contact database") {
                    LabeledContent("Contacts on server", value: String(store.contactCount))
                    Button(store.syncing ? "Synchronizing…" : "Authorize and sync contacts") {
                        Task { await store.synchronizeContacts(askPermission: true) }
                    }.disabled(store.syncing)
                    Toggle("Sync when app opens", isOn: $syncEnabled)
                }
                Section {
                    Text("Only names, phone numbers and email addresses are copied to your server. Apple Contacts stays unchanged. The server snapshot is replaced with the contacts this iPhone can access.")
                    Text("With limited Contacts access, only your selected contacts are synchronized. Sync runs while the app is open; continuous background sync is not enabled.")
                }.font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("Contacts")
        }
    }
}

struct CallsView: View {
    @EnvironmentObject var store: AssistantStore
    var body: some View {
        NavigationStack {
            List(store.calls) { call in
                NavigationLink {
                    TranscriptView(call: call)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(call.caller_name ?? call.caller_number ?? "Unknown caller").font(.headline)
                        Text(call.started_at).font(.caption).foregroundStyle(.secondary)
                        Text("Email: " + call.email_status).font(.caption)
                    }
                }
            }.navigationTitle("Calls")
            .overlay { if store.calls.isEmpty { ContentUnavailableView("No calls yet", systemImage: "phone") } }
            .refreshable { await store.refresh() }
            .task { await store.refresh() }
        }
    }
}

struct TranscriptView: View {
    @EnvironmentObject var store: AssistantStore
    let call: CallSummary
    @State private var text = "Loading…"
    var body: some View {
        ScrollView { Text(text).frame(maxWidth: .infinity, alignment: .leading).padding().textSelection(.enabled) }
            .navigationTitle(call.caller_name ?? "Transcript")
            .task {
                do {
                    let result: TranscriptResponse = try await store.request("calls/" + call.id)
                    text = result.transcript
                } catch { text = error.localizedDescription }
            }
    }
}
