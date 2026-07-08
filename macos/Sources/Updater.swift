import AppKit
import Foundation

let updateRepo = "Jaybee4real/banshell"
let macInstallerAsset = "Banshell-macOS-Installer.pkg"

struct ReleaseInfo {
    let version: String
    let assetURL: URL
    let notes: String
}

enum UpdateOutcome {
    case upToDate
    case available(ReleaseInfo)
    case failed(String)
}

func parseVersion(_ text: String) -> [Int] {
    text.trimmingCharacters(in: CharacterSet(charactersIn: "v "))
        .split(separator: ".")
        .map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
}

func versionIsNewer(_ candidate: String, than current: String) -> Bool {
    let candidateParts = parseVersion(candidate)
    let currentParts = parseVersion(current)
    for index in 0..<max(candidateParts.count, currentParts.count) {
        let left = index < candidateParts.count ? candidateParts[index] : 0
        let right = index < currentParts.count ? currentParts[index] : 0
        if left != right { return left > right }
    }
    return false
}

final class Updater {
    static let shared = Updater()
    private var checking = false

    func fetchLatest() -> UpdateOutcome {
        guard let url = URL(string: "https://api.github.com/repos/\(updateRepo)/releases/latest") else {
            return .failed("bad url")
        }
        var request = URLRequest(url: url)
        request.setValue("BANSHELL-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        var outcome: UpdateOutcome = .failed("no response")
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            if let error {
                outcome = .failed(error.localizedDescription)
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                outcome = .failed("malformed response")
                return
            }
            let notes = json["body"] as? String ?? ""
            let assets = json["assets"] as? [[String: Any]] ?? []
            guard let asset = assets.first(where: { ($0["name"] as? String) == macInstallerAsset }),
                  let urlString = asset["browser_download_url"] as? String,
                  let assetURL = URL(string: urlString) else {
                outcome = .failed("no macOS installer attached to the latest release")
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if versionIsNewer(version, than: banshellVersion) {
                outcome = .available(ReleaseInfo(version: version, assetURL: assetURL, notes: notes))
            } else {
                outcome = .upToDate
            }
        }.resume()
        semaphore.wait()
        return outcome
    }

    func checkForUpdates(silent: Bool) {
        guard !checking else { return }
        checking = true
        DispatchQueue.global(qos: .utility).async {
            let outcome = self.fetchLatest()
            DispatchQueue.main.async {
                self.checking = false
                switch outcome {
                case .upToDate:
                    if !silent { self.showInfo("You're up to date", "BANSHELL v\(banshellVersion) is the latest version.") }
                case .available(let info):
                    self.promptUpdate(info)
                case .failed(let message):
                    if silent {
                        logLine("update check failed: \(message)")
                    } else {
                        self.showInfo("Couldn't check for updates", message)
                    }
                }
            }
        }
    }

    private func promptUpdate(_ info: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "Update available: v\(info.version)"
        var body = "You have v\(banshellVersion). Install v\(info.version) now? BANSHELL will briefly restart."
        let trimmedNotes = info.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            body += "\n\nWhat's new:\n" + String(trimmedNotes.prefix(500))
        }
        alert.informativeText = body
        alert.addButton(withTitle: "Install & Restart")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        downloadAndInstall(info)
    }

    private func downloadAndInstall(_ info: ReleaseInfo) {
        let progress = NSAlert()
        progress.messageText = "Downloading v\(info.version)…"
        progress.informativeText = "BANSHELL will restart to finish installing."
        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        indicator.isIndeterminate = true
        indicator.style = .bar
        indicator.startAnimation(nil)
        progress.accessoryView = indicator
        progress.addButton(withTitle: "Cancel")
        let progressWindow = progress.window
        NSApp.activate(ignoringOtherApps: true)
        progressWindow.makeKeyAndOrderFront(nil)

        DispatchQueue.global(qos: .userInitiated).async {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("Banshell-\(info.version).pkg")
            try? FileManager.default.removeItem(at: destination)
            var downloadError: String?
            let semaphore = DispatchSemaphore(value: 0)
            URLSession.shared.downloadTask(with: info.assetURL) { tempURL, _, error in
                defer { semaphore.signal() }
                if let error { downloadError = error.localizedDescription; return }
                guard let tempURL else { downloadError = "download produced no file"; return }
                do {
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                } catch {
                    downloadError = error.localizedDescription
                }
            }.resume()
            semaphore.wait()

            DispatchQueue.main.async {
                progressWindow.orderOut(nil)
                if let downloadError {
                    self.showInfo("Update failed", downloadError)
                    return
                }
                self.runInstaller(at: destination, version: info.version)
            }
        }
    }

    private func runInstaller(at path: URL, version: String) {
        let shell = "/usr/sbin/installer -pkg '\(path.path)' -target /"
        let source = "do shell script \"\(appleScriptEscaped(shell))\" with administrator privileges"
        logLine("installing update v\(version)")
        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
                if code != -128 {
                    let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "install failed"
                    DispatchQueue.main.async { self.showInfo("Update failed", message) }
                }
            }
        }
    }

    private func showInfo(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
