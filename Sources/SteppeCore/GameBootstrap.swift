import Foundation

/// Creates the small set of files Cossacks 3 needs before its very first launch under Wine.
///
/// Why this exists: on a fresh install the game opens its own configuration dialog and then crashes
/// (access violation at 0x00427A2B while loading fonts) unless a default profile *and* a named profile already exist.
/// With the files below in place it starts straight into the main menu. They are plain-text settings files in the
/// game's own format, written to the user's own prefix; nothing from the game is copied.
public enum GameBootstrap {
    /// Generic hardware-detection result. The game then takes its conservative rendering path, which is the one
    /// Steppe's graphics fixes were validated against.
    static let hardwareInfo = """
    section.begin
       Version = 2.0
       MMX = True
       SSE = True
       SSE2 = True
       SSE3 = True
       SSE4 = True
       HTT = False
       AMDMMX = False
       _3DNow = False
       _3DNow2 = False
       MaxMhz = 26803300
       CurrentMhz = 4213013
       NumLogicalProc = 0
       NumCores = 0
       dwTotalPhys = 4294963200
       GLVendor = 
       GLRenderer = 
       GLVersion = 
       GLFBOSupport = False
       GLSLSupport = False
       GLShadowSupport = False
       GLShadowAmbientSupport = False
       GLPBufferSupport = False
       GLMultitextureSupport = False
       GLMultisampleSupport = False
       GLTextureCompressionS3TCSupport = False
       Acceleration = chaUnknown
       AdapterVendor = NVIDIA
       AdapterProduct = 9
       AdapterVersion = 14
       AdapterSubVersion = 13
       AdapterBuild = 783
       AdapterSubVersionBuild = 13783
       AdapterDriver = nvd3dum.dll
       AdapterDescription = NVIDIA GeForce 6800
       AdapterDeviceName = \\\\.\\DISPLAY1
       AdapterVendorId = 4318
       AdapterDeviceId = 65
       AdapterSubSysId = 0
       AdapterRevision = 0
       AdapterWHQLLevel = 0
    section.end

    """

    static let videoInfo = "section.begin\n   Run = 1\nsection.end\n\n"

    /// Profile files for a player. `locale` is the game's own language folder name (`en`, `tu`, `po` …).
    static func profileData(name: String, locale: String) -> String {
        """
        section.begin
           Variables : struct.begin
              name = \(name)
              sndmute = 0
              sndmaster = 0.75
              sndmusic = 0.75
              sndambient = 0.75
              sndfx = 0.75
              sndvoice = 0.75
              sndinterface = 0.5
              mousescrollspeed = 0.5
              wheelspeed = 0.5
              keyscrollspeed = 0.5
              middlemousescrollspeed = 0.5
              igamespeed = 1
              bclipmouse = -1
              bautosave = -1
              bbrushunderunit = -1
              bsearchenemyinfront = -1
              binfiniteonleftclick = 0
              bselectallunitsonz = 0
              bcenterfirstrow = 0
              lang = .\\data\\locale\\\(locale)\\table.lng
           struct.end
        section.end

        """
    }

    /// Video and sound settings tuned for smooth play on Apple silicon (shadows, SSAO and depth of field off).
    static func profileConfig(resolution: Resolution) -> String {
        """
        section.begin
           Engine : struct.begin
              ScreenResolution : struct.begin
                 Width = \(resolution.width)
                 Height = \(resolution.height)
                 Frequency = 0
              struct.end
              HDRType = htPseudoHDR
              DOFEnable = False
              SSAOEnable = False
              FXAAEnable = True
              AntiAliasing = aaNone
              VSyncMode = vsmNoSync
              TextureFilteringQuality = tfAnisotropic
              DDSDetailLevel = 0
              WaterReflection = wrmLow
              ShadowMap = 1024
              ShadowMapEnabled = False
              HorizonRenderEnabled = False
              ShaderType = stSM20
              CoverEnabled = False
              CoverPPLEnabled = False
              SelfShadowingTerrain = False
              PFX = True
              Sound : struct.begin
                 svgMusic = 1
                 svgAmbient = 1
                 svgSFX = 1
                 svgVoice = 1
                 svgInterface = 1
                 Master = 1
              struct.end
              UseMultithreadedMode = True
           struct.end
        section.end

        """
    }

    /// Maps an ISO language code to the game's locale folder (the game uses `tu`, `po`, `uk` …).
    public static func localeFolder(languageCode: String, available: [String]) -> String {
        let aliases = ["tr": "tu", "pt": "po"]
        let candidate = aliases[languageCode] ?? languageCode
        return available.contains(candidate) ? candidate : "en"
    }

    /// Profile folder names must be safe path components; Steam display names can contain anything.
    public static func sanitizedProfileName(_ raw: String?) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-"))
        let cleaned = String((raw ?? "").unicodeScalars.filter { allowed.contains($0) && $0.isASCII }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        let name = String(cleaned.prefix(24))
        // "Cossack" is the game's own default profile; a named profile must be a different folder.
        return name.isEmpty || name.caseInsensitiveCompare("Cossack") == .orderedSame ? "Player" : name
    }

    /// The display name of the most recently signed-in Steam account (used only to name the local profile).
    public static func personaName(fromLoginUsers text: String) -> String? {
        var current: (persona: String?, mostRecent: Bool) = (nil, false)
        var best: String?
        var fallback: String?
        func flush() {
            if let p = current.persona {
                if current.mostRecent { best = p }
                if fallback == nil { fallback = p }
            }
            current = (nil, false)
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\"PersonaName\"") { current.persona = quotedValue(t) }
            else if t.hasPrefix("\"MostRecent\"") { current.mostRecent = quotedValue(t) == "1" }
            else if t == "}" { flush() }
        }
        flush()
        return best ?? fallback
    }

    private static func quotedValue(_ line: String) -> String? {
        let parts = line.components(separatedBy: "\"")
        return parts.count >= 4 ? parts[3] : nil
    }

    /// Writes whatever is missing. Existing files are never touched. Returns the names of created items.
    @discardableResult
    public static func seed(
        documentsGameDir: URL,
        profileName: String,
        locale: String,
        resolution: Resolution
    ) throws -> [String] {
        let fm = FileManager.default
        var created: [String] = []
        func write(_ text: String, to url: URL, label: String) throws {
            guard !fm.fileExists(atPath: url.path) else { return }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The game writes Windows line endings.
            try Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: url, options: .atomic)
            created.append(label)
        }
        try write(hardwareInfo, to: documentsGameDir.appendingPathComponent("hardware.info"), label: "hardware.info")
        try write(videoInfo, to: documentsGameDir.appendingPathComponent("video.info"), label: "video.info")

        let profiles = documentsGameDir.appendingPathComponent("profiles", isDirectory: true)
        let defaultProfile = profiles.appendingPathComponent("Cossack", isDirectory: true)
        try write(profileData(name: "Cossack", locale: locale), to: defaultProfile.appendingPathComponent("profile.dat"), label: "profiles/Cossack/profile.dat")
        try write(profileConfig(resolution: resolution), to: defaultProfile.appendingPathComponent("profile.cfg"), label: "profiles/Cossack/profile.cfg")

        let existing = (try? fm.contentsOfDirectory(atPath: profiles.path)) ?? []
        let hasNamedProfile = existing.contains { $0.caseInsensitiveCompare("Cossack") != .orderedSame && !$0.hasPrefix(".") }
        if !hasNamedProfile {
            let named = profiles.appendingPathComponent(profileName, isDirectory: true)
            try write(profileData(name: profileName, locale: locale), to: named.appendingPathComponent("profile.dat"), label: "profiles/\(profileName)/profile.dat")
            try write(profileConfig(resolution: resolution), to: named.appendingPathComponent("profile.cfg"), label: "profiles/\(profileName)/profile.cfg")
        }
        return created
    }
}
