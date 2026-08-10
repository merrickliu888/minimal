import AppKit
import CoreText

/// Fonts shipped inside the app bundle. Registration is process-scoped, so
/// users get the intended terminal font without installing anything globally.
enum BundledFonts {
    private static let terminalResourceName = "JetBrainsMonoNerdFontMono-Regular"
    private static let terminalPostScriptName = "JetBrainsMonoNFM-Regular"

    static func register() {
        guard NSFont(name: terminalPostScriptName, size: 12) == nil else { return }
        guard let url = Bundle.main.url(
            forResource: terminalResourceName,
            withExtension: "ttf",
            subdirectory: "Fonts"
        ) else {
            NSLog("Bundled terminal font is missing from the app resources")
            return
        }

        var registrationError: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(
            url as CFURL,
            .process,
            &registrationError
        )
        if !registered, NSFont(name: terminalPostScriptName, size: 12) == nil {
            let detail = registrationError?.takeRetainedValue().localizedDescription
                ?? "unknown error"
            NSLog("Could not register bundled terminal font: %@", detail)
        }
    }

    static func terminalFont(size: CGFloat) -> NSFont {
        NSFont(name: terminalPostScriptName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
