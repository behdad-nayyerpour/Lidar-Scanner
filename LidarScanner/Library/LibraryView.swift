import SwiftUI

struct RootView: View {
    @EnvironmentObject private var library: ScanLibrary
    @State private var selection: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var route: CaptureRoute?
    @State private var pendingRoute: CaptureRoute?
    @State private var showModes = false
    @State private var showSettings = false
    @State private var showTips = false
    @State private var selectedMode: CaptureRoute = .room

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            if let selection {
                ViewerGate(scanID: selection)
            } else {
                emptyDetail
            }
        }
        .navigationSplitViewStyle(.balanced)
        .fullScreenCover(isPresented: $showModes, onDismiss: {
            if let pendingRoute { route = pendingRoute; self.pendingRoute = nil }
        }) { modeSheet }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showTips) { TipsView() }
        .alert(L10n.appName, isPresented: colorNoticePresented) {
            Button(L10n.commonOK, role: .cancel) { library.colorNotice = nil }
        } message: {
            Text(library.colorNotice ?? "")
        }
        .fullScreenCover(item: $route) { route in
            ScanRouter(route: route) { id in
                selection = id
                columnVisibility = .detailOnly
            }
            .environmentObject(library)
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your scans").font(.largeTitle.bold())
                Text("Everything stays on your iPhone.")
                    .font(.subheadline).foregroundStyle(AppColor.textSecondary)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            Button { showModes = true } label: {
                Label(L10n.libraryNewScan, systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .foregroundStyle(AppColor.onAccent)
            .listRowBackground(AppColor.accent)
            .listRowSeparator(.hidden)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(AppColor.textSecondary)
                TextField(L10n.librarySearch, text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(12)
            .background(AppColor.elevated, in: RoundedRectangle(cornerRadius: 12))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            Picker("Scan type", selection: $scanFilter) {
                Text("All").tag(0)
                Text("Rooms").tag(1)
                Text("Objects").tag(2)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            if !DeviceCapability.supportsLiDAR {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.libraryLidarMissingTitle).font(.headline)
                    Text(L10n.libraryLidarMissingBody)
                        .font(.subheadline)
                        .foregroundStyle(AppColor.textSecondary)
                }
                .padding(.vertical, 6)
                .listRowBackground(AppColor.surface)
            }
            if filtered.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? L10n.libraryEmptyTitle : L10n.libraryNoResults,
                    systemImage: "cube.transparent",
                    description: Text(query.isEmpty ? L10n.libraryEmptyBody : L10n.librarySearch)
                )
                .listRowBackground(Color.clear)
            }
            ForEach(filtered) { record in
                ScanRow(
                    record: record,
                    thumbnail: library.thumbnails[record.id],
                    colorProgress: library.refineJob?.scanID == record.id ? library.refineJob?.progress : nil
                )
                    .tag(record.id)
                    .listRowBackground(AppColor.surface)
                    .listRowSeparator(.hidden)
                    .swipeActions {
                        Button(role: .destructive) { delete(record) } label: {
                            Label(L10n.libraryDelete, systemImage: "trash")
                        }
                        if record.canAddColor {
                            Button { library.startAddingColor(to: record.id) } label: {
                                Label(L10n.colorAdd, systemImage: "paintbrush")
                            }
                            .tint(AppColor.accent)
                        }
                        Button {
                            renameText = record.name
                            renameTarget = record
                        } label: {
                            Label(L10n.libraryRename, systemImage: "pencil")
                        }
                        .tint(AppColor.accentSecondary)
                    }
                    .contextMenu {
                        Button(L10n.libraryRename, systemImage: "pencil") {
                            renameText = record.name
                            renameTarget = record
                        }
                        if record.canAddColor {
                            Button(L10n.colorAdd, systemImage: "paintbrush") {
                                library.startAddingColor(to: record.id)
                            }
                        }
                        Button(L10n.libraryDelete, systemImage: "trash", role: .destructive) { delete(record) }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColor.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Label("Scans", systemImage: "folder").foregroundStyle(AppColor.accent)
                Spacer()
                Button { showModes = true } label: {
                    Image(systemName: "plus").font(.title2.bold()).foregroundStyle(AppColor.onAccent)
                        .frame(width: 48, height: 48).background(AppColor.accent, in: Circle())
                }
                Spacer()
                Button { showTips = true } label: { Label("Help", systemImage: "questionmark.circle") }
                    .foregroundStyle(AppColor.textPrimary)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 30).padding(.vertical, 8)
            .background(AppColor.surface)
        }
        .alert(L10n.libraryRename, isPresented: renamePresented) {
            TextField(L10n.libraryRenamePrompt, text: $renameText)
            Button(L10n.librarySave) { commitRename() }
            Button(L10n.libraryCancel, role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(L10n.libraryDeleteTitle, isPresented: deletePresented, titleVisibility: .visible) {
            Button(L10n.libraryDeleteConfirm, role: .destructive) {
                if let deleteTarget {
                    try? library.delete(deleteTarget.id)
                    if selection == deleteTarget.id { selection = nil }
                }
                deleteTarget = nil
            }
            Button(L10n.libraryCancel, role: .cancel) { deleteTarget = nil }
        } message: {
            Text(L10n.libraryDeleteBody)
        }
    }

    @State private var query = ""
    @State private var scanFilter = 0
    @State private var renameTarget: ScanRecord?
    @State private var renameText = ""
    @State private var deleteTarget: ScanRecord?

    private var filtered: [ScanRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.records.filter { record in
            let matchesType = scanFilter == 0 || (scanFilter == 1 && record.mode == .room) || (scanFilter == 2 && record.mode != .room)
            return matchesType && (trimmed.isEmpty || record.name.localizedCaseInsensitiveContains(trimmed))
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var colorNoticePresented: Binding<Bool> {
        Binding(get: { library.colorNotice != nil }, set: { if !$0 { library.colorNotice = nil } })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Menu {
                Button(L10n.tipsTitle, systemImage: "lightbulb") { showTips = true }
                Button(L10n.settingsTitle, systemImage: "gearshape") { showSettings = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(L10n.settingsTitle)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showModes = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(L10n.libraryNewScan)
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(L10n.libraryChoose, systemImage: "cube.transparent", description: Text(L10n.libraryEmptyBody))
            PrimaryButton(title: L10n.libraryNewScan, systemImage: "plus") { showModes = true }
                .frame(maxWidth: 280)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.background)
    }

    private var modeSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("What are you scanning?")
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    if !DeviceCapability.supportsLiDAR {
                        Text(L10n.libraryLidarMissingBody)
                            .font(.subheadline)
                            .foregroundStyle(AppColor.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    modeChoice(.room, title: "Room", detail: "Capture a space", icon: "square.split.bottomrightquarter")
                    modeChoice(.objectLidar, title: "Object", detail: "Capture one item", icon: "shippingbox")
                    Text("Before you start").font(.headline).padding(.top, 12)
                    instruction("Move slowly", "Sweep around at a steady pace.", "figure.walk")
                    instruction("Keep good light", "A well-lit space captures better.", "sun.max")
                    instruction("Cover every side", "Walk around to capture the whole area.", "cube")
                }
                .padding(20)
            }
            .background(AppColor.background)
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Start scanning") { start(selectedMode) }
                    .disabled(!DeviceCapability.supportsLiDAR)
                    .padding(20).background(AppColor.background)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { showModes = false } label: { Image(systemName: "chevron.left") }
                }
                ToolbarItem(placement: .primaryAction) {
                    if DeviceCapability.supportsObjectCapture {
                        Button("Photo capture") { start(.objectPhoto) }
                    }
                }
            }
        }
    }

    private func modeChoice(_ mode: CaptureRoute, title: String, detail: String, icon: String) -> some View {
        Button { selectedMode = mode } label: {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.largeTitle).frame(width: 62)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(AppColor.textSecondary)
                }
                Spacer()
                Image(systemName: selectedMode == mode ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selectedMode == mode ? AppColor.accent : AppColor.textSecondary)
            }
            .foregroundStyle(AppColor.textPrimary)
            .padding(18)
            .background(selectedMode == mode ? AppColor.accent.opacity(0.08) : AppColor.surface,
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selectedMode == mode ? AppColor.accent : AppColor.separator))
        }.buttonStyle(.plain)
    }

    private func instruction(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).frame(width: 50, height: 50)
                .background(AppColor.elevated, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(AppColor.textSecondary)
            }
        }
    }

    private func start(_ route: CaptureRoute) {
        pendingRoute = route
        showModes = false
    }

    private func delete(_ record: ScanRecord) {
        deleteTarget = record
    }

    private func commitRename() {
        guard let renameTarget else { return }
        try? library.rename(renameTarget.id, to: renameText)
        renameText = ""
        self.renameTarget = nil
    }
}

struct ScanRow: View {
    @EnvironmentObject private var library: ScanLibrary
    let record: ScanRecord
    let thumbnail: UIImage?
    var colorProgress: Double?

    var body: some View {
        HStack(spacing: 14) {
            thumbnailView
            VStack(alignment: .leading, spacing: 4) {
                Text(record.name)
                    .font(.headline)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(AppColor.textSecondary)
                if let colorProgress {
                    ProgressView(value: colorProgress)
                        .tint(AppColor.accent)
                    HStack {
                        Text(L10n.colorWorking)
                        Spacer()
                        Button(L10n.colorCancel) { library.cancelRefinement() }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColor.accent)
                } else {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(record.status == .needsReconstruction ? AppColor.warning : AppColor.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .onAppear {}
    }

    private var subtitle: String {
        if record.status == .needsReconstruction { return L10n.libraryNeedsReconstruction }
        if record.canAddColor { return "\(record.mode.title) · \(L10n.colorReady)" }
        return "\(record.mode.title) · \(L10n.triangles(record.triangleCount))"
    }

    @ViewBuilder
    private var thumbnailView: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: record.status == .needsReconstruction ? "photo.on.rectangle" : "cube.transparent")
                    .font(.title2)
                    .foregroundStyle(AppColor.accent)
            }
        }
        .frame(width: 126, height: 100)
        .background(AppColor.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ViewerGate: View {
    let scanID: UUID
    @EnvironmentObject private var library: ScanLibrary

    var body: some View {
        if let record = library.record(scanID) {
            if record.status == .needsReconstruction {
                ReconstructionScreen(scanID: scanID)
            } else {
                ModelViewer(scanID: scanID)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppColor.background)
        }
    }
}

struct SettingsView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = true
    @AppStorage("measurementUnit") private var unitRaw = MeasurementUnit.meters.rawValue
    @Environment(\.dismiss) private var dismiss

    private var unit: Binding<MeasurementUnit> {
        Binding(
            get: { MeasurementUnit(rawValue: unitRaw) ?? .meters },
            set: { unitRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L10n.settingsUnits, selection: unit) {
                        ForEach(MeasurementUnit.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                }
                Section {
                    Button(L10n.settingsIntro) {
                        hasCompletedOnboarding = false
                        dismiss()
                    }
                }
                Section(L10n.settingsCapabilities) {
                    LabeledContent(L10n.settingsLidar, value: DeviceCapability.supportsLiDAR ? L10n.settingsAvailable : L10n.settingsMissing)
                    LabeledContent(L10n.settingsPhoto, value: DeviceCapability.supportsObjectCapture ? L10n.settingsAvailable : L10n.settingsMissing)
                }
                Section {
                    LabeledContent(L10n.settingsVersion, value: versionText)
                    LabeledContent(L10n.settingsBundle, value: Bundle.main.bundleIdentifier ?? "")
                }
            }
            .navigationTitle(L10n.settingsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonDone) { dismiss() }
                }
            }
        }
    }

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

struct TipsView: View {
    @Environment(\.dismiss) private var dismiss
    private let tips = [L10n.tips1, L10n.tips2, L10n.tips3, L10n.tips4, L10n.tips5, L10n.tips6]
    private let symbols = ["tortoise", "sun.max", "arrow.triangle.2.circlepath", "rotate.3d", "checkmark.circle", "square.and.arrow.up"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(tips.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: symbols[index])
                                .foregroundStyle(AppColor.accent)
                                .frame(width: 28)
                            Text(tips[index])
                                .foregroundStyle(AppColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(20)
            }
            .background(AppColor.background)
            .navigationTitle(L10n.tipsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonDone) { dismiss() }
                }
            }
        }
    }
}
