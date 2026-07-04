import AppKit
import Carbon // Text Input Source (TIS) APIs; deprecated framework, but TIS remains the standard way to read keyboard layouts.
import Foundation
import ImageIO
import UniformTypeIdentifiers

// =============================================================================
// LayoutTint
//
// Changes the desktop wallpaper based on the active keyboard layout, by
// painting a colored band over the menu bar area — a glanceable indicator of
// which layout is active.
//
// How it works, end to end:
//   1. On launch, read the current system wallpaper. If it's a plain static
//      image the user picked, copy it into ~/Library/Application Support/
//      LayoutTint/ as the "source".
//   2. Render one PNG per configured band color ("wallpaper-1.png", …), each
//      being the source image aspect-filled to the main display plus a solid
//      band over the menu bar.
//   3. Listen for keyboard layout changes. On each change, map the active
//      layout to its position in the enabled input source list (System Settings
//      > Keyboard > Input Sources order) and set the matching generated
//      wallpaper on the main screen. Other screens are never touched.
//
// Layout → wallpaper mapping is *positional*: input source #1 gets
// bandColors[0], #2 gets bandColors[1], etc. Layouts beyond the configured
// colors, and non-static user wallpapers (video/dynamic/rotating), are left
// alone.
//
// Build:      swiftc -O LayoutTint.swift -o LayoutTint
// Run (CLI):  nohup ./LayoutTint
// Run (.app): place the binary in an .app bundle; set LSUIElement=YES in
//             Info.plist so it doesn't appear in the Dock.
// =============================================================================

// MARK: - Configuration

struct BandColor {
    let r, g, b, a: CGFloat
}

enum Config {
    /// Regenerate all wallpapers on launch, ignoring existing files.
    /// Enable while tuning band colors or height; disable to skip redundant
    /// rendering on every launch. (A newly copied source wallpaper always
    /// triggers regeneration regardless of this flag.)
    static let forceRegenerate = false

    /// Used when the menu bar height can't be detected (e.g. "Automatically
    /// hide and show the menu bar" is enabled, which makes it measure as 0).
    static let menuBarFallbackHeightPx = 76

    /// Subdirectory of ~/Library/Application Support where the source copy and
    /// generated wallpapers live.
    static let appSupportSubdirectory = "LayoutTint"

    /// Band colors by input source position (1-based, matching the order in
    /// System Settings > Keyboard > Input Sources). wallpaper-1.png gets
    /// bandColors[0], wallpaper-2.png gets bandColors[1], and so on.
    /// Layouts beyond the last configured color leave the wallpaper unchanged.
    ///
    /// The actual position → layout mapping is logged at startup; check the
    /// log to verify colors land on the intended layouts.
    static let bandColors: [BandColor] = [
        BandColor(r: 0.00, g: 0.00, b: 0.00, a: 1),                  // #1
        BandColor(r: 60 / 255, g: 40 / 255, b: 120 / 255, a: 1),     // #2
        BandColor(r: 29 / 255, g: 92 / 255, b: 85 / 255, a: 1),      // #3
    ]

    /// File extensions accepted as a static source wallpaper.
    /// (HEIC/HEIF additionally get a multi-image check — see `classify`.)
    static let staticImageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]

    /// Base name of the source copy in Application Support (extension varies
    /// with whatever the user's wallpaper file was).
    static let sourceBaseName = "wallpaper"

    static func outputName(forIndex index: Int) -> String { "wallpaper-\(index).png" }
}

// MARK: - Menu bar measurement

enum MenuBar {
    /// Menu bar height in device pixels, measured as the gap between the top
    /// of the screen and the top of the visible (usable) area. Independent of
    /// the Dock, which only affects the bottom/sides of visibleFrame.
    /// Returns nil when it measures as 0 (menu bar set to auto-hide).
    static func detectedHeightPx(for screen: NSScreen) -> Int? {
        let points = screen.frame.maxY - screen.visibleFrame.maxY
        let pixels = Int((points * screen.backingScaleFactor).rounded())
        return pixels > 0 ? pixels : nil
    }

    /// Height of the band to paint: detected menu bar height (or the
    /// configured fallback) plus the configured overlap.
    static func bandHeightPx(for screen: NSScreen) -> Int {
        (detectedHeightPx(for: screen) ?? Config.menuBarFallbackHeightPx)
    }
}

// MARK: - Logging

private let logTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    print("[\(logTimeFormatter.string(from: Date()))] \(message)")
}

/// One-time startup dump of everything needed to debug "why did/didn't the
/// wallpaper change": environment, config, and detected state.
func logStartupDiagnostics(manager: WallpaperManager) {
    log("LayoutTint starting (pid \(ProcessInfo.processInfo.processIdentifier))")
    log("Working directory: \(manager.directory.path)")

    if let screen = NSScreen.main {
        let backing = screen.convertRectToBacking(screen.frame)
        log("Main display: \(screen.localizedName), "
            + "\(Int(backing.width))×\(Int(backing.height)) px "
            + "(scale \(screen.backingScaleFactor))")
        if let detected = MenuBar.detectedHeightPx(for: screen) {
            log("Menu bar: detected \(detected)px "
                + "→ band height \(MenuBar.bandHeightPx(for: screen))px")
        } else {
            log("Menu bar: could not detect height (auto-hide enabled?) — "
                + "using fallback \(Config.menuBarFallbackHeightPx)px "
                + "→ band height \(MenuBar.bandHeightPx(for: screen))px")
        }
    } else {
        log("Warning: no main display detected")
    }
    let others = NSScreen.screens.filter { $0 != NSScreen.main }
    for screen in others {
        log("Additional display: \(screen.localizedName) — this app only manages the main display; it will be left alone")
    }

    log("Config: \(Config.bandColors.count) band color(s), "
        + "forceRegenerate=\(Config.forceRegenerate)")

    // The position → color mapping depends on this order, and Apple doesn't
    // document that TIS preserves the System Settings order (it does in
    // practice). Logging it makes the mapping verifiable.
    let layouts = InputSources.enabledLayoutIDs()
    if layouts.isEmpty {
        log("Warning: could not read the enabled input source list")
    } else {
        for (i, id) in layouts.enumerated() {
            let color = i < Config.bandColors.count ? "bandColors[\(i)]" : "no color configured"
            log("Input source #\(i + 1): \(id) → \(color)")
        }
    }
    log("Current layout: \(InputSources.currentLayoutID())")
}

// MARK: - Errors

enum AppError: Error, CustomStringConvertible {
    case noScreen
    case appSupportUnavailable
    case imageLoadFailed(URL)
    case contextCreationFailed
    case renderFailed
    case saveFailed(URL)
    case copyFailed(URL, underlying: Error)

    var description: String {
        switch self {
        case .noScreen:                 return "No display available (needs a GUI session)."
        case .appSupportUnavailable:    return "Could not create the Application Support directory."
        case .imageLoadFailed(let url): return "Failed to load image at \(url.path)"
        case .contextCreationFailed:    return "Failed to create bitmap context."
        case .renderFailed:             return "Failed to render output image."
        case .saveFailed(let url):      return "Failed to write \(url.path)"
        case .copyFailed(let url, let e): return "Failed to copy \(url.path): \(e.localizedDescription)"
        }
    }
}

// MARK: - Input sources

enum InputSources {
    /// IDs of the enabled, select-capable keyboard input sources, in what is
    /// assumed to be the System Settings order.
    ///
    /// NOTE: Apple does not document that TISCreateInputSourceList preserves
    /// the user-defined order from System Settings. It appears to in practice;
    /// the order is logged at startup so this can be verified. If it turns out
    /// to be wrong, the authoritative order lives in the com.apple.HIToolbox
    /// defaults under AppleEnabledInputSources.
    static func enabledLayoutIDs() -> [String] {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.compactMap { source in
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
            return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        }
    }

    static func currentLayoutID() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return "Unknown"
        }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}

// MARK: - Rendering

/// Renders the source image with "Fill Screen" semantics (high-quality scale
/// to cover + centered crop) at the main display's device-pixel size, then
/// paints a solid band over the menu bar area and writes a PNG.
///
/// Rendering at exact device-pixel size is what lets the band align with the
/// menu bar: macOS displays the PNG 1:1, so band pixels map to screen pixels.
final class WallpaperRenderer {
    private let sourceImage: CGImage
    private let screenWidthPx: Int
    private let screenHeightPx: Int
    private let bandHeightPx: Int

    init(inputURL: URL) throws {
        guard let screen = NSScreen.main else { throw AppError.noScreen }
        let backing = screen.convertRectToBacking(screen.frame)
        screenWidthPx = Int(backing.width.rounded())
        screenHeightPx = Int(backing.height.rounded())
        bandHeightPx = MenuBar.bandHeightPx(for: screen)

        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AppError.imageLoadFailed(inputURL)
        }
        sourceImage = image
    }

    func render(band: BandColor, to outputURL: URL) throws {
        let imgW = Double(sourceImage.width)
        let imgH = Double(sourceImage.height)
        let sw = Double(screenWidthPx)
        let sh = Double(screenHeightPx)

        // Aspect-fill: scale to cover the screen, center so overflow crops evenly.
        let scale = max(sw / imgW, sh / imgH)
        let drawRect = CGRect(x: (sw - imgW * scale) / 2,
                              y: (sh - imgH * scale) / 2,
                              width: imgW * scale,
                              height: imgH * scale)

        // Render in the source's own RGB color space so wide-gamut (P3)
        // wallpapers don't shift. The space is embedded in the output PNG.
        // Fall back to sRGB for non-RGB sources (grayscale, CMYK, …), which
        // CoreGraphics converts on draw.
        let colorSpace: CGColorSpace
        if let sourceSpace = sourceImage.colorSpace, sourceSpace.model == .rgb {
            colorSpace = sourceSpace
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        guard let ctx = CGContext(data: nil,
                                  width: screenWidthPx, height: screenHeightPx,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppError.contextCreationFailed
        }

        ctx.interpolationQuality = .high
        ctx.draw(sourceImage, in: drawRect)

        // Band colors are defined in sRGB (that's how they were tuned) and
        // converted by CG into whatever the context's space is, so the band
        // looks the same regardless of the wallpaper's color space.
        // CGContext origin is bottom-left, so the menu bar band is the top rows.
        let bandH = Double(bandHeightPx)
        ctx.setFillColor(CGColor(srgbRed: band.r, green: band.g, blue: band.b, alpha: band.a))
        ctx.fill(CGRect(x: 0, y: sh - bandH, width: sw, height: bandH))

        guard let output = ctx.makeImage() else { throw AppError.renderFailed }

        guard let dest = CGImageDestinationCreateWithURL(outputURL as CFURL,
                                                         UTType.png.identifier as CFString,
                                                         1, nil) else {
            throw AppError.saveFailed(outputURL)
        }
        CGImageDestinationAddImage(dest, output, nil)
        guard CGImageDestinationFinalize(dest) else { throw AppError.saveFailed(outputURL) }

        log("Generated \(outputURL.lastPathComponent) (\(screenWidthPx)×\(screenHeightPx) px)")
    }
}

// MARK: - Wallpaper source management

/// What the current system wallpaper turned out to be.
private enum WallpaperKind {
    /// A static image the user picked; usable as our source.
    case staticImage(URL)
    /// One of the files we generated (or anything else inside our directory).
    case ours
    /// Video, dynamic HEIC, rotating folder, or something we can't identify.
    /// Carries a human-readable reason for the log.
    case nonStatic(reason: String)
}

/// Owns the Application Support directory: keeps a copy of the user's chosen
/// wallpaper as the generation source, notices when the user picks a new
/// wallpaper, and (re)generates the banded variants.
///
/// The source is *copied* (not referenced in place) so the original can be
/// moved or deleted, and so generated files never mix with user files.
final class WallpaperManager {
    let directory: URL

    /// Current source copy (wallpaper.<ext>) inside `directory`, if any.
    private(set) var sourceURL: URL?

    /// True while the user's wallpaper is dynamic/video/unknown. While set,
    /// the switcher leaves the wallpaper alone — the user made a choice we
    /// can't reproduce with static PNGs, so respect it.
    private(set) var userWallpaperIsNonStatic = false

    private var lastSeenWallpaperPath: String?

    init() throws {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true) else {
            throw AppError.appSupportUnavailable
        }
        directory = base.appendingPathComponent(Config.appSupportSubdirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AppError.appSupportUnavailable
        }
        sourceURL = findExistingSource()
        if let source = sourceURL {
            log("Using existing source wallpaper \(source.lastPathComponent)")
        } else {
            log("No source wallpaper stored yet")
        }
    }

    /// Checks the current system wallpaper. If the user picked a new static
    /// image, copies it in as the source and regenerates all banded variants.
    /// Returns true if that happened (so callers can force a re-apply).
    ///
    /// There is no public "wallpaper changed" notification, so this is called
    /// opportunistically: at launch and on every layout change. Consequence:
    /// a wallpaper the user picks mid-session is only noticed on the next
    /// layout switch.
    func refresh() -> Bool {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL else {
            log("Could not read the current wallpaper URL — skipping wallpaper check")
            return false
        }

        // The system reports the same value repeatedly (including right after
        // we set our own wallpaper); only react to actual changes.
        guard url.path != lastSeenWallpaperPath else { return false }
        lastSeenWallpaperPath = url.path

        switch classify(url) {
        case .ours:
            userWallpaperIsNonStatic = false
            return false

        case .nonStatic(let reason):
            userWallpaperIsNonStatic = true
            log("Current wallpaper is \(reason) (\(url.path)) — leaving it in place")
            return false

        case .staticImage(let src):
            userWallpaperIsNonStatic = false
            log("New user wallpaper detected: \(src.path)")
            do {
                try copySource(from: src)
                try generateWallpapers(force: true)
                return true
            } catch {
                log("\(error)")
                return false
            }
        }
    }

    /// Generates wallpaper-1…N (N = number of configured band colors) from the
    /// source copy. With force, rebuilds everything; otherwise only missing files.
    func generateWallpapers(force: Bool) throws {
        guard let source = sourceURL else {
            log("No source wallpaper available yet — skipping generation")
            return
        }

        let allIndexes = Array(1...Config.bandColors.count)
        let indexes: [Int]
        if force {
            indexes = allIndexes
        } else {
            indexes = allIndexes.filter {
                !FileManager.default.fileExists(atPath: outputURL(forIndex: $0).path)
            }
            for i in allIndexes where !indexes.contains(i) {
                log("\(Config.outputName(forIndex: i)) already exists, skipping generation")
            }
        }
        guard !indexes.isEmpty else { return }

        let renderer = try WallpaperRenderer(inputURL: source)
        for i in indexes {
            try renderer.render(band: Config.bandColors[i - 1], to: outputURL(forIndex: i))
        }
    }

    func outputURL(forIndex index: Int) -> URL {
        directory.appendingPathComponent(Config.outputName(forIndex: index))
    }

    // MARK: Private

    private func classify(_ url: URL) -> WallpaperKind {
        // Anything inside our own directory is a wallpaper we set ourselves.
        if url.deletingLastPathComponent() == directory.standardizedFileURL {
            return .ours
        }

        // For dynamic wallpapers, desktopImageURL has been observed to report
        // this placeholder path instead of the real wallpaper. It's never a
        // path a user picks directly, so treat it as "can't tell what's set"
        // and leave the wallpaper alone rather than copying the wrong image.
        let placeholderPath = "/System/Library/CoreServices/DefaultDesktop.heic"
        if url.path == placeholderPath || url.resolvingSymlinksInPath().path == placeholderPath {
            return .nonStatic(reason: "reported as the DefaultDesktop placeholder (likely a dynamic wallpaper)")
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else {
            return .nonStatic(reason: "an unreadable or missing file")
        }
        if isDirectory.boolValue {
            return .nonStatic(reason: "a rotating-folder wallpaper")
        }

        // Anything not on the static-image allow-list (video wallpapers like
        // .mov aerials, anything else) is left alone.
        let ext = url.pathExtension.lowercased()
        guard Config.staticImageExtensions.contains(ext) else {
            return .nonStatic(reason: "an unrecognized type (.\(ext))")
        }

        // Dynamic (light/dark or time-based) wallpapers are HEIC files with
        // multiple embedded images; a static HEIC has exactly one.
        if ext == "heic" || ext == "heif" {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return .nonStatic(reason: "an unreadable HEIC file")
            }
            if CGImageSourceGetCount(source) > 1 {
                return .nonStatic(reason: "a dynamic HEIC wallpaper")
            }
        }

        return .staticImage(url)
    }

    /// Copies the user's wallpaper into our directory as wallpaper.<ext>,
    /// replacing any previous source copy (which may have a different extension,
    /// hence remove-all rather than overwrite-one).
    private func copySource(from src: URL) throws {
        let ext = src.pathExtension.lowercased()
        let dest = directory.appendingPathComponent("\(Config.sourceBaseName).\(ext)")

        for old in existingSourceCandidates() {
            try? FileManager.default.removeItem(at: old)
        }
        do {
            try FileManager.default.copyItem(at: src, to: dest)
        } catch {
            throw AppError.copyFailed(src, underlying: error)
        }
        sourceURL = dest
        log("Copied user wallpaper \(src.path) → \(dest.path)")
    }

    private func findExistingSource() -> URL? {
        let candidates = existingSourceCandidates()
        // Normally at most one exists (copySource removes the others). More
        // than one means a previous cleanup failed; the pick is arbitrary.
        if candidates.count > 1 {
            log("Warning: multiple source wallpapers found (\(candidates.map(\.lastPathComponent).joined(separator: ", "))) — using \(candidates[0].lastPathComponent)")
        }
        return candidates.first
    }

    private func existingSourceCandidates() -> [URL] {
        Config.staticImageExtensions
            .map { directory.appendingPathComponent("\(Config.sourceBaseName).\($0)") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: - Layout watching

/// Reacts to keyboard layout changes by setting the matching generated
/// wallpaper.
final class WallpaperSwitcher {
    private let manager: WallpaperManager
    private var lastAppliedLayoutID: String?
    private var warnedUnconfiguredLayouts = Set<String>()

    init(manager: WallpaperManager) {
        self.manager = manager
    }

    /// Applies the wallpaper matching the active layout's position in the
    /// enabled input source list, on the main screen only.
    ///
    /// No-ops when the layout is the same as last time (the notification can
    /// fire redundantly). A `force` call — used at startup and after the
    /// source wallpaper is replaced — bypasses that check.
    func applyCurrentLayout(force: Bool = false) {
        let id = InputSources.currentLayoutID()
        if !force, id == lastAppliedLayoutID { return }
        lastAppliedLayoutID = id

        if manager.userWallpaperIsNonStatic { return }

        // Re-read the list every time: the user can add, remove, or reorder
        // input sources while the app is running.
        let layouts = InputSources.enabledLayoutIDs()
        guard let position = layouts.firstIndex(of: id) else {
            log("Layout \(id) not found in the enabled input source list — wallpaper unchanged")
            return
        }
        let index = position + 1

        guard index <= Config.bandColors.count else {
            // Warn once per layout; this fires on every switch otherwise.
            if warnedUnconfiguredLayouts.insert(id).inserted {
                log("Layout \(id) is input source #\(index), but only \(Config.bandColors.count) band colors are configured — wallpaper unchanged")
            }
            return
        }

        let url = manager.outputURL(forIndex: index)
        guard FileManager.default.fileExists(atPath: url.path) else {
            log("\(url.lastPathComponent) has not been generated yet — wallpaper unchanged")
            return
        }

        // Main screen only: the images are rendered for its exact pixel size,
        // and multi-screen behavior is untested. Other screens are left alone.
        guard let screen = NSScreen.main else {
            log("No main screen available — wallpaper unchanged")
            return
        }
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        } catch {
            log("Failed to set \(url.lastPathComponent): \(error.localizedDescription)")
            return
        }
        log("Layout changed to \(id) (input source #\(index)) → \(url.lastPathComponent)")
    }
}

// MARK: - Entry point

// The manager and switcher are top-level globals out of necessity: the
// CFNotification callback below is a C function pointer, which cannot capture
// Swift context, so it must reach them through globals.

let manager: WallpaperManager
do {
    manager = try WallpaperManager()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
let switcher = WallpaperSwitcher(manager: manager)

logStartupDiagnostics(manager: manager)

// Pick up the current wallpaper. If it's a fresh static image, refresh()
// copies it in and regenerates everything itself; otherwise generate whatever
// is missing (or everything, under forceRegenerate) from the stored source.
let copiedNewSource = manager.refresh()
if !copiedNewSource {
    do {
        if Config.forceRegenerate { log("Force regeneration enabled, rebuilding all wallpapers") }
        try manager.generateWallpapers(force: Config.forceRegenerate)
    } catch {
        log("\(error)")
    }
}

// On every layout switch: first check whether the user picked a new wallpaper
// (this is the only recurring hook we have — see refresh() docs), then apply
// the wallpaper for the new layout.
let layoutChangedCallback: CFNotificationCallback = { _, _, _, _, _ in
    let copied = manager.refresh()
    switcher.applyCurrentLayout(force: copied)
}

CFNotificationCenterAddObserver(
    CFNotificationCenterGetDistributedCenter(),
    nil,
    layoutChangedCallback,
    kTISNotifySelectedKeyboardInputSourceChanged,
    nil,
    .deliverImmediately
)

switcher.applyCurrentLayout(force: true)
log("Watching for keyboard layout changes…")

// NSApplication.run() (rather than a bare CFRunLoopRun) so the process behaves
// as a proper AppKit app in both CLI and .app-bundle form; AppKit is already
// in use via NSScreen/NSWorkspace.
NSApplication.shared.run()
