import SwiftUI
import UIKit

// MARK: - App

@main
struct RafaelApp: App {
    var body: some Scene {
        WindowGroup {
            RafaelView()
        }
    }
}

// MARK: - Models

struct StorageSnapshot: Sendable {
    let total: Int64
    let available: Int64
    let importantAvailable: Int64

    var used: Int64 { max(total - available, 0) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct CacheEntry: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let url: URL
    let bytes: Int64
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Disk

enum Disk {
    static var targets: [(label: String, url: URL)] {
        var list: [(label: String, url: URL)] = []
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            list.append((label: "Caches", url: caches))
        }
        list.append((label: "Temp", url: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)))
        return list
    }

    static func snapshot() -> StorageSnapshot? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard
            let values = try? home.resourceValues(forKeys: keys),
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacity
        else { return nil }

        let important = values.volumeAvailableCapacityForImportantUsage ?? Int64(available)
        return StorageSnapshot(total: Int64(total), available: Int64(available), importantAvailable: important)
    }

    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]

        func fileBytes(_ file: URL) -> Int64 {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        if !isDirectory.boolValue {
            return fileBytes(url)
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        while let next = enumerator.nextObject() as? URL {
            let values = try? next.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                total += fileBytes(next)
            }
        }
        return total
    }

    static func cacheEntries() -> [CacheEntry] {
        let fm = FileManager.default
        var out: [CacheEntry] = []
        for target in targets {
            let items = (try? fm.contentsOfDirectory(
                at: target.url,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
            for item in items {
                out.append(CacheEntry(
                    name: "\(target.label)/\(item.lastPathComponent)",
                    url: item,
                    bytes: size(of: item)
                ))
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    static func purgeCaches() -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        for target in targets {
            let items = (try? fm.contentsOfDirectory(
                at: target.url,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
            for item in items {
                let bytes = size(of: item)
                do {
                    try fm.removeItem(at: item)
                    freed += bytes
                } catch {
                    continue
                }
            }
        }
        return freed
    }
}

// MARK: - Model

@MainActor
final class RafaelModel: ObservableObject {
    @Published var snapshot: StorageSnapshot?
    @Published var entries: [CacheEntry] = []
    @Published var isWorking = false
    @Published var lastFreed: Int64?
    @Published var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published var thermal = ProcessInfo.processInfo.thermalState
    @Published var batteryLevel: Float = -1

    let physicalMemory = Int64(ProcessInfo.processInfo.physicalMemory)

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshDevice()
    }

    var cacheTotal: Int64 {
        entries.reduce(0) { $0 + $1.bytes }
    }

    func refreshDevice() {
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermal = ProcessInfo.processInfo.thermalState
        batteryLevel = UIDevice.current.batteryLevel
    }

    private func load() async {
        let result = await Task.detached(priority: .utility) { () -> (StorageSnapshot?, [CacheEntry]) in
            (Disk.snapshot(), Disk.cacheEntries())
        }.value
        snapshot = result.0
        entries = result.1
        refreshDevice()
    }

    func refresh() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await load()
    }

    func clean() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let freed = await Task.detached(priority: .utility) {
            Disk.purgeCaches()
        }.value
        URLCache.shared.removeAllCachedResponses()
        lastFreed = freed
        await load()
    }
}

// MARK: - View

struct RafaelView: View {
    @StateObject private var model = RafaelModel()
    @State private var confirmClean = false

    var body: some View {
        NavigationStack {
            List {
                storageSection
                cacheSection
                deviceSection
            }
            .navigationTitle("Rafael")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isWorking)
                }
            }
            .task { await model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                model.refreshDevice()
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                model.refreshDevice()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
                model.refreshDevice()
            }
            .confirmationDialog(
                "Delete \(Fmt.bytes(model.cacheTotal)) of cache and temp files?",
                isPresented: $confirmClean,
                titleVisibility: .visible
            ) {
                Button("Clean", role: .destructive) {
                    Task { await model.clean() }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: Sections

    private var storageSection: some View {
        Section("Storage") {
            if let snap = model.snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: snap.usedFraction)
                    HStack {
                        Text("\(Fmt.bytes(snap.used)) used")
                        Spacer()
                        Text("\(Fmt.bytes(snap.available)) free")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                row("Total", Fmt.bytes(snap.total))
                row("Free for important use", Fmt.bytes(snap.importantAvailable))
            } else {
                Text("Unavailable").foregroundStyle(.secondary)
            }
        }
    }

    private var cacheSection: some View {
        Section {
            row("Cleanable", Fmt.bytes(model.cacheTotal))

            Button {
                confirmClean = true
            } label: {
                HStack {
                    Text("Clean Cache")
                    Spacer()
                    if model.isWorking {
                        ProgressView()
                    }
                }
            }
            .disabled(model.isWorking || model.cacheTotal == 0)

            if let freed = model.lastFreed {
                row("Last cleanup freed", Fmt.bytes(freed))
            }

            ForEach(model.entries.prefix(5)) { entry in
                row(entry.name, Fmt.bytes(entry.bytes))
                    .font(.footnote)
            }
        } header: {
            Text("Cache")
        } footer: {
            Text("Only this app's own cache and temp files are touched. iOS does not let apps clean other apps.")
        }
    }

    private var deviceSection: some View {
        Section("Device") {
            row("Memory", Fmt.bytes(model.physicalMemory))
            row("Thermal state", model.thermal.label)
            row("Low Power Mode", model.lowPower ? "On" : "Off")
            row(
                "Battery",
                model.batteryLevel < 0 ? "Unknown" : "\(Int((model.batteryLevel * 100).rounded()))%"
            )
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
