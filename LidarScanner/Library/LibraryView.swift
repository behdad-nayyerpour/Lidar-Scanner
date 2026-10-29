import SwiftUI

struct RootView: View {
    @EnvironmentObject private var library: ScanLibrary
    @State private var selection: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var route: CaptureRoute?
    @State private var showModes = false
    @State private var showSettings = false
    @State private var showTips = false

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
        .sheet(isPresented: $showModes) { modeSheet }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showTips) { TipsView() }
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
                ScanRow(record: record, thumbnail: library.thumbnails[record.id])
                    .tag(record.id)
                    .listRowBackground(AppColor.surface)
                    .swipeActions {
                        Button(role: .destructive) { delete(record) } label: {
                            Label(L10n.libraryDelete, systemImage: "trash")
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
                        Button(L10n.libraryDelete, systemImage: "trash", role: .destructive) { delete(record) }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColor.background)
        .navigationTitle(L10n.libraryTitle)
        .searchable(text: $query, prompt: L10n.librarySearch)
        .toolbar { toolbar }
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
    @State private var renameTarget: ScanRecord?
    @State private var renameText = ""
    @State private var deleteTarget: ScanRecord?

    private var filtered: [ScanRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return library.records }
        return library.records.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
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
                VStack(spacing: 12) {
                    if !DeviceCapability.supportsLiDAR {
                        Text(L10n.libraryLidarMissingBody)
                            .font(.subheadline)
                            .foregroundStyle(AppColor.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ModeCard(
                        title: L10n.modeRoomTitle,
                        bodyText: L10n.modeRoomBody,
                        systemImage: "square.split.bottomrightquarter",
                        enabled: DeviceCapability.supportsLiDAR
                    ) { start(.room) }
                    ModeCard(
                        title: L10n.modeObjectLidarTitle,
                        bodyText: L10n.modeObjectLidarBody,
                        systemImage: "circle.dashed",
                        enabled: DeviceCapability.supportsLiDAR
                    ) { start(.objectLidar) }
                    ModeCard(
                        title: L10n.modeObjectPhotoTitle,
                        bodyText: L10n.modeObjectPhotoBody,
                        systemImage: "camera.viewfinder",
                        enabled: DeviceCapability.supportsObjectCapture,
                        footnote: DeviceCapability.supportsObjectCapture ? nil : L10n.modeObjectPhotoUnavailable
                    ) { start(.objectPhoto) }
                }
                .padding(20)
            }
            .background(AppColor.background)
            .navigationTitle(L10n.libraryNewScan)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonClose) { showModes = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func start(_ route: CaptureRoute) {
        showModes = false
        DispatchQueue.main.async {
            self.route = route
        }
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
    let record: ScanRecord
    let thumbnail: UIImage?

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
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(record.status == .needsReconstruction ? AppColor.warning : AppColor.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .onAppear {}
    }

    private var subtitle: String {
        if record.status == .needsReconstruction { return L10n.libraryNeedsReconstruction }
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
        .frame(width: 64, height: 64)
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
