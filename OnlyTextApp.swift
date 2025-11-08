//
//  OnlyTextApp.swift
//  OnlyText
//
//  Created by Larry Titus on 9/28/25
//  Last Updated 08-Nov-2025
//  Version 1.2
//
//  Overview:
//  - Menu bar–only macOS app (no Dock icon, no Cmd-Tab entry).
//  - Watches the system pasteboard and converts rich text (RTF/HTML) to plain text
//    when enabled.
//  - Leaves images and other non-text/binary clipboard content untouched.
//  - Preserves line feeds / line breaks / carriage returns (maps U+2028/U+2029 to \n).
//  - Shows a small version label in the popover footer (“OnlyText vX.Y”).
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers   // Used to detect whether clipboard items are textual or binary.

// MARK: - Version Helper
/// Reads the human-facing app version from Info.plist (CFBundleShortVersionString)
/// and formats it as "vX.Y". Update the Version in the target settings to change it.
struct AppInfo {
    static var versionTag: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "v\(v)"
    }
}

// MARK: - App Entry
@main
struct OnlyTextApp: App {
    // Hook in an NSApplication delegate to configure app-wide behaviors at launch.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // MenuBarExtra creates a status item (menu bar icon) with a popover.
        MenuBarExtra("OnlyText", systemImage: "doc.on.clipboard") {
            // --- Popover content ---
            SettingsView()               // Single toggle: Enable Plain-Text by Default
                .frame(width: 320)

            Divider()

            // Manual action to run a cleanup on the current clipboard contents.
            Button("Clean Clipboard Now") {
                PasteboardMonitor.shared.cleanClipboardIfNeeded(force: true)
            }

            Divider()

            // Quit the app (terminates immediately).
            Button("Quit") { NSApplication.shared.terminate(nil) }
            // (no padding here by request)

            // Version footer: small, subtle label at the bottom with padding.
            Divider()
            HStack {
                Spacer()
                Text("OnlyText \(AppInfo.versionTag)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 8)
            // --- End popover content ---
        }
        .menuBarExtraStyle(.window) // Gives a small window-like popover instead of a plain menu.
    }
}

// MARK: - App Delegate
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make this a true menu-bar utility (no Dock icon, not shown in Cmd-Tab).
        NSApp.setActivationPolicy(.accessory)

        // First-run default: Enabled = true (so behavior works immediately).
        UserDefaults.standard.register(defaults: [
            "enabled": true
        ])

        // Start the pasteboard monitor and immediately process the current clipboard,
        // so rich text already on the clipboard is handled without user interaction.
        PasteboardMonitor.shared.start()
        PasteboardMonitor.shared.cleanClipboardIfNeeded(force: false)
    }
}

// MARK: - Settings View (single toggle)
/// Minimal settings: only the "plain text by default" enable/disable toggle.
struct SettingsView: View {
    // Persist the toggle in UserDefaults automatically.
    @AppStorage("enabled") private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Main feature toggle.
            Toggle("Enable Plain-Text by Default", isOn: $enabled)
                .toggleStyle(.switch)
                .font(.headline)

            // Short description of what the app does and what it intentionally ignores.
            GroupBox("About") {
                Text("When enabled, copied rich text (RTF/HTML) is automatically converted to plain text on the clipboard. Images/files are left alone. Items marked as Transient/Concealed (e.g., from password managers) are ignored.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

// MARK: - Pasteboard Monitor
/// Listens for clipboard (pasteboard) changes and ensures text is plain when enabled.
final class PasteboardMonitor {
    static let shared = PasteboardMonitor()

    private let pb = NSPasteboard.general
    private var changeCount: Int = NSPasteboard.general.changeCount  // Tracks the last seen pasteboard change number.
    private var timer: Timer?                                        // Polls the pasteboard for changes.

    // Pasteboard hints used by some apps (e.g., password managers).
    // We skip these to avoid touching sensitive/ephemeral clipboard items.
    private let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

    private init() {}

    /// Start polling the pasteboard for changes.
    func start() {
        timer?.invalidate()
        // Poll 4x/second. (You can reduce/increase this if needed.)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.check()
        }
        if let timer { RunLoop.current.add(timer, forMode: .common) }
    }

    /// Called periodically to see if the pasteboard changed.
    private func check() {
        // Feature can be toggled off by the user.
        guard UserDefaults.standard.bool(forKey: "enabled") else { return }

        let currentChange = pb.changeCount
        // Only act when the pasteboard actually changed.
        if currentChange != changeCount {
            changeCount = currentChange
            cleanClipboardIfNeeded(force: false)
        }
    }

    /// Convert rich text to plain text, but only when it’s safe:
    /// - Skip password-manager-like entries (Transient/Concealed/AutoGenerated).
    /// - Leave clipboard untouched if ANY item is non-text/binary (images, PDFs, file URLs, etc.).
    /// - If items are textual (RTF/HTML/plain), convert to plain text.
    func cleanClipboardIfNeeded(force: Bool) {
        // Respect Transient/Concealed/AutoGenerated items (commonly used for secure clipboards).
        if pb.types?.contains(where: { $0 == transientType || $0 == concealedType || $0 == autoGeneratedType }) == true, !force {
            return
        }

        guard let items = pb.pasteboardItems, !items.isEmpty else { return }

        // If ANY pasteboard item declares a non-textual UTType, we do nothing to preserve it.
        // This avoids accidentally stripping images or binary data when apps put multiple
        // representations on the clipboard.
        let hasNonTextual: Bool = items.contains { item in
            item.types.contains { t in
                let raw = t.rawValue

                // Ignore NSPasteboard internal helper types.
                if raw.hasPrefix("org.nspasteboard.") { return false }

                // If we can form a UTType, check if it conforms to text or matches common text flavors.
                if let ut = UTType(raw) {
                    // Treat .text, .rtf, .html, and .url as textual; everything else = non-textual.
                    return !(ut.conforms(to: .text) || ut == .rtf || ut == .html || ut == .url)
                } else {
                    // Fallback if UTType init fails: allow standard text flavors only.
                    return !(t == .string || t == .rtf || t == .html)
                }
            }
        }
        if hasNonTextual { return }  // Preserve clipboard as-is.

        // All items are textual: convert any rich text to plain text.
        for item in items {
            if let plain = extractPlainText(from: item) {
                pb.clearContents()
                pb.setString(plain, forType: .string)

                // Update changeCount to avoid immediately re-processing the write we just did.
                changeCount = pb.changeCount
                return
            }
        }
        // If we got here, either everything was already plain text or we couldn't extract text.
        // In either case, do nothing further.
    }

    /// Extracts a plain-string representation from a rich pasteboard item, if possible.
    /// - Preserves line breaks: converts U+2028/U+2029 to "\n", leaves "\n" and "\r" untouched.
    /// - Returns: The plain text for RTF/HTML items; `nil` if item is already plain text (or unsupported).
    private func extractPlainText(from item: NSPasteboardItem) -> String? {
        // Prefer decoding RTF to preserve content while stripping formatting.
        if let rtfData = item.data(forType: .rtf),
           let attr = try? NSAttributedString(
               data: rtfData,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            return preserveLineBreaks(attr.string)
        }

        // Fallback: decode HTML payload to text.
        if let htmlData = item.data(forType: .html),
           let attr = try? NSAttributedString(
               data: htmlData,
               options: [.documentType: NSAttributedString.DocumentType.html],
               documentAttributes: nil
           ) {
            return preserveLineBreaks(attr.string)
        }

        // If the item already includes a plain string flavor, we don't need to modify the clipboard.
        if item.string(forType: .string) != nil { return nil }

        // Not a known text representation we handle → leave unchanged.
        return nil
    }

    // MARK: - Line break preservation
    /// Ensures line separators are retained when converting attributed text to plain text.
    /// - We map Unicode line/paragraph separators (U+2028/U+2029) to "\n".
    /// - We leave existing "\n" and "\r" untouched to avoid altering platform-specific line endings.
    private func preserveLineBreaks(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\u{2028}", with: "\n") // line separator → LF
        out = out.replacingOccurrences(of: "\u{2029}", with: "\n") // paragraph separator → LF
        return out
    }
}
