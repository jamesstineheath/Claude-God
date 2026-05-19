# Extensions Tab — Plugin Marketplace Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Memory tab with an "Extensions" tab containing a plugin marketplace (Discover/Installed) alongside the existing Memory features.

**Architecture:** New `PluginManager` class reads local marketplace data from `~/.claude/plugins/` (marketplace.json, installed_plugins.json, install-counts-cache.json, settings.json). Plugin install/uninstall/toggle runs the `claude` CLI via `Process()`. The existing `MemoryManager` is preserved as-is. The tab UI uses the same sub-tab pattern already in the Memory tab (Memories/Activity/Projects → Discover/Installed/Memory).

**Tech Stack:** Swift 5.9, SwiftUI, Foundation (Process, JSONDecoder, FileManager)

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/PluginManager.swift` | **Create** | Models + data loading from `~/.claude/plugins/` files, install/uninstall/toggle via `claude` CLI |
| `Sources/MenuBarView.swift` | **Modify** | Rename Memory tab → Extensions, add Discover + Installed sub-tabs, wire PluginManager |
| `Sources/UsageManager.swift` | **Modify** | Add `pluginManager` property, rename `.memory` → `.extensions` in Tab enum, forward objectWillChange |

---

## Task 1: Create PluginManager — Models & Data Loading

**Files:**
- Create: `Sources/PluginManager.swift`

- [ ] **Step 1: Create models**

```swift
// Sources/PluginManager.swift
import Foundation

// MARK: - Models

struct MarketplacePlugin: Identifiable, Codable {
    let name: String
    let description: String
    let version: String
    let category: String
    let marketplace: String // e.g. "claude-plugins-official"
    var installCount: Int = 0
    var isInstalled: Bool = false
    var isEnabled: Bool = false
    var installedVersion: String?

    var id: String { "\(name)@\(marketplace)" }

    var displayCategory: String {
        category.isEmpty ? "other" : category
    }
}

// Decodable helpers for the JSON files
private struct InstallCountsFile: Decodable {
    let version: Int
    let counts: [PluginCount]

    struct PluginCount: Decodable {
        let plugin: String
        let unique_installs: Int // swiftlint:disable:this identifier_name
    }
}

private struct InstalledPluginsFile: Decodable {
    let version: Int
    let plugins: [String: [InstalledEntry]]

    struct InstalledEntry: Decodable {
        let scope: String
        let installPath: String
        let version: String
        let installedAt: String
        let lastUpdated: String
    }
}

private struct MarketplaceFile: Decodable {
    let name: String
    let description: String?
    let plugins: [MarketplaceEntry]

    struct MarketplaceEntry: Decodable {
        let name: String
        let description: String?
        let version: String?
        let category: String?
    }
}
```

- [ ] **Step 2: Create PluginManager class with published properties**

```swift
// MARK: - Manager

class PluginManager: ObservableObject {
    @Published var availablePlugins: [MarketplacePlugin] = []
    @Published var categories: [String] = []
    @Published var selectedCategory: String?
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var isInstalling: String? = nil // plugin id currently being installed

    private static let pluginsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/plugins")
    }()

    private static let settingsPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }()
}
```

- [ ] **Step 3: Implement `refresh()` — load all marketplace data**

```swift
    func refresh() {
        isLoading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Self.loadPluginData()
            DispatchQueue.main.async {
                self.availablePlugins = result.plugins
                self.categories = result.categories
                self.isLoading = false
            }
        }
    }

    private struct LoadResult {
        let plugins: [MarketplacePlugin]
        let categories: [String]
    }

    private static func loadPluginData() -> LoadResult {
        // 1. Load all marketplace.json files
        var plugins: [MarketplacePlugin] = []
        let marketplacesDir = pluginsDir.appendingPathComponent("marketplaces")
        let fm = FileManager.default

        if let marketplaces = try? fm.contentsOfDirectory(atPath: marketplacesDir.path) {
            for marketplace in marketplaces {
                let jsonPath = marketplacesDir
                    .appendingPathComponent(marketplace)
                    .appendingPathComponent(".claude-plugin/marketplace.json")
                guard let data = try? Data(contentsOf: jsonPath),
                      let file = try? JSONDecoder().decode(MarketplaceFile.self, from: data) else { continue }

                for entry in file.plugins {
                    plugins.append(MarketplacePlugin(
                        name: entry.name,
                        description: entry.description ?? "",
                        version: entry.version ?? "1.0.0",
                        category: entry.category ?? "",
                        marketplace: file.name
                    ))
                }
            }
        }

        // 2. Merge install counts
        let countsPath = pluginsDir.appendingPathComponent("install-counts-cache.json")
        if let data = try? Data(contentsOf: countsPath),
           let counts = try? JSONDecoder().decode(InstallCountsFile.self, from: data) {
            let lookup = Dictionary(uniqueKeysWithValues: counts.counts.map { ($0.plugin, $0.unique_installs) })
            for i in plugins.indices {
                plugins[i].installCount = lookup[plugins[i].id] ?? 0
            }
        }

        // 3. Merge installed state
        let installedPath = pluginsDir.appendingPathComponent("installed_plugins.json")
        if let data = try? Data(contentsOf: installedPath),
           let installed = try? JSONDecoder().decode(InstalledPluginsFile.self, from: data) {
            for i in plugins.indices {
                if let entries = installed.plugins[plugins[i].id], let entry = entries.first {
                    plugins[i].isInstalled = true
                    plugins[i].installedVersion = entry.version
                }
            }
        }

        // 4. Merge enabled state
        if let data = try? Data(contentsOf: settingsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let enabled = json["enabledPlugins"] as? [String: Bool] {
            for i in plugins.indices {
                plugins[i].isEnabled = enabled[plugins[i].id] ?? false
            }
        }

        // 5. Sort by install count descending
        plugins.sort { $0.installCount > $1.installCount }

        // 6. Extract categories
        let categories = Array(Set(plugins.compactMap { $0.category.isEmpty ? nil : $0.category })).sorted()

        return LoadResult(plugins: plugins, categories: categories)
    }
```

- [ ] **Step 4: Add filtered plugins computed property**

```swift
    var filteredPlugins: [MarketplacePlugin] {
        availablePlugins.filter { plugin in
            let matchesSearch = searchText.isEmpty ||
                plugin.name.localizedCaseInsensitiveContains(searchText) ||
                plugin.description.localizedCaseInsensitiveContains(searchText)
            let matchesCategory = selectedCategory == nil || plugin.category == selectedCategory
            return matchesSearch && matchesCategory
        }
    }

    var installedPlugins: [MarketplacePlugin] {
        availablePlugins.filter(\.isInstalled)
    }
```

- [ ] **Step 5: Implement install/uninstall/toggle via claude CLI**

```swift
    // MARK: - Plugin actions

    func installPlugin(_ plugin: MarketplacePlugin) {
        isInstalling = plugin.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let success = Self.runClaude(arguments: ["plugin", "install", "\(plugin.name)@\(plugin.marketplace)"])
            DispatchQueue.main.async {
                self?.isInstalling = nil
                if success { self?.refresh() }
            }
        }
    }

    func uninstallPlugin(_ plugin: MarketplacePlugin) {
        isInstalling = plugin.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let success = Self.runClaude(arguments: ["plugin", "uninstall", "\(plugin.name)@\(plugin.marketplace)"])
            DispatchQueue.main.async {
                self?.isInstalling = nil
                if success { self?.refresh() }
            }
        }
    }

    func togglePlugin(_ plugin: MarketplacePlugin, enabled: Bool) {
        // Directly modify settings.json enabledPlugins
        guard let data = try? Data(contentsOf: Self.settingsPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var enabledPlugins = json["enabledPlugins"] as? [String: Bool] ?? [:]
        enabledPlugins[plugin.id] = enabled
        json["enabledPlugins"] = enabledPlugins
        if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? newData.write(to: Self.settingsPath)
        }
        if let idx = availablePlugins.firstIndex(where: { $0.id == plugin.id }) {
            availablePlugins[idx].isEnabled = enabled
        }
    }

    private static func runClaude(arguments: [String]) -> Bool {
        let process = Process()
        // Try common paths
        let claudePaths = [
            "/usr/local/bin/claude",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
        ]
        guard let claudePath = claudePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            Log.error("claude binary not found")
            return false
        }
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            Log.error("Failed to run claude: \(error)")
            return false
        }
    }
```

- [ ] **Step 6: Add install count formatting helper**

```swift
    static func formatInstallCount(_ count: Int) -> String {
        switch count {
        case ..<1000: return "\(count)"
        case ..<1_000_000: return String(format: "%.1fK", Double(count) / 1000)
        default: return String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }
```

- [ ] **Step 7: Build to verify**

Run: `xcodegen generate && xcodebuild -scheme SubMaxxing -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
git add Sources/PluginManager.swift
git commit -m "feat: add PluginManager for reading marketplace data and managing plugins"
```

---

## Task 2: Wire PluginManager into UsageManager

**Files:**
- Modify: `Sources/UsageManager.swift:219-220` (Tab enum + pluginManager property)
- Modify: `Sources/UsageManager.swift:567-573` (objectWillChange forwarding section)

- [ ] **Step 1: Rename `.memory` to `.extensions` in Tab enum and add pluginManager**

In `Sources/UsageManager.swift`, change:
```swift
enum Tab: Int { case usage, analytics, timeline, roi, memory }
```
to:
```swift
enum Tab: Int { case usage, analytics, timeline, roi, extensions }
```

Add after `let memoryManager = MemoryManager()`:
```swift
let pluginManager = PluginManager()
```

- [ ] **Step 2: Forward pluginManager objectWillChange**

After the existing `memoryManager.objectWillChange.sink` block, add:
```swift
pluginManager.objectWillChange.sink { [weak self] _ in
    self?.objectWillChange.send()
}.store(in: &cancellables)
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -scheme SubMaxxing -configuration Debug build 2>&1 | grep "error:" | head -5`
Expected: errors only in MenuBarView.swift (still references `.memory`)

- [ ] **Step 4: Commit**

```bash
git add Sources/UsageManager.swift
git commit -m "feat: add PluginManager to UsageManager, rename memory tab to extensions"
```

---

## Task 3: Update MenuBarView — Rename Tab & Add Extensions Sub-tabs

**Files:**
- Modify: `Sources/MenuBarView.swift:23` (@State property for extensions sub-tab)
- Modify: `Sources/MenuBarView.swift:63` (tab routing)
- Modify: `Sources/MenuBarView.swift:180-183` (tab button)
- Modify: `Sources/MenuBarView.swift:1715-1731` (memoryView → extensionsView)
- Modify: `Sources/MenuBarView.swift:1793-1798` (MemorySection enum → ExtensionsSection)

- [ ] **Step 1: Add extensionsSection state, rename memorySection, update enum**

Replace the `@State private var memorySection` and `MemorySection` enum:
```swift
@State private var extensionsSection: ExtensionsSection = .discover
```

```swift
private enum ExtensionsSection: String, CaseIterable {
    case discover = "Discover"
    case installed = "Installed"
    case memory = "Memory"
}
```

- [ ] **Step 2: Replace all `.memory` tab references with `.extensions`**

- `manager.selectedTab == .memory` → `manager.selectedTab == .extensions`
- `manager.selectedTab = .memory` → `manager.selectedTab = .extensions`
- Tab label `"Memory"` → `"Extensions"`
- On tab select, also call `manager.pluginManager.refresh()` alongside `manager.memoryManager.refresh()`

- [ ] **Step 3: Rewrite `memoryView` → `extensionsView`**

The top-level view dispatches to either install guide (if claude-mem not installed AND on memory sub-tab) or the extensions content:
```swift
@ViewBuilder
private var extensionsView: some View {
    extensionsContent
}
```

- [ ] **Step 4: Rewrite `memoryContent` → `extensionsContent`**

The section picker now shows Discover/Installed/Memory. The stats cards move to the Memory sub-section. The export/refresh buttons stay in Memory sub-tab only.

```swift
private var extensionsContent: some View {
    VStack(alignment: .leading, spacing: 12) {
        // Section picker
        HStack(spacing: 6) {
            ForEach(ExtensionsSection.allCases, id: \.rawValue) { section in
                Button {
                    extensionsSection = section
                } label: {
                    Text(section.rawValue)
                        .font(.system(size: 10, weight: extensionsSection == section ? .semibold : .regular))
                        .foregroundColor(extensionsSection == section ? .primary : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(extensionsSection == section ? Theme.muted : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }

        // Content
        switch extensionsSection {
        case .discover:
            discoverView
        case .installed:
            installedPluginsView
        case .memory:
            memorySubView
        }
    }
}
```

- [ ] **Step 5: Create `memorySubView`**

Wrap the existing memory content (stats cards, search bar, memory sections) into `memorySubView`. This is essentially the old `memoryContent` minus the section picker (which is now at the extensions level). Keep the internal memory sub-tabs (Memories/Activity/Projects) and all existing memory features.

- [ ] **Step 6: Build to verify**

Run: `xcodegen generate && xcodebuild -scheme SubMaxxing -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add Sources/MenuBarView.swift
git commit -m "feat: rename Memory tab to Extensions with Discover/Installed/Memory sub-tabs"
```

---

## Task 4: Build Discover View UI

**Files:**
- Modify: `Sources/MenuBarView.swift` (add discoverView, pluginCard)

- [ ] **Step 1: Create discoverView with search + category filter**

```swift
private var discoverView: some View {
    VStack(alignment: .leading, spacing: 8) {
        // Search bar
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            TextField("Search plugins...", text: Binding(
                get: { manager.pluginManager.searchText },
                set: { manager.pluginManager.searchText = $0 }
            ))
                .font(.system(size: 11))
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.muted)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )

        // Category filter
        if !manager.pluginManager.categories.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    categoryChip("All", isSelected: manager.pluginManager.selectedCategory == nil) {
                        manager.pluginManager.selectedCategory = nil
                    }
                    ForEach(manager.pluginManager.categories, id: \.self) { cat in
                        categoryChip(cat.capitalized, isSelected: manager.pluginManager.selectedCategory == cat) {
                            manager.pluginManager.selectedCategory = cat
                        }
                    }
                }
            }
        }

        // Plugin list
        if manager.pluginManager.isLoading {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading plugins...")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 100)
        } else if manager.pluginManager.filteredPlugins.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
                Text("No plugins found")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 100)
        } else {
            VStack(spacing: 6) {
                ForEach(manager.pluginManager.filteredPlugins) { plugin in
                    pluginCard(plugin)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Create pluginCard**

```swift
private func pluginCard(_ plugin: MarketplacePlugin) -> some View {
    SHCard {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(plugin.name)
                            .font(.system(size: 11, weight: .semibold))
                        Text("v\(plugin.version)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Text(plugin.marketplace)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Spacer()
                pluginActionButton(plugin)
            }

            Text(plugin.description)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                if !plugin.category.isEmpty {
                    memoryTag(plugin.displayCategory.capitalized, icon: "square.grid.2x2")
                }
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 8))
                    Text(PluginManager.formatInstallCount(plugin.installCount))
                        .font(.system(size: 9))
                }
                .foregroundColor(.secondary)
            }
        }
    }
}
```

- [ ] **Step 3: Create pluginActionButton and categoryChip helpers**

```swift
@ViewBuilder
private func pluginActionButton(_ plugin: MarketplacePlugin) -> some View {
    if manager.pluginManager.isInstalling == plugin.id {
        ProgressView()
            .controlSize(.small)
    } else if plugin.isInstalled {
        Text("Installed")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.muted)
            )
    } else {
        Button {
            manager.pluginManager.installPlugin(plugin)
        } label: {
            Text("Install")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.accent)
                )
        }
        .buttonStyle(.plain)
    }
}

private func categoryChip(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(label)
            .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
            .foregroundColor(isSelected ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Theme.muted : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Theme.border, lineWidth: isSelected ? 0 : 1)
                    )
            )
    }
    .buttonStyle(.plain)
}
```

- [ ] **Step 4: Build and verify**

Run: `xcodegen generate && xcodebuild -scheme SubMaxxing -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Sources/MenuBarView.swift
git commit -m "feat: add Discover view with plugin cards, search, and category filter"
```

---

## Task 5: Build Installed Plugins View

**Files:**
- Modify: `Sources/MenuBarView.swift` (add installedPluginsView, installedPluginRow)

- [ ] **Step 1: Create installedPluginsView**

```swift
@ViewBuilder
private var installedPluginsView: some View {
    if manager.pluginManager.installedPlugins.isEmpty {
        VStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 20))
                .foregroundColor(.secondary)
            Text("No plugins installed")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    } else {
        VStack(spacing: 6) {
            ForEach(manager.pluginManager.installedPlugins) { plugin in
                installedPluginRow(plugin)
            }
        }
    }
}
```

- [ ] **Step 2: Create installedPluginRow with toggle and uninstall**

```swift
private func installedPluginRow(_ plugin: MarketplacePlugin) -> some View {
    SHCard {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(plugin.name)
                            .font(.system(size: 11, weight: .semibold))
                        Text("v\(plugin.installedVersion ?? plugin.version)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if !plugin.category.isEmpty {
                        memoryTag(plugin.displayCategory.capitalized, icon: "square.grid.2x2")
                    }
                }
                Spacer()

                // Enabled toggle
                Toggle("", isOn: Binding(
                    get: { plugin.isEnabled },
                    set: { manager.pluginManager.togglePlugin(plugin, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }

            Text(plugin.description)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(2)

            HStack {
                // Update available indicator
                if let installed = plugin.installedVersion, installed != plugin.version {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                        Text("v\(plugin.version) available")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    }
                }

                Spacer()

                // Uninstall
                if manager.pluginManager.isInstalling == plugin.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        manager.pluginManager.uninstallPlugin(plugin)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: 8))
                            Text("Uninstall")
                                .font(.system(size: 9))
                        }
                        .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Build and verify**

Run: `xcodegen generate && xcodebuild -scheme SubMaxxing -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/MenuBarView.swift
git commit -m "feat: add Installed plugins view with toggle and uninstall"
```

---

## Task 6: Final Integration & Polish

**Files:**
- Modify: `Sources/MenuBarView.swift` (cleanup, keyboard shortcut)
- Modify: `Sources/UsageManager.swift` (ensure pluginManager refreshes on tab select)

- [ ] **Step 1: Ensure plugins load when Extensions tab is selected**

In the tab button action (around line 180), add `manager.pluginManager.refresh()`:
```swift
SHTab(label: "Extensions", isActive: manager.selectedTab == .extensions) {
    manager.selectedTab = .extensions
    manager.memoryManager.refresh()
    manager.pluginManager.refresh()
}
.keyboardShortcut("5", modifiers: .command)
```

- [ ] **Step 2: Handle not-installed state in Memory sub-tab**

Move the `memoryInstallView` check inside the Memory sub-tab only (not the whole Extensions tab):
```swift
@ViewBuilder
private var memorySubView: some View {
    if !manager.memoryManager.isInstalled {
        memoryInstallView
    } else if manager.memoryManager.isLoading && manager.memoryManager.memories.isEmpty {
        VStack(spacing: 8) {
            ProgressView()
            Text("Loading memories...")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    } else {
        memoryContentInner
    }
}
```

Where `memoryContentInner` is the old memory content (stats + search + internal sub-tabs for Memories/Activity/Projects).

- [ ] **Step 3: Build full project**

Run: `xcodegen generate && xcodebuild -scheme SubMaxxing -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Test manually**

Run: `make run`
Verify:
- Extensions tab shows with Discover/Installed/Memory sub-tabs
- Discover shows all plugins sorted by popularity
- Search filters plugins
- Category chips filter plugins
- Install button works (installs via claude CLI)
- Installed tab shows installed plugins with toggle and uninstall
- Memory sub-tab works exactly as before

- [ ] **Step 5: Commit all remaining changes**

```bash
git add Sources/MenuBarView.swift Sources/UsageManager.swift
git commit -m "feat: complete Extensions tab integration with plugin marketplace"
```
