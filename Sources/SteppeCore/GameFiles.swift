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

    private static let resourcePanelPatched = """
          [*] = ;var bNotchBar : Boolean = (((GetViewerWidth/GetViewerHeight)>1.50) and ((GetViewerWidth/GetViewerHeight)<1.58) and (GetDisplayMode<>'dmWindow'));
          [*] = ;if ((GetViewerWidth)<1260) then
          [*] = ;dpiscale := GetViewerWidth/1260;
          [*] = ;var resPanelBaseH : Integer = GetGUITextureHeight('resourcepanel.background');
          [*] = ;var notchDropY : Integer = 0;
          [*] = ;if (bNotchBar) then
          [*] = ;notchDropY := Max(46, round(GetViewerHeight*0.042/dpiscale));
          [*] = ;var elmParent : Integer = _gui_CreateParent(elmname, 0, gc_halParentLeft, gc_valParentTop, 0, 0, round(GetViewerWidth/dpiscale), resPanelBaseH+notchDropY, True);
          [*] = ;_gui_AbsScaleByDPI(elmParent);
          [*] = ;_gui_SetAbsScale(elmParent, dpiscale);
          [*] = ;SetGUIElementVisible(elmParent, (gInterface.gamemode<>gc_gamemode_mainmenu));
          [*] = ;var xoff : Integer;
          [*] = ;if (not bNotchBar) then
          [*] = ;begin
          [*] = ;   if ((GetViewerWidth/basedpiscale)<cminwidth) then
          [*] = ;   xoff := round(-45*dpiscale)
          [*] = ;   else
          [*] = ;   if ((GetViewerWidth/basedpiscale)<1440) then
          [*] = ;   xoff := -100;
          [*] = ;end;
          [*] = ;var elm : Integer = _gui_CreateImageActive('resbackground', elmParent, 'resourcepanel.background', gc_halParentMiddle, gc_valParentTop, xoff, cResourceOffY+notchDropY, 0, 0, 0, '', '', True);
    """

    private static let resourceTextsOriginal = """
          [*] = ;   _gui_CreateTextShadowed('resource'+IntToStr(ind), elmParent, text, gc_halParentMiddle, gc_valParentTop, x+xoff, cResourceOffY-4, cResourceSizeX, GetGUIElementHeight(elmParent), gc_halLeft, gc_valMiddle, gc_font_serif_13, color, 1, 1, shcolor, True);
          [*] = ;
          [*] = ;   if (dpiscale=2) then
          [*] = ;   _gui_CreateImageActive('resourcehint'+IntToStr(ind), elmParent, gc_gui_material_blank, gc_halParentMiddle, gc_valParentMiddle, x-160+xoff, cResourceOffY-10, cResourceSizeX-10, GetGUIElementHeight(elmParent), 0, '', hint, True)
          [*] = ;   else
          [*] = ;   _gui_CreateImageActive('resourcehint'+IntToStr(ind), elmParent, gc_gui_material_blank, gc_halParentMiddle, gc_valParentMiddle, x-60+xoff, cResourceOffY-10, cResourceSizeX-10, GetGUIElementHeight(elmParent), 0, '', hint, True);
    """

    private static let resourceTextsPatched = """
          [*] = ;   _gui_CreateTextShadowed('resource'+IntToStr(ind), elmParent, text, gc_halParentMiddle, gc_valParentTop, x+xoff, cResourceOffY-4+notchDropY, cResourceSizeX, resPanelBaseH, gc_halLeft, gc_valMiddle, gc_font_serif_13, color, 1, 1, shcolor, True);
          [*] = ;
          [*] = ;   if (dpiscale=2) then
          [*] = ;   _gui_CreateImageActive('resourcehint'+IntToStr(ind), elmParent, gc_gui_material_blank, gc_halParentMiddle, gc_valParentTop, x-160+xoff, cResourceOffY-10+notchDropY, cResourceSizeX-10, resPanelBaseH, 0, '', hint, True)
          [*] = ;   else
          [*] = ;   _gui_CreateImageActive('resourcehint'+IntToStr(ind), elmParent, gc_gui_material_blank, gc_halParentMiddle, gc_valParentTop, x-60+xoff, cResourceOffY-10+notchDropY, cResourceSizeX-10, resPanelBaseH, 0, '', hint, True);
    """

    private static let populationCreateOriginal = """
          [*] = ;var elmPopulationHnd : Integer = _gui_CreateImageActive('population', elmParent, gc_gui_material_blank, gc_halParentLeft, gc_valParentTop, 0, 5, 142, GetGUIElementHeight(elmParent), 0, '', cTextHintFarm, True);
    """

    private static let populationCreatePatched = """
          [*] = ;var elmPopulationHnd : Integer = _gui_CreateImageActive('population', elmParent, gc_gui_material_blank, gc_halParentLeft, gc_valParentTop, 0, 5, 142, resPanelBaseH, 0, '', cTextHintFarm, True);
    """

    private static let populationAndIdleOriginal = """
          [*] = ;_gui_CreateTextShadowed('_txt_population', elmPopulationHnd, text, gc_halParentLeft, gc_valParentTop, cPopulationOffsetX, 0, 0, GetGUIElementHeight(elmParent), gc_halLeft, gc_valMiddle, gc_font_sans_12, color, 1, 1, shcolor, True);
          [*] = ;
          [*] = ;var bObjectivesExists : Boolean;
          [*] = ;if (gScenario.bactive) then
          [*] = ;begin
          [*] = ;   var i : Integer;
          [*] = ;   for i:=0 to gc_scenario_maxobjectives-1 do
          [*] = ;   if (gScenario.objectives[i].bvisible) then
          [*] = ;   begin
          [*] = ;      bObjectivesExists := True;
          [*] = ;      break;
          [*] = ;   end;
          [*] = ;end;
          [*] = ;
          [*] = ;var posY : Integer;
          [*] = ;if (bObjectivesExists) then
          [*] = ;posY := 50;
    """

    private static let populationAndIdlePatched = """
          [*] = ;_gui_CreateTextShadowed('_txt_population', elmPopulationHnd, text, gc_halParentLeft, gc_valParentTop, cPopulationOffsetX, 0, 0, resPanelBaseH, gc_halLeft, gc_valMiddle, gc_font_sans_12, color, 1, 1, shcolor, True);
          [*] = ;
          [*] = ;var bObjectivesExists : Boolean;
          [*] = ;if (gScenario.bactive) then
          [*] = ;begin
          [*] = ;   var i : Integer;
          [*] = ;   for i:=0 to gc_scenario_maxobjectives-1 do
          [*] = ;   if (gScenario.objectives[i].bvisible) then
          [*] = ;   begin
          [*] = ;      bObjectivesExists := True;
          [*] = ;      break;
          [*] = ;   end;
          [*] = ;end;
          [*] = ;
          [*] = ;var posY : Integer = notchDropY;
          [*] = ;if (bObjectivesExists) then
          [*] = ;posY := posY+50;
    """

    private static let objectivesOriginal = """
          [*] = ;var elmObjectives : Integer = _gui_CreateParent('objs', elmParent, gc_halParentLeft, gc_valParentTop, 54+5+cpadding-8, 66+cpadding-8, 0, 0, True);
          [*] = ;if (bPaper) then
          [*] = ;elmObjectivesBackground := _gui_CreateParent('bcg', elmObjectives, gc_halParentLeft, gc_valParentTop, 0, 0, 0, 0, True);
          [*] = ;//SetGUIElementUserBlend(elmObjectives, 1);
          [*] = ;if (gScenario.bactive) then
          [*] = ;begin
          [*] = ;   var listid : TIntegerList;
          [*] = ;   var listgametime : TIntegerList;
          [*] = ;   var material : String;
          [*] = ;   if (not bObjectivesExists) then
          [*] = ;   begin
          [*] = ;      material := gc_hud_icons_control+'showobjectives';
          [*] = ;      hint := cTextShowObjectivesDisabled;
          [*] = ;   end
          [*] = ;   else
          [*] = ;   if (not gInterface.bhideobjectives) then
          [*] = ;   begin
          [*] = ;      material := gc_hud_icons_control+'hideobjectives';
          [*] = ;      hint := cTextHideObjectives;
          [*] = ;   end
          [*] = ;   else
          [*] = ;   begin
          [*] = ;      material := gc_hud_icons_control+'showobjectives';
          [*] = ;      hint := cTextShowObjectives;
          [*] = ;   end;
          [*] = ;   var elmSwitchShowObjectivesHnd : Integer = _gui_CreateImage('_img_switchobjectives', elmParent, material, gc_halParentLeft, gc_valParentTop, 3, 64{+50+50}, 0, 0, 0, True);
    """

    private static let objectivesPatched = """
          [*] = ;var elmObjectives : Integer = _gui_CreateParent('objs', elmParent, gc_halParentLeft, gc_valParentTop, 54+5+cpadding-8, 66+cpadding-8+notchDropY, 0, 0, True);
          [*] = ;if (bPaper) then
          [*] = ;elmObjectivesBackground := _gui_CreateParent('bcg', elmObjectives, gc_halParentLeft, gc_valParentTop, 0, 0, 0, 0, True);
          [*] = ;//SetGUIElementUserBlend(elmObjectives, 1);
          [*] = ;if (gScenario.bactive) then
          [*] = ;begin
          [*] = ;   var listid : TIntegerList;
          [*] = ;   var listgametime : TIntegerList;
          [*] = ;   var material : String;
          [*] = ;   if (not bObjectivesExists) then
          [*] = ;   begin
          [*] = ;      material := gc_hud_icons_control+'showobjectives';
          [*] = ;      hint := cTextShowObjectivesDisabled;
          [*] = ;   end
          [*] = ;   else
          [*] = ;   if (not gInterface.bhideobjectives) then
          [*] = ;   begin
          [*] = ;      material := gc_hud_icons_control+'hideobjectives';
          [*] = ;      hint := cTextHideObjectives;
          [*] = ;   end
          [*] = ;   else
          [*] = ;   begin
          [*] = ;      material := gc_hud_icons_control+'showobjectives';
          [*] = ;      hint := cTextShowObjectives;
          [*] = ;   end;
          [*] = ;   var elmSwitchShowObjectivesHnd : Integer = _gui_CreateImage('_img_switchobjectives', elmParent, material, gc_halParentLeft, gc_valParentTop, 3, 64+notchDropY{+50+50}, 0, 0, 0, True);
    """

    /// On notched MacBooks, lowers the centered 6-resource bar (`showresourcepanel.inc`) just below the camera notch
    /// while keeping Population (top-left) and Game Menu (top-right) in the auxiliary top areas beside the notch.
    /// Also restores any legacy `hud.mat.steppe-orig` backup if present.
    public static func applyNotchHUD(in gameDir: URL, enabled: Bool) -> [Status] {
        let fm = FileManager.default
        var record = readInstalledRecord(in: gameDir)
        defer { writeInstalledRecord(record, in: gameDir) }

        // Always restore any legacy hud.mat.steppe-orig from v0.1.6 so hud.mat stays 100% original.
        let hudTarget = gameDir.appendingPathComponent(hudMatRelativePath)
        let hudBackup = hudTarget.appendingPathExtension("steppe-orig")
        if fm.fileExists(atPath: hudBackup.path) {
            let currentHash = try? Hashing.sha256(of: hudTarget)
            let backupHash = try? Hashing.sha256(of: hudBackup)
            if let currentHash, currentHash != record[hudMatRelativePath], currentHash != backupHash {
                try? fm.removeItem(at: hudBackup)
            } else {
                _ = try? replaceFile(at: hudTarget, with: hudBackup)
            }
            record.removeValue(forKey: hudMatRelativePath)
        }

        let path = resourcePanelRelativePath
        let target = gameDir.appendingPathComponent(path)
        let backup = target.appendingPathExtension("steppe-orig")

        if !enabled {
            guard fm.fileExists(atPath: backup.path) else { return [.alreadyCurrent(path)] }
            let currentHash = try? Hashing.sha256(of: target)
            let backupHash = try? Hashing.sha256(of: backup)
            if let currentHash, currentHash != record[path], currentHash != backupHash {
                try? fm.removeItem(at: backup)
                record.removeValue(forKey: path)
                return [.alreadyCurrent(path)]
            }
            do {
                try replaceFile(at: target, with: backup)
                record.removeValue(forKey: path)
                return [.installed(path)]
            } catch {
                Log.shared.error("Could not restore \(path): \(error.localizedDescription)")
                return [.skippedUnknownFile(path)]
            }
        }

        guard fm.fileExists(atPath: target.path), let currentHash = try? Hashing.sha256(of: target) else {
            return [.missing(path)]
        }
        let hasValidBackup = fm.fileExists(atPath: backup.path)
            && (currentHash == record[path] || currentHash == (try? Hashing.sha256(of: backup)))
        let base = hasValidBackup ? backup : target
        let refreshBackup = !hasValidBackup
        guard let data = try? Data(contentsOf: base),
              var content = String(data: data, encoding: .isoLatin1) else {
            return [.skippedUnknownFile(path)]
        }
        let newline = content.contains("\r\n") ? "\r\n" : "\n"
        let replacements = [
            (resourcePanelOriginal, resourcePanelPatched),
            (resourceTextsOriginal, resourceTextsPatched),
            (populationCreateOriginal, populationCreatePatched),
            (populationAndIdleOriginal, populationAndIdlePatched),
            (objectivesOriginal, objectivesPatched),
        ]
        for (original, replacement) in replacements {
            let expected = original.replacingOccurrences(of: "\n", with: newline)
            guard content.components(separatedBy: expected).count == 2 else {
                return [.skippedUnknownFile(path)]
            }
            content = content.replacingOccurrences(of: expected, with: replacement.replacingOccurrences(of: "\n", with: newline))
        }
        guard let patched = content.data(using: .isoLatin1) else { return [.skippedUnknownFile(path)] }
        let patchedHash = Hashing.sha256(of: patched)
        if !refreshBackup, fm.fileExists(atPath: backup.path), (try? Data(contentsOf: target)) == patched {
            record[path] = patchedHash
            return [.alreadyCurrent(path)]
        }
        let staged = target.appendingPathExtension("steppe-new-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged) }
        do {
            if refreshBackup || !fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: target, to: backup)
            }
            try patched.write(to: staged)
            try replaceFile(at: target, with: staged)
            record[path] = patchedHash
            return [.installed(path)]
        } catch {
            Log.shared.error("Could not patch \(path): \(error.localizedDescription)")
            return [.skippedUnknownFile(path)]
        }
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
