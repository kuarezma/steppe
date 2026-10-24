import Foundation

/// Installs Steppe's replacement audio libraries and optional notch HUD into the game folder.
///
/// A file is only replaced while it is still the unmodified original shipped by the game; a backup
/// is kept as `<name>.steppe-orig`. If Steam updates or verifies the game the originals come back
/// and are replaced again on the next launch.
public enum GameFiles {
    public static let libraryNames = ["ogg.dll", "vorbis.dll", "vorbisfile.dll"]

    public enum Status: Equatable, Sendable {
        case installed(String)
        case alreadyCurrent(String)
        case skippedUnknownFile(String)
        case missing(String)
    }

    /// Sidecar file recording the SHA-256 of every library Steppe installed, so a newer Steppe can tell its own
    /// older files apart from a modified or updated game file.
    static let installedRecordName = ".steppe-audio-installed.json"

    private static func readInstalledRecord(in gameDir: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: gameDir.appendingPathComponent(installedRecordName)),
              let record = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return record
    }

    private static func writeInstalledRecord(_ record: [String: String], in gameDir: URL) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: gameDir.appendingPathComponent(installedRecordName), options: .atomic)
    }

    public static func installSpeedLibraries(from sourceDir: URL, into gameDir: URL, knownOriginals: [String: String]) -> [Status] {
        let fm = FileManager.default
        var results: [Status] = []
        var record = readInstalledRecord(in: gameDir)
        for name in libraryNames {
            let source = sourceDir.appendingPathComponent(name)
            let target = gameDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path), let ours = try? Hashing.sha256(of: source) else {
                results.append(.missing(name))
                continue
            }
            guard fm.fileExists(atPath: target.path), let current = try? Hashing.sha256(of: target) else {
                results.append(.missing(name))
                continue
            }
            if current == ours {
                record[name] = ours
                results.append(.alreadyCurrent(name))
                continue
            }
            // Replace only the verified original, or a file we installed ourselves earlier (an older Steppe).
            let isOriginal = knownOriginals[name] == current
            let isOurOlderFile = record[name] == current
            guard isOriginal || isOurOlderFile else {
                results.append(.skippedUnknownFile(name))
                continue
            }
            let backup = target.appendingPathExtension("steppe-orig")
            do {
                if isOriginal, !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: target, to: backup) }
                let staged = target.appendingPathExtension("steppe-new")
                try? fm.removeItem(at: staged)
                try fm.copyItem(at: source, to: staged)
                try replaceFile(at: target, with: staged)
                record[name] = ours
                results.append(.installed(name))
            } catch {
                Log.shared.error("Could not install \(name): \(error.localizedDescription)")
                results.append(.skippedUnknownFile(name))
            }
        }
        writeInstalledRecord(record, in: gameDir)
        return results
    }


    public static let hudMatRelativePath = "data/hud/hud.mat"
    public static let resourcePanelRelativePath = "data/gui/menu.inc/showresourcepanel.inc"

    private static let resourceBackground = #"""
    section.begin {refurl=.\data\hud\ref\reflibmat.mat}
       Material.Name = resourcepanel.background
       Material.LibTextureName = tex03
       Material.TextureCoord.ImageH = 512
       Material.TextureCoord.CoordX = 386
       Material.TextureCoord.CoordY = 183
       Material.TextureCoord.CoordW = 1159
       Material.TextureCoord.CoordH = 58
    section.end
    """#

    private static let resourcePanelOriginal = """
          [*] = ;if ((GetViewerWidth)<1260) then
          [*] = ;dpiscale := GetViewerWidth/1260;
          [*] = ;var elmParent : Integer = _gui_CreateParent(elmname, 0, gc_halParentLeft, gc_valParentTop, 0, 0, round(GetViewerWidth/dpiscale), GetGUITextureHeight('resourcepanel.background'), True);
          [*] = ;_gui_AbsScaleByDPI(elmParent);
          [*] = ;_gui_SetAbsScale(elmParent, dpiscale);
          [*] = ;SetGUIElementVisible(elmParent, (gInterface.gamemode<>gc_gamemode_mainmenu));
          [*] = ;var xoff : Integer;
          [*] = ;if ((GetViewerWidth/basedpiscale)<cminwidth) then
          [*] = ;xoff := round(-45*dpiscale)
          [*] = ;else
          [*] = ;if ((GetViewerWidth/basedpiscale)<1440) then
          [*] = ;xoff := -100;
          [*] = ;var elm : Integer = _gui_CreateImageActive('resbackground', elmParent, 'resourcepanel.background', gc_halParentMiddle, gc_valParentTop, xoff, cResourceOffY, 0, 0, 0, '', '', True);
    """

    private static let resourcePanelSplit = """
          [*] = ;var bNotchSplit : Boolean = (((GetViewerWidth/GetViewerHeight)>1.50) and ((GetViewerWidth/GetViewerHeight)<1.58));
          [*] = ;if (bNotchSplit) and ((GetViewerWidth/dpiscale)<1470) then
          [*] = ;dpiscale := GetViewerWidth/1470
          [*] = ;else
          [*] = ;if ((GetViewerWidth)<1260) then
          [*] = ;dpiscale := GetViewerWidth/1260;
          [*] = ;var parentW : Integer = round(GetViewerWidth/dpiscale);
          [*] = ;var elmParent : Integer = _gui_CreateParent(elmname, 0, gc_halParentLeft, gc_valParentTop, 0, 0, parentW, GetGUITextureHeight('resourcepanel.background'), True);
          [*] = ;_gui_AbsScaleByDPI(elmParent);
          [*] = ;_gui_SetAbsScale(elmParent, dpiscale);
          [*] = ;SetGUIElementVisible(elmParent, (gInterface.gamemode<>gc_gamemode_mainmenu));
          [*] = ;var xoff : Integer;
          [*] = ;if (not bNotchSplit) then
          [*] = ;begin
          [*] = ;   if ((GetViewerWidth/basedpiscale)<cminwidth) then
          [*] = ;   xoff := round(-45*dpiscale)
          [*] = ;   else
          [*] = ;   if ((GetViewerWidth/basedpiscale)<1440) then
          [*] = ;   xoff := -100;
          [*] = ;end;
          [*] = ;var notchHalfGap : Integer = 0;
          [*] = ;var notchLeftShift : Integer = 0;
          [*] = ;var notchRightShift : Integer = 0;
          [*] = ;if (bNotchSplit) then
          [*] = ;begin
          [*] = ;   notchHalfGap := round(parentW*0.068);
          [*] = ;   notchLeftShift := -notchHalfGap-31;
          [*] = ;   notchRightShift := notchHalfGap-31;
          [*] = ;end;
          [*] = ;var elmL : Integer = _gui_CreateImageActive('resbackground_l', elmParent, 'resourcepanel.background.left', gc_halParentMiddle, gc_valParentTop, xoff-275+notchLeftShift, cResourceOffY, 0, 0, 0, '', '', True);
          [*] = ;var elmR : Integer = _gui_CreateImageActive('resbackground_r', elmParent, 'resourcepanel.background.right', gc_halParentMiddle, gc_valParentTop, xoff+305+notchRightShift, cResourceOffY, 0, 0, 0, '', '', True);
    """

    private static let resourceOffsetsOriginal = """
          [*] = ;   const cSideOffsetX = -10;
          [*] = ;   if (i<4) then
          [*] = ;   x := x+(cSideOffsetX div 2)
          [*] = ;   else
          [*] = ;   x := x+cSideOffsetX+4;
    """

    private static let resourceOffsetsSplit = """
          [*] = ;   const cSideOffsetX = -10;
          [*] = ;   if (i<4) then
          [*] = ;   x := x+(cSideOffsetX div 2)+notchLeftShift
          [*] = ;   else
          [*] = ;   x := x+cSideOffsetX+4+notchRightShift;
    """

    /// Validate both originals before touching either file; backups are only reused when `target` still matches
    /// either the backup or our previously installed patch (recorded in `.steppe-audio-installed.json`), so a
    /// Steam update or a user-modified file is never overwritten by a stale backup.
    public static func applyNotchHUD(in gameDir: URL, enabled: Bool) -> [Status] {
        let fm = FileManager.default
        let paths = [hudMatRelativePath, resourcePanelRelativePath]
        var record = readInstalledRecord(in: gameDir)
        if !enabled {
            defer { writeInstalledRecord(record, in: gameDir) }
            return paths.map { path in
                let target = gameDir.appendingPathComponent(path)
                let backup = target.appendingPathExtension("steppe-orig")
                guard fm.fileExists(atPath: backup.path) else { return .alreadyCurrent(path) }
                let currentHash = try? Hashing.sha256(of: target)
                let backupHash = try? Hashing.sha256(of: backup)
                // Only restore if target is still our patched file (or identical to backup). If Steam updated target,
                // discard the stale backup and keep the new target untouched.
                if let currentHash, currentHash != record[path], currentHash != backupHash {
                    try? fm.removeItem(at: backup)
                    record.removeValue(forKey: path)
                    return .alreadyCurrent(path)
                }
                do {
                    try replaceFile(at: target, with: backup)
                    record.removeValue(forKey: path)
                    return .installed(path)
                } catch {
                    Log.shared.error("Could not restore \(path): \(error.localizedDescription)")
                    return .skippedUnknownFile(path)
                }
            }
        }

        // The 1159px resource bar texture has its asymmetric center between Stone (slot 3) and Gold (slot 4) at x=610
        // (+30.5px right of the 579.5px texture midpoint), hence the -31px centering offset on both halves.
        let left = resourceBackground
            .replacingOccurrences(of: "resourcepanel.background", with: "resourcepanel.background.left")
            .replacingOccurrences(of: "CoordW = 1159", with: "CoordW = 610")
        let right = resourceBackground
            .replacingOccurrences(of: "resourcepanel.background", with: "resourcepanel.background.right")
            .replacingOccurrences(of: "CoordX = 386", with: "CoordX = 996")
            .replacingOccurrences(of: "CoordW = 1159", with: "CoordW = 549")
        let replacements = [
            [(resourceBackground, [resourceBackground, left, right].joined(separator: "\n"))],
            [(resourcePanelOriginal, resourcePanelSplit), (resourceOffsetsOriginal, resourceOffsetsSplit)],
        ]
        var patchedFiles: [Data] = []
        var refreshBackup = [false, false]
        for (index, path) in paths.enumerated() {
            let target = gameDir.appendingPathComponent(path)
            let backup = target.appendingPathExtension("steppe-orig")
            guard fm.fileExists(atPath: target.path), let currentHash = try? Hashing.sha256(of: target) else {
                return [.missing(path)]
            }
            let hasValidBackup = fm.fileExists(atPath: backup.path)
                && (currentHash == record[path] || currentHash == (try? Hashing.sha256(of: backup)))
            let base = hasValidBackup ? backup : target
            refreshBackup[index] = !hasValidBackup
            guard let data = try? Data(contentsOf: base),
                  var content = String(data: data, encoding: .isoLatin1) else {
                return [.skippedUnknownFile(path)]
            }
            if index == 0, content.contains("Material.Name = resourcepanel.background.left")
                || content.contains("Material.Name = resourcepanel.background.right") {
                return [.skippedUnknownFile(path)]
            }
            let newline = content.contains("\r\n") ? "\r\n" : "\n"
            for (original, replacement) in replacements[index] {
                let expected = original.replacingOccurrences(of: "\n", with: newline)
                guard content.components(separatedBy: expected).count == 2 else {
                    return [.skippedUnknownFile(path)]
                }
                content = content.replacingOccurrences(of: expected, with: replacement.replacingOccurrences(of: "\n", with: newline))
            }
            guard let patched = content.data(using: .isoLatin1) else { return [.skippedUnknownFile(path)] }
            patchedFiles.append(patched)
        }

        var statuses: [Status] = []
        for (index, path) in paths.enumerated() {
            let target = gameDir.appendingPathComponent(path)
            let backup = target.appendingPathExtension("steppe-orig")
            let patchedHash = Hashing.sha256(of: patchedFiles[index])
            if !refreshBackup[index], fm.fileExists(atPath: backup.path), (try? Data(contentsOf: target)) == patchedFiles[index] {
                record[path] = patchedHash
                statuses.append(.alreadyCurrent(path))
                continue
            }
            let staged = target.appendingPathExtension("steppe-new-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staged) }
            do {
                if refreshBackup[index] || !fm.fileExists(atPath: backup.path) {
                    try? fm.removeItem(at: backup)
                    try fm.copyItem(at: target, to: backup)
                }
                try patchedFiles[index].write(to: staged)
                try replaceFile(at: target, with: staged)
                record[path] = patchedHash
                statuses.append(.installed(path))
            } catch {
                Log.shared.error("Could not patch \(path): \(error.localizedDescription)")
                // Roll back any earlier file patched in this call so hud.mat and showresourcepanel.inc stay consistent.
                for prevIndex in 0..<index {
                    let prevPath = paths[prevIndex]
                    let prevTarget = gameDir.appendingPathComponent(prevPath)
                    let prevBackup = prevTarget.appendingPathExtension("steppe-orig")
                    if fm.fileExists(atPath: prevBackup.path), (try? replaceFile(at: prevTarget, with: prevBackup)) != nil {
                        record.removeValue(forKey: prevPath)
                    }
                }
                writeInstalledRecord(record, in: gameDir)
                return [.skippedUnknownFile(path)]
            }
        }
        writeInstalledRecord(record, in: gameDir)
        return statuses
    }

    /// Puts the original libraries and HUD files back (used by "Restore original game files").
    @discardableResult
    public static func restoreOriginals(in gameDir: URL) -> Int {
        let fm = FileManager.default
        var restored = 0
        var record = readInstalledRecord(in: gameDir)
        let hudPaths = Set([hudMatRelativePath, resourcePanelRelativePath])
        for name in libraryNames + [hudMatRelativePath, resourcePanelRelativePath] {
            let target = gameDir.appendingPathComponent(name)
            let backup = target.appendingPathExtension("steppe-orig")
            guard fm.fileExists(atPath: backup.path) else { continue }
            if hudPaths.contains(name),
               let currentHash = try? Hashing.sha256(of: target),
               currentHash != record[name],
               currentHash != (try? Hashing.sha256(of: backup)) {
                try? fm.removeItem(at: backup)
                record.removeValue(forKey: name)
                continue
            }
            if (try? replaceFile(at: target, with: backup)) != nil {
                record.removeValue(forKey: name)
                restored += 1
            }
        }
        writeInstalledRecord(record, in: gameDir)
        return restored
    }

    /// Atomic replace where the volume supports it; exFAT and similar volumes can reject it (ENOTSUP),
    /// so fall back to a rollback-safe move that preserves `target` if moving `source` fails.
    static func replaceFile(at target: URL, with source: URL) throws {
        let fm = FileManager.default
        do {
            _ = try fm.replaceItemAt(target, withItemAt: source)
        } catch {
            guard fm.fileExists(atPath: source.path) else { throw error }
            let rollback = target.appendingPathExtension("steppe-rollback-\(UUID().uuidString)")
            let hadTarget = fm.fileExists(atPath: target.path)
            if hadTarget { try fm.moveItem(at: target, to: rollback) }
            do {
                try fm.moveItem(at: source, to: target)
                if hadTarget { try? fm.removeItem(at: rollback) }
            } catch let moveError {
                if hadTarget, !fm.fileExists(atPath: target.path) {
                    try? fm.moveItem(at: rollback, to: target)
                }
                throw moveError
            }
        }
    }
}


/// Summary of the speed-patch log written by the replacement audio library.
public struct PatchReport: Equatable, Sendable {
    public var applied: Int
    /// Patches that could not be applied (for example because the game was updated).
    public var skipped: Int
    /// Optional patches that are off by default.
    public var disabled: Int

    public init(applied: Int, skipped: Int, disabled: Int = 0) {
        self.applied = applied
        self.skipped = skipped
        self.disabled = disabled
    }

    public var isEmpty: Bool { applied == 0 && skipped == 0 && disabled == 0 }

    /// Lines look like `0x004d1870 applied` or `0x004a825c skipped: math disabled`.
    public static func parse(_ text: String) -> PatchReport {
        var report = PatchReport(applied: 0, skipped: 0)
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].hasPrefix("0x") else { continue }
            if parts[1].hasPrefix("applied") { report.applied += 1 }
            else if parts[1].hasPrefix("skipped: math disabled") { report.disabled += 1 }
            else if parts[1].hasPrefix("skipped") { report.skipped += 1 }
        }
        return report
    }

    public var summary: String {
        if isEmpty { return L("Not available yet") }
        if skipped == 0 { return L("Active") }
        return L("%@ active, %@ skipped (game version differs)", String(applied), String(skipped))
    }
}
