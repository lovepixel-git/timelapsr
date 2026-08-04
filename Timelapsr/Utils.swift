import AVFoundation
import Foundation
import ScreenCaptureKit

/// Resolved capture geometry, shared by the `SCStream` configuration and the
/// `AVAssetWriter` so the two can never disagree about output size.
struct CaptureGeometry {
  /// Region of the display to capture, in points. `nil` captures the whole display.
  var sourceRect: CGRect?
  /// Output width in pixels. Always even.
  var width: Int
  /// Output height in pixels. Always even.
  var height: Int
}

/// Aspect ratios offered for framing, as width / height. `0` means "match the display".
enum AspectRatio {
  static let native: Double = 0
  static let options: [Double] = [0, 16.0 / 9.0, 4.0 / 3.0, 1.0, 9.0 / 16.0]

  static func label(_ ratio: Double) -> String {
    switch ratio {
    case 0: return "Native"
    case 16.0 / 9.0: return "16:9"
    case 4.0 / 3.0: return "4:3"
    case 1.0: return "1:1 Square"
    case 9.0 / 16.0: return "9:16 Vertical"
    default: return String(format: "%.2f", ratio)
    }
  }
}

/// Maximum output long-edge in pixels. `0` keeps the display's native resolution.
enum ResolutionCap {
  static let options: [Int] = [0, 3840, 2560, 1920, 1280]

  static func label(_ cap: Int) -> String {
    switch cap {
    case 0: return "Native"
    case 3840: return "4K (3840)"
    case 2560: return "1440p (2560)"
    case 1920: return "1080p (1920)"
    case 1280: return "720p (1280)"
    default: return "\(cap) px"
    }
  }
}

/// Resolves the capture rectangle and output pixel size from the user's framing and
/// resolution preferences.
///
/// Framing crops a centred region of the display to the requested aspect ratio. The
/// resolution cap then scales that result down so its long edge never exceeds the limit,
/// which is the main lever on file size. Dimensions are forced even because H.264 and
/// HEVC reject odd ones.
func resolveCaptureGeometry(
  displayWidth: Int, displayHeight: Int, pixelScale: CGFloat
) -> CaptureGeometry {
  let aspect = UserDefaults.standard.double(forKey: "aspectRatio")
  let cap = UserDefaults.standard.integer(forKey: "resolutionCap")

  let fullWidth = CGFloat(displayWidth)
  let fullHeight = CGFloat(displayHeight)

  var cropWidth = fullWidth
  var cropHeight = fullHeight
  var sourceRect: CGRect?

  // Centre-crop to the requested aspect ratio, keeping as much of the display as fits.
  if aspect > 0, fullHeight > 0 {
    if fullWidth / fullHeight > aspect {
      cropWidth = cropHeight * aspect  // display is wider than the target
    } else {
      cropHeight = cropWidth / aspect  // display is taller than the target
    }
    sourceRect = CGRect(
      x: (fullWidth - cropWidth) / 2,
      y: (fullHeight - cropHeight) / 2,
      width: cropWidth,
      height: cropHeight
    )
  }

  var pixelWidth = cropWidth * pixelScale
  var pixelHeight = cropHeight * pixelScale

  if cap > 0 {
    let longEdge = max(pixelWidth, pixelHeight)
    if longEdge > CGFloat(cap) {
      let scale = CGFloat(cap) / longEdge
      pixelWidth *= scale
      pixelHeight *= scale
    }
  }

  // `& ~1` clears the low bit, forcing even dimensions.
  return CaptureGeometry(
    sourceRect: sourceRect,
    width: max(2, Int(pixelWidth.rounded()) & ~1),
    height: max(2, Int(pixelHeight.rounded()) & ~1)
  )
}

/// Security-scoped bookmark handling for the user's chosen save folder.
///
/// The app is sandboxed with `com.apple.security.files.user-selected.read-write`, so a
/// plain path carries no write access — only a folder the user picked through an
/// `NSOpenPanel` does, and even that access dies when the app relaunches unless it is
/// persisted as a bookmark. Storing a bare `URL` (what the picker used to do) therefore
/// worked until the next launch, after which every recording silently fell back to the
/// container's temporary directory.
enum SaveLocationBookmark {
  private static let key = "saveLocationBookmark"

  /// Persists a folder the user just picked, so access survives relaunches.
  static func store(_ url: URL) {
    do {
      let data = try url.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      UserDefaults.standard.set(data, forKey: key)
    } catch {
      logger.error("Could not bookmark save location: \(error.localizedDescription)")
    }
  }

  /// Resolves the stored folder and begins access.
  ///
  /// Returns `nil` when nothing is stored or the folder has gone (an unplugged drive, a
  /// renamed directory). The caller **must** balance a non-nil result with
  /// ``endAccess(_:)``, or the sandbox leaks the grant for the process lifetime.
  static func resolveAndBeginAccess() -> URL? {
    guard let data = UserDefaults.standard.data(forKey: key) else { return nil }

    var stale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: data,
        options: .withSecurityScope,
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
    else {
      logger.error("Save-location bookmark could not be resolved")
      return nil
    }

    // Bookmarks go stale when the folder moves or the volume is remounted. Refresh it
    // while access is held, otherwise it degrades again on the next launch.
    if stale { store(url) }

    guard url.startAccessingSecurityScopedResource() else {
      logger.error("Denied security-scoped access to the save location")
      return nil
    }
    return url
  }

  static func endAccess(_ url: URL?) {
    url?.stopAccessingSecurityScopedResource()
  }
}

/// Seconds since the user last produced any HID input (key, mouse move, click, scroll).
///
/// Used to pause capture while the user is away so long breaks do not become dead air
/// in the finished timelapse. `kCGAnyInputEventType` is `~0`, which has no Swift
/// constant, so the raw value is constructed directly.
var systemIdleSeconds: Double {
  guard let anyInputEvent = CGEventType(rawValue: ~0) else { return 0 }
  return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInputEvent)
}

/// Output information consists of details about each stream designed to be shared by a recorder view model
struct OutputInfo {
  var frameRate: Float = 25.0
  var timeDivisor: Float = 25.0

  /// Determines the time each frame should be shown on the screen
  func getFrameTime() -> Float { 1 / self.frameRate * self.timeDivisor }
}

/// Represents the possible states of the recording system
/// Converting into a string yields the app's icon
enum RecordingState: CustomStringConvertible {
  var description: String {
    switch self {
    case .stopped:
      return "record.circle.fill"
    case .paused:
      return "play.fill"
    case .recording:
      return "pause.fill"
    }
  }

  case stopped
  case recording
  case paused
}

/// Wraps the `SCStreamConfiguration.captureResolution` for user interface
enum QualitySettings: String, Codable, CaseIterable {
  case low
  case medium
  case high

  var description: LocalizedStringResource {
    switch self {
    case .low:
      return LocalizedStringResource("Low", comment: "low in terms of recording quality")
    case .medium:
      return LocalizedStringResource("Medium", comment: "medium in terms of recording quality")
    case .high:
      return LocalizedStringResource("High", comment: "high in terms of recording quality")
    }
  }
}

/// Allows sorting by `bundleIdentifier` so the displayed order is consistent
/// even when new `SCRunningApplication`s are added
extension SCRunningApplication: @retroactive Comparable {
  public static func < (lhs: SCRunningApplication, rhs: SCRunningApplication) -> Bool {
    lhs.bundleIdentifier < rhs.bundleIdentifier
  }
}

/// Gets the App Version as a ``String``
extension Bundle {
  /// Fetches the current bundle version of the app.
  static var currentAppVersion: String? {
    #if os(macOS)
      let infoDictionaryKey = "CFBundleShortVersionString"
    #else
      let infoDictionaryKey = "CFBundleVersion"
    #endif

    return Bundle.main.object(forInfoDictionaryKey: infoDictionaryKey) as? String
  }
}
