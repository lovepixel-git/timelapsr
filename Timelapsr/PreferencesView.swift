import AVFoundation
import AppKit
import ScreenCaptureKit
import SwiftUI

/// Represents a user's preferences or settings
///
/// Has two main tabs:
/// - General Settings
/// - Video Settings
struct PreferencesView: View {
  @EnvironmentObject private var preferencesViewModel: PreferencesViewModel
  @EnvironmentObject private var recorderViewModel: RecorderViewModel

  var body: some View {
    TabView {
      generalSettings().tabItem {
        Label("General", systemImage: "gear")
      }.navigationTitle("Timelapsr Settings")
      videoSettings().tabItem {
        Label("Video", systemImage: "video")
      }.navigationTitle("Timelapsr Settings")
      appSettings().tabItem {
        Label("Apps", systemImage: "square.grid.2x2")
      }.navigationTitle("Timelapsr Settings")
    }
    .frame(width: 450)
    .fixedSize()
    .background(VisualEffectView().ignoresSafeArea())
  }

  /// Which running applications appear in the recording.
  ///
  /// This lives in Settings rather than the menu bar because an `NSMenu` dismisses on
  /// every click, so toggling several apps there meant reopening the menu each time.
  /// A window stays put.
  func appSettings() -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Timelapsr App Settings")
        .fontWeight(.semibold)
        .font(.headline)

      Text("Unchecked apps are hidden from the recording.")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack {
        Button("Enable All") { recorderViewModel.resetApps() }
        Button("Invert") { recorderViewModel.invertApplications() }
        Spacer()
        Text("\(enabledAppCount) of \(sortedApps.count) enabled")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(sortedApps, id: \.self) { app in
            appRow(app)
          }
        }
      }
      .frame(height: 260)
    }
    .padding(30)
  }

  /// One checkbox row, with the app's real icon for quick scanning
  @ViewBuilder
  func appRow(_ app: SCRunningApplication) -> some View {
    Toggle(
      isOn: Binding(
        get: { recorderViewModel.apps[app] ?? true },
        set: { _ in recorderViewModel.toggleApp(app: app) }
      )
    ) {
      HStack(spacing: 8) {
        if let running = NSRunningApplication(processIdentifier: app.processID),
          let icon = running.icon
        {
          Image(nsImage: icon).resizable().frame(width: 18, height: 18)
        }
        Text(app.applicationName)
      }
    }
    .toggleStyle(.checkbox)
  }

  /// Only user-facing apps, alphabetised so the list does not reshuffle as processes churn
  private var sortedApps: [SCRunningApplication] {
    recorderViewModel.apps.keys
      .filter { app in
        guard let running = NSRunningApplication(processIdentifier: app.processID) else {
          return false
        }
        return running.activationPolicy == .regular && !app.applicationName.isEmpty
      }
      .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
  }

  private var enabledAppCount: Int {
    sortedApps.filter { recorderViewModel.apps[$0] ?? true }.count
  }

  func generalSettings() -> some View {
    Form {
      Text("Timelapsr General Settings")
        .fontWeight(.semibold)
        .font(.headline)

      Spacer()

      uiSettings()
    }
    .padding(30)
  }

  func videoSettings() -> some View {
    Form {
      Text("Timelapsr Video Settings")
        .fontWeight(.semibold)
        .font(.headline)

      playbackVideoSettings()
      captureVideoSettings()
      outputVideoSettings()
    }
    .padding(30)
  }

  // MARK: Submenus
  @ViewBuilder
  func uiSettings() -> some View {
    Toggle("Show notifications", isOn: $preferencesViewModel.showNotifications)
    Toggle("Show video after saving", isOn: $preferencesViewModel.showAfterSave)

    Spacer()

    HStack {
      Link("About", destination: baseConfig.about)
      Link("Help", destination: baseConfig.help)

      Spacer()

      Button("Write Review") {
        ReviewManager.shared.getReview()
      }.buttonStyle(.borderedProminent)
    }
  }

  /// Renders an idle-timeout duration as a short human label ("30 seconds", "5 minutes")
  func idleTimeoutLabel(_ seconds: Double) -> String {
    seconds < 60
      ? "\(Int(seconds)) seconds"
      : "\(Int(seconds / 60)) minute\(seconds >= 120 ? "s" : "")"
  }

  @ViewBuilder
  func playbackVideoSettings() -> some View {
    Text(
      "An hour long recording would be \(String(format: "%.1f", 60.0 / Double(preferencesViewModel.timeMultiple))) minutes"
    )

    HStack {
      Text("\(String(format: "%.1f", preferencesViewModel.timeMultiple))x faster")
      Slider(value: $preferencesViewModel.timeMultiple, in: .init(uncheckedBounds: (1.0, 240.0)))
    }

    Picker("Pause when idle", selection: $preferencesViewModel.idleTimeout) {
      ForEach(preferencesViewModel.validIdleTimeouts, id: \.self) { seconds in
        Text(seconds == 0 ? "Never" : idleTimeoutLabel(seconds)).tag(seconds)
      }
    }

    Text(
      preferencesViewModel.idleTimeout == 0
        ? "Records continuously, including while you are away from the keyboard."
        : "Stops capturing after \(idleTimeoutLabel(preferencesViewModel.idleTimeout)) without input, so breaks do not become dead air."
    )
    .font(.caption)
    .foregroundStyle(.secondary)

    Picker("Framing", selection: $preferencesViewModel.aspectRatio) {
      ForEach(AspectRatio.options, id: \.self) { ratio in
        Text(AspectRatio.label(ratio)).tag(ratio)
      }
    }

    Picker("Resolution", selection: $preferencesViewModel.resolutionCap) {
      ForEach(ResolutionCap.options, id: \.self) { cap in
        Text(ResolutionCap.label(cap)).tag(cap)
      }
    }

    Text(
      preferencesViewModel.aspectRatio == AspectRatio.native
        ? "Captures the whole display at its native resolution."
        : "Centre-crops the display to \(AspectRatio.label(preferencesViewModel.aspectRatio)). Lowering the resolution is the biggest lever on file size."
    )
    .font(.caption)
    .foregroundStyle(.secondary)

    if #available(macOS 14.0, *) {
      Picker("Output FPS", selection: $preferencesViewModel.fpsDropdown) {
        ForEach(0..<preferencesViewModel.validFPS.count) { index in
          Text("\(preferencesViewModel.validFPS[index]) fps")
        }
      }.onChange(
        of: preferencesViewModel.fpsDropdown,
        { oldValue, newValue in
          preferencesViewModel.framesPerSecond = preferencesViewModel.validFPS[newValue]
        }
      )
      .pickerStyle(MenuPickerStyle())  // Style the picker as a dropdown menu
      .padding()

      if preferencesViewModel.fpsDropdown == preferencesViewModel.validFPS.count - 1 {
        Text("Want an even higher frame rate?")
        Stepper(value: $preferencesViewModel.framesPerSecond, in: 1...240, step: 1) {
          Text("Output FPS: \(preferencesViewModel.framesPerSecond)")
        }.pickerStyle(.segmented)
      }
    }
  }

  @ViewBuilder
  func captureVideoSettings() -> some View {
    if #available(macOS 14.0, *) {
      Picker("Quality", selection: $preferencesViewModel.quality) {
        ForEach(QualitySettings.allCases, id: \.self) { qualitySetting in
          Text(qualitySetting.description)
        }
      }.pickerStyle(SegmentedPickerStyle())
    }

    Picker("Format", selection: $preferencesViewModel.format) {
      ForEach(baseConfig.validFormats, id: \.self) { format in
        Text(baseConfig.convertFormatToString(format))
      }
    }
  }

  @ViewBuilder
  func outputVideoSettings() -> some View {
    let chooseFolder = Button(action: {
      preferencesViewModel.showPicker.toggle()
    }) {
      Label("Choose Output Folder", systemImage: "folder")
    }
    .disabled(preferencesViewModel.showPicker)
    .onChange(of: preferencesViewModel.showPicker, perform: preferencesViewModel.getDirectory)

    // Subtle thing, but using bordered prominent to call attention to something when a default has not been set
    if preferencesViewModel.saveLocation.isInTemporaryFolder() {
      chooseFolder.buttonStyle(.borderedProminent)
    } else {
      chooseFolder
      HStack {
        Text("Save videos to:")
        Text("\(preferencesViewModel.saveLocation.path())").fontWeight(.medium)
      }
    }
  }
}

/// The use of a ``VisualEffectView`` comes from Jack Waugh's [Creating a blurred window background with SwiftUI on macOS](https://zachwaugh.com/posts/swiftui-blurred-window-background-macos)
/// and is something that I think makes the preferences view look better
struct VisualEffectView: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let effectView = NSVisualEffectView()
    effectView.state = .active
    return effectView
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
  }
}

#Preview {
  PreferencesView()
    .frame(width: 700, height: 300)
}
