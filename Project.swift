import Foundation
import ProjectDescription

// Tuist is the source of truth for the Murmur app target — it regenerates the
// .xcodeproj, so bundle id and signing MUST live here (Xcode edits get clobbered).
//
// The app is a thin UI over MurmurKit, the shared dictation core it builds from
// the local `MurmurKit/` Swift package (which pulls STT from the fork's
// `dev/nemo-mic` worktree). The same MurmurKit powers `murmur-cli`. The global
// hotkey uses Carbon `RegisterEventHotKey` (KeyboardShortcuts) — no Accessibility.

// PostHog ingestion key injected at generation time. Tuist only forwards TUIST_-prefixed env
// vars into the manifest, so the maintainer's build sets TUIST_MURMUR_POSTHOG_KEY (local or
// CI). Absent in a plain `tuist generate` → source/fork builds ship with analytics OFF.
let posthogAPIKey = ProcessInfo.processInfo.environment["TUIST_MURMUR_POSTHOG_KEY"] ?? ""

// Release builds inject both values. Otherwise the marketing version is read
// from the committed VERSION — the same file release-please bumps and the
// release scripts read — so the repo never holds a second copy that can drift.
// The manifest-relative path is tried first so `tuist generate` is correct from
// any working directory; "0.0.0" only appears if VERSION itself is unreadable.
// TUIST_APP_BUILD is a monotonic integer (BUILD_NUMBER_BASE + commit count);
// a plain local build falls back to the marketing version.
let versionFile = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("VERSION")
let committedVersion = (
    (try? String(contentsOfFile: versionFile.path, encoding: .utf8))
        ?? (try? String(contentsOfFile: "VERSION", encoding: .utf8))
        ?? "0.0.0"
).trimmingCharacters(in: .whitespacesAndNewlines)
let appVersion = ProcessInfo.processInfo.environment["TUIST_APP_VERSION"] ?? committedVersion
let appBuild = ProcessInfo.processInfo.environment["TUIST_APP_BUILD"] ?? appVersion

let project = Project(
    name: "Murmur",
    packages: [
        .local(path: "MurmurKit"),
        .local(path: "Engine/Captions"),   // captions band UI, shared with Kafedra
        .remote(url: "https://github.com/sindresorhus/KeyboardShortcuts",
                requirement: .upToNextMajor(from: "2.0.0")),
        .remote(url: "https://github.com/PostHog/posthog-ios",
                requirement: .upToNextMajor(from: "3.0.0")),   // anonymous usage/error analytics (opt-out)
        .remote(url: "https://github.com/sparkle-project/Sparkle",
                requirement: .upToNextMajor(from: "2.6.0")),   // in-app auto-update (appcast + EdDSA)
    ],
    targets: [
        .target(
            name: "Murmur",
            destinations: .macOS,
            product: .app,
            productName: "Murmator",
            bundleId: "app.bshk.murmur",
            deploymentTargets: .macOS("15.0"),   // MLXAudioSTT (dev/nemo-mic) requires macOS 15
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": .string(appVersion),   // X.Y.Z from the release tag
                "CFBundleVersion": .string(appBuild),                // monotonic build (APP_BUILD) or version
                "LSUIElement": true,                       // menu-bar agent: no Dock icon
                "LSApplicationCategoryType": "public.app-category.productivity",
                "CFBundleDisplayName": "Murmator",
                "CFBundleName": "Murmator",
                "CFBundleLocalizations": ["en", "ru"],
                "CFBundleDevelopmentRegion": "en",
                "NSMicrophoneUsageDescription":
                    "Murmator transcribes your speech on-device while you hold the dictation hotkey.",
                // Analytics key injected from MURMUR_POSTHOG_KEY (empty in source/fork builds → off).
                "PostHogAPIKey": .string(posthogAPIKey),
                // Sparkle in-app updates: the appcast lives in the app's own GitHub repo
                // (the artifact source; the Homebrew tap stays thin).
                // This key is Murmur's alone - ContainerStack signs with a different one.
                // Shipped 0.1.x pins it, so the private half can never be rotated or replaced.
                "SUFeedURL": "https://raw.githubusercontent.com/bshk-app/murmur/main/appcast.xml",
                "SUPublicEDKey": "vCki0eiwlGncDf3ZwIZawLNFss906pi/drQi/PnUaUA=",
                "SUEnableAutomaticChecks": true,
                "SUScheduledCheckInterval": 86400,   // daily
            ]),
            sources: ["Sources/Murmur/**/*.swift", "Shared/Mascot/**/*.swift"],
            resources: ["Sources/Murmur/Resources/**", "Shared/Mascot/Resources/**"],
            dependencies: [
                .package(product: "MurmurKit"),
                .package(product: "MurmurCaptions"),
                .package(product: "KeyboardShortcuts"),
                .package(product: "PostHog"),
                .package(product: "Sparkle"),
            ],
            settings: .settings(base: [
                "SWIFT_VERSION": "5.0",
                "PRODUCT_MODULE_NAME": "Murmur",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",   // Media.xcassets/AppIcon (cat)
                // Stable signature so the Accessibility (typing) grant persists.
                "CODE_SIGN_STYLE": "Automatic",
                "DEVELOPMENT_TEAM": "Q8H6GWJ658",
                "CODE_SIGN_IDENTITY": "Apple Development",
            ])
        ),
        // The app layer had no tests at all, which is why a missing startup
        // step could not be caught: MurmurKit's suite cannot see anything in
        // Sources/Murmur. Deliberately host-free — these cover decisions and
        // declarations, not anything needing a running app.
        .target(
            name: "MurmurTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "app.bshk.murmur.tests",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            sources: ["Tests/MurmurTests/**/*.swift"],
            dependencies: [.target(name: "Murmur")],
            settings: .settings(base: [
                "SWIFT_VERSION": "5.0",
                "DEVELOPMENT_TEAM": "Q8H6GWJ658",
                "CODE_SIGN_STYLE": "Automatic",
            ])
        ),
    ]
)
