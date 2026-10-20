import AppKit
import SwiftUI
import CalSyncCore

/// The setup workflow: pick the two calendars to track, and the two calendars that
/// receive Busy blocks. Calendars are identified by EventKit identifier, so two
/// accounts holding a calendar called "Calendar" are never confused.
///
/// Built as a grouped `Form`, which is the same construction System Settings uses. It
/// brings native section chrome, label alignment, and light/dark adaptation, so every
/// colour here is semantic and nothing is hardcoded.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let calendars: CalendarStore
    let onSave: () -> Void

    @State private var draft: AppConfig
    @State private var available: [CalendarInfo] = []
    @State private var creatingFor: CreationTarget?
    @State private var errorMessage: String?

    enum CreationTarget: Identifiable {
        case company, client
        var id: Int { self == .company ? 0 : 1 }
        var sideIndex: Int { self == .company ? 0 : 1 }
        var defaultName: String { self == .company ? "Busy (Company)" : "Busy (Client)" }
    }

    init(settings: SettingsStore, calendars: CalendarStore, onSave: @escaping () -> Void) {
        self.settings = settings
        self.calendars = calendars
        self.onSave = onSave
        _draft = State(initialValue: Self.normalized(settings.config))
    }

    /// Guarantees exactly two sides so the pickers always have something to bind to.
    private static func normalized(_ config: AppConfig) -> AppConfig {
        let blank = CalendarRef(id: "", name: "", accountName: "")
        var copy = config
        copy.sides = ["company", "client"].map { id in
            config.sides.first { $0.id == id } ?? SyncSide(id: id, source: blank, mirrorTo: blank)
        }
        return copy
    }

    var body: some View {
        Form {
            if !calendars.hasFullAccess { accessSection }
            summarySection
            sideSection(index: 0, title: "Company calendar",
                        footer: "Events here become Busy blocks on the client calendar.",
                        target: .company)
            sideSection(index: 1, title: "Client calendar",
                        footer: "Events here become Busy blocks on the company calendar.",
                        target: .client)
            optionsSection
            creditsSection
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) { footerBar }
        .frame(minWidth: 560, idealWidth: 580, minHeight: 620, idealHeight: 680)
        .onAppear(perform: reloadCalendars)
        .sheet(item: $creatingFor) { target in
            CreateCalendarSheet(
                calendars: calendars,
                defaultName: target.defaultName,
                onCreated: { info in
                    draft.sides[target.sideIndex].mirrorTo = info.ref
                    reloadCalendars()
                },
                onError: { errorMessage = $0 })
        }
    }

    // MARK: - Sections

    private var accessSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("CalSync needs full access to your calendars")
                        .fontWeight(.medium)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text("Without it the calendar lists stay empty and nothing syncs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open Privacy Settings") {
                    if let url = URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
            .padding(.vertical, 2)
        }
    }

    private var summarySection: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                if let icon = CalSyncMark.appIconImage(points: 56) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)   // decorative; the text carries the meaning
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("CalSync").font(.headline)
                    Text("Copies the times of your events between two calendars, never the "
                       + "titles, notes, or guests. Each event becomes a block titled "
                       + "“\(draft.busyTitle)” on the other calendar. All day events are "
                       + "ignored, events already titled “\(draft.busyTitle)” are never copied "
                       + "back, and only events that have yet to start are mirrored.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func sideSection(index: Int, title: String, footer: String,
                             target: CreationTarget) -> some View {
        Section {
            Picker("Read events from", selection: refBinding(sideIndex: index, \.source)) {
                calendarOptions(available)
            }
            HStack(spacing: 8) {
                Picker("Write Busy blocks to", selection: refBinding(sideIndex: index, \.mirrorTo)) {
                    calendarOptions(available.filter(\.isWritable))
                }
                Button("New…") { creatingFor = target }
                    .help("Create a dedicated Busy calendar in one of your accounts")
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var optionsSection: some View {
        Section {
            TextField("Block title", text: $draft.busyTitle)

            Stepper(value: $draft.windowDays, in: 1...365) {
                LabeledContent("Sync ahead", value: "\(draft.windowDays) days")
            }

            Stepper(value: $draft.paddingMinutes, in: 0...120, step: 5) {
                LabeledContent("Buffer", value: draft.paddingMinutes == 0
                               ? "None" : "\(draft.paddingMinutes) min each side")
            }

            Picker("Check every", selection: $draft.syncIntervalMinutes) {
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("4 hours").tag(240)
            }

            Picker("Notify me", selection: $draft.notifications) {
                ForEach(NotificationPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Options")
        } footer: {
            Text("CalSync also syncs within seconds of you editing either calendar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var creditsSection: some View {
        Section {
            HStack(spacing: 5) {
                Spacer()
                Text("Built by").foregroundStyle(.secondary)
                if let url = URL(string: "https://github.com/getinet") {
                    Link("Mekuria Getinet", destination: url)
                }
                Spacer()
            }
            .font(.caption)
            .listRowBackground(Color.clear)
        }
    }

    /// `.bar` is a system material, so it tracks light and dark on its own.
    private var footerBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                validationLabel
                Spacer(minLength: 12)
                Button("Save") {
                    settings.config = draft
                    onSave()
                    NSApp.keyWindow?.close()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(ConfigValidator.validate(draft) != nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var validationLabel: some View {
        if let problem = errorMessage ?? ConfigValidator.validate(draft) {
            Label {
                Text(problem).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(errorMessage == nil ? Color.secondary : .red)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            Label {
                Text("Ready to sync")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Plumbing

    /// Grouped by account, so two calendars sharing a name stay tellable apart.
    @ViewBuilder
    private func calendarOptions(_ options: [CalendarInfo]) -> some View {
        Text("Not set").tag("")
        ForEach(accountNames(in: options), id: \.self) { account in
            Section(account) {
                ForEach(options.filter { $0.accountName == account }) { calendar in
                    Text(calendar.name).tag(calendar.id)
                }
            }
        }
    }

    private func accountNames(in options: [CalendarInfo]) -> [String] {
        var seen: [String] = []
        for option in options where !seen.contains(option.accountName) {
            seen.append(option.accountName)
        }
        return seen
    }

    /// Writes the whole `CalendarRef`, not only the id, so the display name and account
    /// stay correct in menus without another EventKit lookup.
    private func refBinding(sideIndex: Int,
                            _ keyPath: WritableKeyPath<SyncSide, CalendarRef>) -> Binding<String> {
        Binding(
            get: { draft.sides[sideIndex][keyPath: keyPath].id },
            set: { newID in
                if let info = available.first(where: { $0.id == newID }) {
                    draft.sides[sideIndex][keyPath: keyPath] = info.ref
                } else {
                    draft.sides[sideIndex][keyPath: keyPath] = CalendarRef(id: "", name: "", accountName: "")
                }
                autofillDestinations()
                errorMessage = nil
            })
    }

    /// With only two calendars, each one's blocks belong on the other, so fill that in
    /// and save the user picking the same two calendars a second time. Only ever fills a
    /// blank, so a deliberate choice such as a dedicated Busy calendar survives.
    private func autofillDestinations() {
        if draft.sides[0].mirrorTo.id.isEmpty { draft.sides[0].mirrorTo = draft.sides[1].source }
        if draft.sides[1].mirrorTo.id.isEmpty { draft.sides[1].mirrorTo = draft.sides[0].source }
    }

    private func reloadCalendars() {
        available = calendars.allCalendars()
        // Refresh cached display names in case a calendar was renamed elsewhere.
        for index in draft.sides.indices {
            if let info = available.first(where: { $0.id == draft.sides[index].source.id }) {
                draft.sides[index].source = info.ref
            }
            if let info = available.first(where: { $0.id == draft.sides[index].mirrorTo.id }) {
                draft.sides[index].mirrorTo = info.ref
            }
        }
    }
}

/// Creates a dedicated Busy calendar. Some account types refuse this, so failure is
/// reported plainly with the manual alternative.
private struct CreateCalendarSheet: View {
    let calendars: CalendarStore
    let defaultName: String
    let onCreated: (CalendarInfo) -> Void
    let onError: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var accountID: String = ""
    @State private var accounts: [(id: String, title: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New Busy Calendar").font(.headline)
                Text("Create this in the account that should display the blocks, which is "
                   + "normally the opposite account from the calendar being read.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Form {
                TextField("Name", text: $name)
                Picker("Account", selection: $accountID) {
                    ForEach(accounts, id: \.id) { Text($0.title).tag($0.id) }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .controlSize(.large)
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || accountID.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 480)
        .onAppear {
            name = defaultName
            accounts = calendars.accounts()
            accountID = accounts.first?.id ?? ""
        }
    }

    private func create() {
        do {
            let info = try calendars.createCalendar(
                named: name.trimmingCharacters(in: .whitespaces), inAccountWithID: accountID)
            onCreated(info)
            dismiss()
        } catch {
            onError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            dismiss()
        }
    }
}
