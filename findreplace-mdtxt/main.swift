//
//  main.swift
//  findreplace-mdtxt
//
//  Native Swift CLI: Recursive Find & Replace for .md/.txt
//  - Accepts Finder/Automator selection as CLI args (files and/or folders)
//  - If no args: asks user to choose a folder
//  - Processes only .md and .txt
//  - Recurses into all subfolders (skips hidden folders), and skips common repo/system junk dirs
//  - Preview + confirmation before writing
//
//  Created by Marcel Mißbach on 12.01.26.
//

import Foundation
import AppKit

// MARK: - Persisted History (last N runs)

/// Persist the last N find/replace inputs across runs.
/// We use an explicit suite name so persistence works even for a plain CLI without a bundle identifier.
struct HistoryStore {
    static let suiteName = "dev.marcel.findreplace-mdtxt"
    static let keyFind = "recentFind"
    static let keyReplace = "recentReplace"
    static let maxItems = 10

    private static var defaults: UserDefaults {
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func loadFinds() -> [String] {
        return (defaults.array(forKey: keyFind) as? [String]) ?? []
    }

    static func loadReplaces() -> [String] {
        return (defaults.array(forKey: keyReplace) as? [String]) ?? []
    }

    static func save(find: String, replace: String) {
        var finds = loadFinds()
        var replaces = loadReplaces()

        func insertMostRecent(_ value: String, into arr: inout [String], allowEmpty: Bool) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty && !allowEmpty { return }
            arr.removeAll(where: { $0 == v })
            arr.insert(v, at: 0)
            if arr.count > maxItems { arr = Array(arr.prefix(maxItems)) }
        }

        insertMostRecent(find, into: &finds, allowEmpty: false)
        insertMostRecent(replace, into: &replaces, allowEmpty: false) // leer ist erlaubt, aber Historie wäre sonst sinnlos

        defaults.set(finds, forKey: keyFind)
        defaults.set(replaces, forKey: keyReplace)
        defaults.synchronize()
    }

    static func clear() {
        defaults.removeObject(forKey: keyFind)
        defaults.removeObject(forKey: keyReplace)
        defaults.synchronize()
    }
}

// MARK: - AppleScript helpers (for simple dialogs)

struct AppleScript {
    static func escape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\r", with: "")
        return out
    }

    @discardableResult
    static func run(_ script: String) -> (exitCode: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        do {
            try p.run()
        } catch {
            return (127, "", "Failed to run osascript: \(error)")
        }

        p.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""

        return (p.terminationStatus, outStr.trimmingCharacters(in: .whitespacesAndNewlines), errStr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Confirm dialog. Returns true if okLabel was chosen.
    static func confirm(title: String, message: String, okLabel: String, cancelLabel: String) -> Bool {
        let t = escape(title)
        let m = escape(message)
        let ok = escape(okLabel)
        let cancel = escape(cancelLabel)

        let scpt = """
        try
            set theBtn to button returned of (display dialog "\(m)" with title "\(t)" buttons {"\(cancel)", "\(ok)"} default button "\(ok)" )
            return theBtn
        on error number -128
            return "__CANCEL__"
        end try
        """

        let (code, out, _) = run(scpt)
        if code != 0 { return false }
        if out == "__CANCEL__" { return false }
        return out == okLabel
    }

    static func info(title: String, message: String) {
        let t = escape(title)
        let m = escape(message)
        let scpt = """
        display dialog "\(m)" with title "\(t)" buttons {"OK"} default button "OK"
        """
        _ = run(scpt)
    }
}

// MARK: - Native UI (foreground + dialogs)

struct NativeUI {
    private static var didBootstrap = false

    /// One-time UI bootstrap for a CLI that still uses AppKit.
    /// Goals:
    /// - Avoid AppKit "window tab" indexing warnings for bundle-less CLIs.
    /// - Ensure a minimal menu exists (some AppKit UI behaves oddly without it).
    private static func bootstrapIfNeeded() {
        guard didBootstrap == false else { return }
        didBootstrap = true

        // Reduce noisy logs for bundle-less CLIs.
        NSWindow.allowsAutomaticWindowTabbing = false

        // Create a minimal application instance and menu.
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.finishLaunching()

        if NSApp.mainMenu == nil {
            let mainMenu = NSMenu()
            let appMenuItem = NSMenuItem()
            mainMenu.addItem(appMenuItem)

            let appMenu = NSMenu()
            let quitTitle = "Beenden \(ProcessInfo.processInfo.processName)"
            appMenu.addItem(withTitle: quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            appMenuItem.submenu = appMenu

            NSApp.mainMenu = mainMenu
        }
    }


    /// Best-effort foreground activation (important when launched via Automator/Workflow runner).
    /// IMPORTANT: Do not use System Events / AppleScript here; it can be slow/hang without Accessibility.
    private static func bringToFrontBestEffort() {
        bootstrapIfNeeded()

        // Unhide and activate.
        NSApp.unhide(nil)
        let opts: NSApplication.ActivationOptions
        if #available(macOS 14.0, *) {
            // macOS 14+: `activateIgnoringOtherApps` is deprecated and has no effect.
            opts = [.activateAllWindows]
        } else {
            opts = [.activateAllWindows, .activateIgnoringOtherApps]
        }
        _ = NSRunningApplication.current.activate(options: opts)
        // As an extra nudge for panel/key behavior.
        // NSApp.activate(ignoringOtherApps: true) // deprecated, but harmless and still helps on some systems
    }

    private static func ensureAppKitForeground() {
        bootstrapIfNeeded()
        bringToFrontBestEffort()
    }

    /// Re-activate and force a given window to the front. Needed for Automator/Quick Action launches
    /// where the first activation is sometimes ignored and windows appear behind Finder.
    private static func nudgeWindowToFront(_ window: NSWindow) {
        bringToFrontBestEffort()
        window.hidesOnDeactivate = false
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // A second nudge on the next runloop tick helps reliably when launched from WorkflowServiceRunner.
        DispatchQueue.main.async {
            bringToFrontBestEffort()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    /// Native folder chooser (German).
    static func chooseFolder() -> String? {
        bootstrapIfNeeded()
        bringToFrontBestEffort()

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false

        panel.showsHiddenFiles = false
        panel.setFrameAutosaveName("dev.marcel.findreplace-mdtxt.openpanel")

        // System is German -> rely on system localization.
        panel.title = "Ordner auswählen"
        panel.message = "" // kein erklärender Titeltext; verbessert Drag/Usability
        panel.prompt = "Auswählen"

        // Start somewhere sensible.
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        // Ensure we are truly frontmost when the panel appears.
        // When launched via Automator/Workflow runner, the first activation can be ignored,
        // so we nudge again on the next runloop tick and explicitly order the panel front.
        panel.hidesOnDeactivate = false
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            bringToFrontBestEffort()
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }

        let response = panel.runModal()
        if response == .OK {
            return panel.url?.path
        }
        return nil
    }

    // MARK: - Find/Replace Modal Window (more responsive than NSAlert accessory views)

    private final class FindReplaceWindowController: NSWindowController, NSWindowDelegate {
        private let findBox = NSComboBox()
        private let replaceBox = NSComboBox()
        private let infoLabel = NSTextField(labelWithString: "Nur .md/.txt • rekursiv • keine versteckten Ordner")
        private let scopeLabel = NSTextField(labelWithString: "")

        private(set) var result: (find: String, replace: String)? = nil

        override init(window: NSWindow?) {
            super.init(window: window)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func buildUI(title: String, scope: String) {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 260),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = title
            w.isReleasedWhenClosed = false
            w.center()
            w.hidesOnDeactivate = false
            w.collectionBehavior = [.moveToActiveSpace]
            w.delegate = self
            self.window = w

            let content = NSView()
            content.translatesAutoresizingMaskIntoConstraints = false
            w.contentView = content

            // Labels
            let findLabel = NSTextField(labelWithString: "Suchen nach")
            let replaceLabel = NSTextField(labelWithString: "Ersetzen durch")

            // Combo boxes
            findBox.isEditable = true
            findBox.usesDataSource = false
            findBox.completes = true
            findBox.placeholderString = "z. B. alter Text"

            replaceBox.isEditable = true
            replaceBox.usesDataSource = false
            replaceBox.completes = true
            replaceBox.placeholderString = "leer = entfernen"

            // History
            let recentFinds = HistoryStore.loadFinds()
            let recentReplaces = HistoryStore.loadReplaces()
            findBox.removeAllItems()
            replaceBox.removeAllItems()
            findBox.addItems(withObjectValues: recentFinds)
            replaceBox.addItems(withObjectValues: recentReplaces)
            if let first = recentFinds.first { findBox.stringValue = first }
            if let first = recentReplaces.first { replaceBox.stringValue = first }

            // Ensure fields expand to full window width
            findBox.translatesAutoresizingMaskIntoConstraints = false
            replaceBox.translatesAutoresizingMaskIntoConstraints = false
            findBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
            replaceBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
            findBox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            replaceBox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            // Buttons
            let okButton = NSButton(title: "OK", target: self, action: #selector(okPressed))
            okButton.keyEquivalent = "\r"
            let cancelButton = NSButton(title: "Abbrechen", target: self, action: #selector(cancelPressed))
            cancelButton.keyEquivalent = "\u{1b}"
            let clearButton = NSButton(title: "Historie löschen", target: self, action: #selector(clearHistoryPressed))

            // Key-View-Loop: TAB wechselt zuverlässig zwischen den Feldern
            findBox.nextKeyView = replaceBox
            replaceBox.nextKeyView = okButton
            okButton.nextKeyView = cancelButton
            cancelButton.nextKeyView = findBox

            let buttonRow = NSStackView(views: [clearButton, NSView(), cancelButton, okButton])
            buttonRow.orientation = .horizontal
            buttonRow.alignment = .centerY
            buttonRow.distribution = .fill
            buttonRow.spacing = 10
            buttonRow.translatesAutoresizingMaskIntoConstraints = false

            infoLabel.textColor = .secondaryLabelColor
            infoLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

            // Scope / target folder (helps when the tool is started twice via Quick Action)
            let trimmedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedScope.isEmpty {
                scopeLabel.stringValue = ""
                scopeLabel.isHidden = true
            } else {
                scopeLabel.stringValue = "Ordner: \(trimmedScope)"
                scopeLabel.isHidden = false
            }
            scopeLabel.textColor = .secondaryLabelColor
            scopeLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            scopeLabel.lineBreakMode = .byWordWrapping
            scopeLabel.maximumNumberOfLines = 3
            scopeLabel.translatesAutoresizingMaskIntoConstraints = false
            scopeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            scopeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let stack = NSStackView(views: [findLabel, findBox, replaceLabel, replaceBox, infoLabel, scopeLabel, buttonRow])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.distribution = .fill
            stack.spacing = 10
            stack.translatesAutoresizingMaskIntoConstraints = false

            content.addSubview(stack)

            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),

                // Full-width inputs
                findBox.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                findBox.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
                replaceBox.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                replaceBox.trailingAnchor.constraint(equalTo: stack.trailingAnchor),

                // Full-width scope label
                scopeLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                scopeLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),

                // Button row full width
                buttonRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                buttonRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            ])

            w.initialFirstResponder = findBox
        }

        @objc private func okPressed() {
            let find = findBox.stringValue
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard find.isEmpty == false else {
                NSSound.beep()
                window?.makeFirstResponder(findBox)
                return
            }

            let replace = replaceBox.stringValue
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")

            HistoryStore.save(find: find, replace: replace)
            result = (find: find, replace: replace)

            if let w = window { NSApp.stopModal() ; w.close() }
        }

        @objc private func cancelPressed() {
            result = nil
            if let w = window { NSApp.stopModal() ; w.close() }
        }

        @objc private func clearHistoryPressed() {
            HistoryStore.clear()
            findBox.removeAllItems()
            replaceBox.removeAllItems()
            findBox.stringValue = ""
            replaceBox.stringValue = ""
            window?.makeFirstResponder(findBox)
        }

        func windowWillClose(_ notification: Notification) {
            // Fenster schließt (auch via Titelleiste). Modal-Loop beenden,
            // aber `result` NICHT überschreiben – sonst geht ein zuvor gesetztes OK-Ergebnis verloren.
            if NSApp.modalWindow != nil {
                NSApp.stopModal()
            }
        }
    }

    /// One dialog with two fields + history + button to clear history.
    /// Implemented as a custom modal window for responsiveness.
    static func promptFindReplace(title: String, scope: String) -> (find: String, replace: String)? {
        ensureAppKitForeground()

        let wc = FindReplaceWindowController(window: nil)
        wc.buildUI(title: title, scope: scope)

        guard let w = wc.window else { return nil }

        // Show + activate before entering modal loop.
        nudgeWindowToFront(w)

        NSApp.runModal(for: w)
        return wc.result
    }
}

// Helper to create a compact, user-friendly scope string
func scopeDescription(for selectionArgs: [String]) -> String {
    let fm = FileManager.default

    var dirs: [String] = []
    var files: [String] = []

    for a in selectionArgs {
        let path = (a as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue {
                dirs.append(url.standardizedFileURL.path)
            } else {
                files.append(url.standardizedFileURL.path)
            }
        }
    }

    func tilde(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }

    if dirs.count == 1 && files.isEmpty {
        return tilde(dirs[0])
    }

    if dirs.isEmpty == false {
        let first = tilde(dirs[0])
        if dirs.count == 1 && files.isEmpty == false {
            return "\(first) (+\(files.count) Dateien)"
        }
        if dirs.count > 1 && files.isEmpty {
            return "\(first) (+\(dirs.count - 1) weitere)"
        }
        if dirs.count > 1 && files.isEmpty == false {
            return "\(first) (+\(dirs.count - 1) Ordner, \(files.count) Dateien)"
        }
        return first
    }

    if files.count == 1 {
        let parent = URL(fileURLWithPath: files[0]).deletingLastPathComponent().standardizedFileURL.path
        return tilde(parent)
    }

    if files.count > 1 {
        let parents = Set(files.map { URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.path })
        if parents.count == 1, let only = parents.first {
            return tilde(only)
        }
        return "Mehrere Ordner (\(files.count) Dateien)"
    }

    return ""
}

// MARK: - Core logic

let allowedExtensions: Set<String> = ["md", "txt"]

let excludedDirNames: Set<String> = [
    ".git",
    "__MACOSX",
    ".Spotlight-V100",
    ".Trashes",
    ".fseventsd",
    "DerivedData",
    "xcuserdata",
    ".build",
    "build",
    "Index.noindex",
    "Codex Reports",
    "node_modules",
    ".swiftpm"
]

func normalizeExt(_ url: URL) -> String {
    return url.pathExtension.lowercased()
}

func isAllowedFile(_ url: URL) -> Bool {
    guard url.hasDirectoryPath == false else { return false }
    return allowedExtensions.contains(normalizeExt(url))
}

func shouldSkipDirectory(named name: String) -> Bool {
    return excludedDirNames.contains(name)
}

func enumerateFilesRecursively(root: URL) -> [URL] {
    let fm = FileManager.default
    var urls: [URL] = []

    let options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]

    guard let enumerator = fm.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .nameKey, .isHiddenKey],
        options: options,
        errorHandler: { _, _ in true }
    ) else {
        return []
    }

    for case let item as URL in enumerator {
        do {
            let rv = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .nameKey, .isHiddenKey])
            if rv.isDirectory == true {
                let name = rv.name ?? item.lastPathComponent

                if (rv.isHidden == true) || name.hasPrefix(".") {
                    enumerator.skipDescendants()
                    continue
                }

                if shouldSkipDirectory(named: name) {
                    enumerator.skipDescendants()
                }
                continue
            }

            if (rv.isHidden == true) || item.lastPathComponent.hasPrefix(".") {
                continue
            }

            if rv.isRegularFile == true, isAllowedFile(item) {
                urls.append(item)
            }
        } catch {
            continue
        }
    }

    return urls
}

func collectTargets(from args: [String]) -> [URL] {
    let fm = FileManager.default
    var targets: [URL] = []

    for a in args {
        let path = (a as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue {
                targets.append(contentsOf: enumerateFilesRecursively(root: url))
            } else {
                if isAllowedFile(url) { targets.append(url) }
            }
        }
    }

    var seen = Set<String>()
    var out: [URL] = []
    for u in targets {
        let key = u.standardizedFileURL.path
        if seen.insert(key).inserted {
            out.append(u)
        }
    }
    return out
}

func countOccurrences(haystack: String, needle: String) -> Int {
    if needle.isEmpty { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let r = haystack.range(of: needle, options: [], range: searchRange) {
        count += 1
        searchRange = r.upperBound..<haystack.endIndex
    }
    return count
}

struct MatchInfo {
    let url: URL
    let matches: Int
    let encoding: String.Encoding
    let original: String
}

func readStringWithEncoding(url: URL) -> (text: String, enc: String.Encoding)? {
    var usedEnc: String.Encoding = .utf8
    do {
        let text = try String(contentsOf: url, usedEncoding: &usedEnc)
        return (text, usedEnc)
    } catch {
        for enc in [String.Encoding.utf8, .macOSRoman, .isoLatin1] {
            if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: enc) {
                return (text, enc)
            }
        }
        return nil
    }
}

func writeString(url: URL, text: String, encoding: String.Encoding) throws {
    try text.write(to: url, atomically: true, encoding: encoding)
}

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())

var selectionArgs = args
if selectionArgs.isEmpty {
    if let chosen = NativeUI.chooseFolder() {
        selectionArgs = [chosen]
    } else {
        exit(0)
    }
}

let targets = collectTargets(from: selectionArgs)

let title = "Suchen & Ersetzen (MD/TXT)"

if targets.isEmpty {
    AppleScript.info(title: title, message: "Keine .md/.txt-Dateien gefunden (oder Auswahl enthielt keine passenden Dateien/Ordner).")
    exit(0)
}

let scopeText = scopeDescription(for: selectionArgs)

guard let (search, replaceWith) = NativeUI.promptFindReplace(title: title, scope: scopeText) else {
    exit(0)
}

// Scan for matches first
var matches: [MatchInfo] = []
var unreadable: [URL] = []

for url in targets {
    guard let (text, enc) = readStringWithEncoding(url: url) else {
        unreadable.append(url)
        continue
    }

    let c = countOccurrences(haystack: text, needle: search)
    if c > 0 {
        matches.append(MatchInfo(url: url, matches: c, encoding: enc, original: text))
    }
}

if matches.isEmpty {
    var msg = "Keine Treffer für: \"\(search)\"\n\nDurchsuchte Dateien: \(targets.count)"
    if unreadable.isEmpty == false {
        msg += "\nNicht lesbar: \(unreadable.count)"
    }
    AppleScript.info(title: title, message: msg)
    exit(0)
}

let totalMatches = matches.reduce(0) { $0 + $1.matches }

// Build preview list
let maxLines = 150
let sortedMatches = matches.sorted { a, b in
    if a.matches != b.matches { return a.matches > b.matches }
    return a.url.path < b.url.path
}

var lines: [String] = []
for mi in sortedMatches.prefix(maxLines) {
    lines.append("(\(mi.matches)x) \(mi.url.path)")
}

var preview = lines.joined(separator: "\n")
if sortedMatches.count > maxLines {
    preview += "\n… (+\(sortedMatches.count - maxLines) weitere Dateien)"
}

var confirmMsg = "Suchen nach: \"\(search)\"\nErsetzen durch: \"\(replaceWith)\"\n\nDateien mit Treffern: \(matches.count)\nGesamttreffer: \(totalMatches)\n\nÄnderungen betreffen:\n\n\(preview)"
if unreadable.isEmpty == false {
    confirmMsg += "\n\nHinweis: \(unreadable.count) Dateien konnten nicht gelesen werden und werden ignoriert."
}

let ok = AppleScript.confirm(
    title: title,
    message: confirmMsg,
    okLabel: "Alles ersetzen",
    cancelLabel: "Abbrechen"
)

if ok == false {
    exit(0)
}

// Perform replacements
var changedFiles = 0
var writtenMatches = 0
var writeErrors: [String] = []

for mi in matches {
    let newText = mi.original.replacingOccurrences(of: search, with: replaceWith)
    if newText != mi.original {
        do {
            try writeString(url: mi.url, text: newText, encoding: mi.encoding)
            changedFiles += 1
            writtenMatches += mi.matches
        } catch {
            writeErrors.append("\(mi.url.path): \(error)")
        }
    }
}

var doneMsg = "Fertig.\n\nGeänderte Dateien: \(changedFiles)\nErsetzungen: \(writtenMatches)"
if writeErrors.isEmpty == false {
    let head = writeErrors.prefix(10).joined(separator: "\n")
    doneMsg += "\n\nSchreibfehler: \(writeErrors.count)\n\(head)"
    if writeErrors.count > 10 {
        doneMsg += "\n…"
    }
}

AppleScript.info(title: title, message: doneMsg)
exit(0)
