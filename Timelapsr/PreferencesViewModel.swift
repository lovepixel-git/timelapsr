import AVFoundation
import SwiftUI

/// Manages data for the ``PreferencesView``
class PreferencesViewModel: ObservableObject {
  @AppStorage("showNotifications") var showNotifications = false
  @AppStorage("showAfterSave") var showAfterSave = false

  @AppStorage("framesPerSecond") var framesPerSecond = 30
  // Valid frames per second
  let validFPS = [10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60]

  @AppStorage("FPS") var fps: Double = 30.0
  @AppStorage("timeMultiple") var timeMultiple: Double = 5.0

  /// Seconds of user inactivity after which frames stop being captured. `0` disables
  /// the behaviour and records continuously.
  @AppStorage("idleTimeout") var idleTimeout: Double = 0
  let validIdleTimeouts: [Double] = [0, 30, 60, 120, 300, 600]

  /// Framing aspect ratio as width / height. `0` matches the display.
  @AppStorage("aspectRatio") var aspectRatio: Double = AspectRatio.native
  /// Maximum output long-edge in pixels. `0` keeps native resolution.
  @AppStorage("resolutionCap") var resolutionCap: Int = 0

  @AppStorage("quality") var quality: QualitySettings = .medium

  @AppStorage("format") var format: AVFileType = baseConfig.validFormats.first!

  @AppStorage("saveLocation") var saveLocation: URL = FileManager.default
    .homeDirectoryForCurrentUser
  @Published var showPicker = false
  @Published var fpsDropdown = 4
  @Published var fpsInput = ""

  @Environment(\.openURL) var openURL

  // MARK: Intents

  /// Gets the user to specify where they want to save output videos
  func getDirectory(newVal: Bool) {
    guard showPicker else { return }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.begin { [self] res in
      showPicker = false
      guard res == .OK, let pickedURL = panel.url else { return }

      // Persist a security-scoped bookmark, not just the path. The app is sandboxed, so
      // the access granted by this panel expires when the app quits; without a bookmark
      // the next launch can no longer write there and every recording silently lands in
      // the container's temporary directory instead.
      SaveLocationBookmark.store(pickedURL)
      saveLocation = pickedURL
    }
  }
}
