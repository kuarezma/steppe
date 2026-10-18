import Foundation

/// Everything Steppe downloads or patches, pinned by SHA-256.
///
/// This file is the single source of truth for third-party runtime versions.
/// To move to a newer Wine engine, change the values here, re-run the tests and
/// re-verify the patch offsets (see docs/ENGINE_PATCHES.md).
public struct RuntimeManifest: Sendable {
    public struct Download: Sendable {
        public let name: String
        public let url: URL
        public let sha256: String
        public let sizeBytes: Int64
    }

    public struct BytePatch: Sendable {
        public let offset: Int
        public let expected: [UInt8]
        public let replacement: [UInt8]
        public let note: String
    }

    public struct WinemacPatch: Sendable {
        /// Path of the patched file relative to the engine directory.
        public let relativePath: String
        /// SHA-256 of the pristine, upstream-signed file.
        public let originalSHA256: String
        /// SHA-256 of the patched file after an ad-hoc sign-and-strip round trip (its canonical unsigned form).
        public let patchedUnsignedSHA256: String
        public let patches: [BytePatch]
    }

    public struct Steam: Sendable {
        public let setupURL: URL
        public let appID: Int
    }

    public let engine: Download
    /// Top-level directory inside the engine archive.
    public let engineArchiveRoot: String
    public let template: Download
    /// Path of the library directory inside the template archive.
    public let templateFrameworksPath: String
    public let winemac: WinemacPatch
    public let steam: Steam
    /// Bump to force engines to be re-patched after changing the patch table.
    public let patchRevision: Int
    /// SHA-256 of the original third-party audio libraries shipped with the
    /// game (Steam build 3154226). Only these files are ever replaced.
    public let originalGameDLLs: [String: String]

    public static let current = RuntimeManifest(
        engine: Download(
            name: "WS12WineSikarugir10.0_6",
            url: URL(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir10.0_6.tar.xz")!,
            sha256: "9da7ee0cbf386522f3a9906943726d9c3c125dbbd9ab120e3cde80e88d6091b2",
            sizeBytes: 166_304_096
        ),
        engineArchiveRoot: "wswine.bundle",
        template: Download(
            name: "Template-1.0.18",
            url: URL(string: "https://github.com/Sikarugir-App/Template/releases/download/v1.0/Template-1.0.18.tar.xz")!,
            sha256: "00d1fcb66aebdef51981b26476a2fe8cd600c39552166f0e733f57272d9e97b3",
            sizeBytes: 87_468_948
        ),
        templateFrameworksPath: "Template-1.0.18.app/Contents/Frameworks",
        winemac: WinemacPatch(
            relativePath: "lib/wine/x86_64-unix/winemac.so",
            originalSHA256: "4cbf65e363d6d8b5a70dba719b50b811fb4b2705985e93f777c6cb7a12878eb0",
            patchedUnsignedSHA256: "5c422f82a2f5428b104bcf6fc879d84a2c1f0cdb969b57d4208632f1c43ef644",
            patches: [
                BytePatch(
                    offset: 194_532,
                    expected: [0x0f, 0x84, 0x0b, 0x02, 0x00, 0x00],
                    replacement: [0xe9, 0x0c, 0x02, 0x00, 0x00, 0x90],
                    note: "Hide WGL pbuffer extensions: CGLCreatePBuffer fails with 10005 on current macOS."
                ),
                BytePatch(
                    offset: 222_017,
                    expected: [0xe8, 0x14, 0xd0, 0x00, 0x00],
                    replacement: [0x90, 0x90, 0x90, 0x90, 0x90],
                    note: "Skip a double free() of the pbuffer device context."
                ),
                BytePatch(
                    offset: 223_138,
                    expected: [0xe8, 0xb3, 0xcb, 0x00, 0x00],
                    replacement: [0x90, 0x90, 0x90, 0x90, 0x90],
                    note: "Skip a second double free() of the pbuffer device context."
                ),
                BytePatch(
                    offset: 233_474,
                    expected: [0x75, 0x0e],
                    replacement: [0x90, 0x90],
                    note: "Let wglGetPixelFormat succeed for the default (BEHIND) surface mode."
                ),
            ]
        ),
        steam: Steam(
            setupURL: URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!,
            appID: 333_420
        ),
        patchRevision: 1,
        originalGameDLLs: [
            "ogg.dll": "a49cf7d501484be0f8967288d8e744fc7531c38efb60718071bb127cd56f3ab3",
            "vorbis.dll": "d5c04c2fa70ab723bd1e7e595b3e7f1a82fd390c0457271a25f6fc21d53b6ff6",
            "vorbisfile.dll": "afb1cfa3b585323b03ba962ff5503fd22db2c7c44546705b020338895a23489a",
        ]
    )
}
