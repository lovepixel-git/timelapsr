import AVFoundation
import Cocoa
import ScreenCaptureKit
import SwiftUI

let workspace = NSWorkspace.shared

/// Records the output of a `SCDisplay` in a stream-like format using `SCStreamOutput`
///
/// Saves `CMSampleBuffers` into ``input`` and outputs then to ``writer``
class Screen: NSObject, SCStreamOutput, Recordable {
  var state: RecordingState = .stopped
  var lastSavedFrame: CMTime?
  var metaData: OutputInfo = OutputInfo()
  var enabled: Bool = false
  var writer: AVAssetWriter?
  var input: AVAssetWriterInput?

  // ScreenCaptureKit-Specific Functionality
  var screen: SCDisplay
  var stream: SCStream?
  /// Strongly held because `SCStream` keeps only a weak reference to its delegate.
  var streamDelegate: StreamDelegate?

  /// Guards ``isFinalizing`` — `saveRecording()` is reachable from the main thread (user
  /// stop) and from ScreenCaptureKit's queue (``StreamDelegate``) simultaneously.
  private let finalizeLock = NSLock()
  /// Ensures the writer is finalized exactly once. Finalizing twice aborts the process.
  private var isFinalizing = false
  var apps: [SCRunningApplication: Bool] = [:]
  var showCursor: Bool = true

  // Recording timings
  var offset: CMTime = CMTime(seconds: 0.0, preferredTimescale: 60)
  var timeMultiple: Double = 1  // offset set based on settings
  /// Seconds of user inactivity after which frames stop being captured. `0` records
  /// continuously. Cached per recording in ``setupWriter``.
  var idleTimeout: Double = 0
  /// Accumulated wall-clock time skipped while idle, collapsed out of the timeline.
  var skippedDuration: CMTime = .zero
  /// Presentation timestamp at which the current idle stretch began, if any.
  var idleStartedAt: CMTime?
  /// Framing and output size, resolved once per recording in ``setupStream`` and reused by
  /// ``setupWriter`` so both agree.
  var geometry = CaptureGeometry(sourceRect: nil, width: 0, height: 0)
  var frameCount: Int = 0
  var frameChanged = true

  var lastAppendedFrame: CMTime = .zero
  var tmpFrameBuffer: CMSampleBuffer?

  var height: Int?
  var width: Int?

  override var description: String {
    if height == nil || width == nil {
      let pixelRatio = getPixelRatio(for: screen.displayID) ?? 1.0

      self.width = Int(CGFloat(screen.width) * pixelRatio)
      self.height = Int(CGFloat(screen.height) * pixelRatio)
    }

    return "[\(width ?? 0) x \(height ?? 0)] - Display \(screen.displayID)"
  }

  init(screen: SCDisplay, showCursor: Bool) {
    self.screen = screen
    self.showCursor = showCursor
  }

  // MARK: User Interaction
  func startRecording(excluding: [SCRunningApplication], showCursor: Bool) {
    guard self.enabled else { return }
    guard self.state != .recording else { return }

    self.showCursor = showCursor

    // Reset the once-only finalization latch for this new recording. Without this, the
    // second recording in a session would be refused as a duplicate save.
    finalizeLock.lock()
    isFinalizing = false
    finalizeLock.unlock()

    // Idle accounting is per-recording.
    skippedDuration = .zero
    idleStartedAt = nil

    self.state = .recording

    setup(path: getFilename(), excluding: excluding)
  }

  func pauseRecording() {
    self.state = .paused
  }

  func resumeRecording() {
    self.state = .recording
  }

  /// Saves recording and stops `stream`
  func saveRecording() {
    guard self.enabled else { return }

    // Finalization must happen exactly once. Two callers can reach this: the user
    // stopping, and `StreamDelegate` salvaging an unexpected stream stop. Without this
    // guard the second call reaches `finishWriting()` on an already-completed writer,
    // which raises NSInternalInconsistencyException — an ObjC exception Swift cannot
    // catch, so it aborts the process. The check and set are serialized on
    // `finalizeLock` because the delegate is invoked on ScreenCaptureKit's queue while
    // the user stop arrives on the main thread, so check-then-act would otherwise race.
    finalizeLock.lock()
    if isFinalizing {
      finalizeLock.unlock()
      logger.log("Screen -- finalization already in progress, ignoring duplicate save")
      return
    }
    isFinalizing = true
    finalizeLock.unlock()

    guard let writer = writer, let input = input else {
      isFinalizing = false
      return
    }

    // Set the state before stopping the stream so `handleVideo` starts rejecting
    // in-flight buffers immediately. Ordering matters: any frame appended after
    // `markAsFinished()` below fails the writer.
    self.state = .stopped

    logger.log("Screen -- saved recording")

    let stream = self.stream

    Task {
      // `stopCapture()` must be awaited. Fire-and-forget returns while frames are
      // still in flight, which is what raced `markAsFinished()` previously.
      if let stream {
        do {
          try await stream.stopCapture()
        } catch {
          logger.error("Failed to stop capture: \(error.localizedDescription)")
        }
      }

      // Only a writer that actually started can be finalized. If the stream died before
      // the first frame arrived, status is still `.unknown`, and `markAsFinished()`
      // aborts the process just as surely as double-finalizing does.
      guard writer.status == .writing else {
        logger.error(
          "Writer never started (status \(writer.status.rawValue)); nothing to finalize")
        self.writer = nil
        self.input = nil
        self.stream = nil
        return
      }

      input.markAsFinished()

      // Await finalization. `finishWriting` is what writes the moov atom; when
      // nothing waited on its completion handler, teardown could beat it and leave
      // the file unplayable.
      await writer.finishWriting()

      if writer.status == .completed {
        // Asset writing completed successfully

        if UserDefaults.standard.bool(forKey: "showAfterSave")
          || writer.outputURL.isInTemporaryFolder()
        {
          workspace.open(writer.outputURL)
        }

        sendNotification(title: "\(self) saved", body: "Saved video", url: writer.outputURL)

        logger.log("Saved video to \(writer.outputURL.absoluteString)")
      } else if writer.status == .failed {
        // Asset writing failed with an error
        if let error = writer.error {
          logger.error("Asset writing failed with error: \(error.localizedDescription)")
          sendNotification(
            title: "Could not save asset", body: "\(error.localizedDescription)", url: nil)
        }
      }

      // Release the handles so a stale writer can never be finalized again.
      self.writer = nil
      self.input = nil
      self.stream = nil
      self.streamDelegate = nil
    }
  }

  /// Sets up both *writing* and *saving*
  ///
  /// Creates ``writer`` and ``input`` to write assets
  /// Sets up the stream to use ``self`` as `SCStreamOutput`
  func setup(path: String, excluding: [SCRunningApplication]) {
    Task(priority: .userInitiated) {
      do {
        try setupStream(screen: screen, showCursor: showCursor, excluding: excluding)

        (self.writer, self.input) = try setupWriter(screen: screen, path: path)

        try await stream!.startCapture()

        logger.debug("Setup stream")
      } catch {
        logger.error("Failed to setup stream")
      }
    }
  }

  /// Sets up the `AVAssetWriter` and `AVAssetWriterInput`
  ///
  /// ``stream(_:didOutputSampleBuffer:of:)`` relies on this to save data
  func setupWriter(screen: SCDisplay, path: String) throws -> (AVAssetWriter, AVAssetWriterInput) {
    // TODO: Update this so hevc_displayP3 is not the assumed color space
    //
    // The display color space can easily be fetched dynamically using SCDisplay.CGDirectDisplayID
    //
    // see:
    // https://developer.apple.com/documentation/coregraphics/1454190-cgdisplaycopycolorspace

    // creates a custom-defined config for the P3 color space
    let config: VideoSettings = .hevcDisplayP3

    // uses a settings recommender to get the video settings
    let settingsAssistant = AVOutputSettingsAssistant(preset: config.preset)!

    // Geometry is resolved in `setupStream`, which always runs first (see `setup`). Falling
    // back to the native size keeps this safe if that order ever changes.
    let pixelRatio = getPixelRatio(for: screen.displayID) ?? 1.0
    let width =
      geometry.width > 0 ? geometry.width : Int(CGFloat(screen.width) * pixelRatio)
    let height =
      geometry.height > 0 ? geometry.height : Int(CGFloat(screen.height) * pixelRatio)

    settingsAssistant.sourceVideoFormat = try CMVideoFormatDescription(
      videoCodecType: .hevc, width: width, height: height)

    var settings = settingsAssistant.videoSettings!
    settings[AVVideoWidthKey] = width
    settings[AVVideoHeightKey] = height
    settings[AVVideoColorPropertiesKey] = config.colorProperties

    // more entropy in the video -> the higher the bitrate
    if var compressionProperties = settings[AVVideoCompressionPropertiesKey] as? [String: Any] {
      compressionProperties.removeValue(forKey: AVVideoAverageBitRateKey)
      compressionProperties[AVVideoQualityKey] = baseConfig.quality
      settings[AVVideoCompressionPropertiesKey] = compressionProperties
    }

    // Gets a valid file type, but replaces it if in preferences
    var fileType: AVFileType = baseConfig.validFormats.first!
    if let fileTypeValue = UserDefaults.standard.object(forKey: "format"),
      let preferenceType = fileTypeValue as? AVFileType
    {
      fileType = preferenceType
    }

    // Creates a valid url path (may not be user-specified)
    let url = getFileDestination(path: path)
    let writer = try AVAssetWriter(url: url, fileType: fileType)

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = true

    writer.add(input)

    // timeMultiple setup -> for some reason, does not return optional
    // `double(forKey:)` yields 0 for an unset or invalid key, and 0 becomes an infinite
    // multiplier in `appendBuffer`. Keep the declared default rather than trusting it.
    let storedTimeMultiple = UserDefaults.standard.double(forKey: "timeMultiple")
    timeMultiple = storedTimeMultiple > 0 ? storedTimeMultiple : timeMultiple

    // Read once per recording rather than per frame; `handleVideo` runs at the full
    // display refresh rate. Changing the preference mid-recording has no effect,
    // which matches how `timeMultiple` already behaves.
    idleTimeout = max(0, UserDefaults.standard.double(forKey: "idleTimeout"))

    return (writer, input)
  }

  /// Creates an `SCStream` with correct `filter` and `configuration`. ``self`` is set to receive this data
  func setupStream(screen: SCDisplay, showCursor: Bool, excluding: [SCRunningApplication]) throws {
    let contentFilter = SCContentFilter(
      display: screen,
      excludingApplications: excluding,
      exceptingWindows: []
    )

    let config = SCStreamConfiguration()
    config.queueDepth = 20
    config.showsCursor = showCursor
    config.capturesAudio = false
    config.backgroundColor = .white

    // Resolve framing and resolution once and cache it. `setupWriter` reads the same
    // values, so the stream and the asset writer can never disagree about output size.
    // Previously each computed dimensions independently — one from
    // `contentFilter.pointPixelScale`, the other from `getPixelRatio(for:)` — which was
    // only correct as long as those two agreed.
    let resolved = resolveCaptureGeometry(
      displayWidth: screen.width,
      displayHeight: screen.height,
      pixelScale: CGFloat(contentFilter.pointPixelScale)
    )
    self.geometry = resolved

    // Crop to the chosen aspect ratio. Left unset, the whole display is captured.
    if let sourceRect = resolved.sourceRect {
      config.sourceRect = sourceRect
    }

    config.width = resolved.width
    config.height = resolved.height

    // color settings
    // note: in display settings, you can set the color space. So, this should probably not be hard-coded either
    // source: https://support.apple.com/guide/mac-help/displays-settings-on-mac-mh40768
    config.colorSpaceName = CGColorSpace.displayP3
    config.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked

    if #available(macOS 14.0, *) {
      // Getting quality from user defaults
      if let qualityValue = UserDefaults.standard.object(forKey: "quality"),
        let quality = qualityValue as? QualitySettings
      {
        config.captureResolution = .nominal
      }

      config.streamName = "\(screen.displayID) Screen Recording"
      config.shouldBeOpaque = true  // Turns off transparency
    }

    // Retain the delegate. `SCStream` holds it weakly, so the previous inline
    // `StreamDelegate()` could be deallocated immediately, meaning stream failures
    // were never reported at all.
    let delegate = StreamDelegate(owner: self)
    self.streamDelegate = delegate

    stream = SCStream(
      filter: contentFilter,
      configuration: config,
      delegate: delegate
    )

    guard let stream = stream else { return }

    try stream.addStreamOutput(
      self,
      type: .screen,
      sampleHandlerQueue: .global(qos: .userInitiated)
    )
  }

  /// Generates a filename specific to `SCDisplay` and `CMTime`
  func getFilename() -> String {
    return "display\(screen.displayID)-\(dateExtension)\(fileExtension)"
  }

  /// Saves each `CMSampleBuffer` from the screen
  func stream(_ stream: SCStream, didOutputSampleBuffer: CMSampleBuffer, of: SCStreamOutputType) {
    guard self.state == .recording else { return }

    switch of {
    case .screen:
      handleVideo(buffer: didOutputSampleBuffer)
    case .audio:
      logger.debug("Audio should not be captured")
    default:
      logger.error("Unknown future case")
    }
  }

  /// Receives a list of `CMSampleBuffers` and uses `appendBuffer` to save them
  func handleVideo(buffer: CMSampleBuffer) {
    guard self.input != nil else {  // both
      logger.error("No AVAssetWriter with the name `input` is present")
      return
    }

    // Drop buffers that arrive after the recording stopped. `stopCapture()` is
    // asynchronous, so ScreenCaptureKit keeps delivering in-flight frames for a
    // short window after `saveRecording()` runs. Appending any of them once
    // `input.markAsFinished()` has been called moves the writer to `.failed`, and a
    // failed writer never emits the moov atom, leaving an unplayable ftyp+mdat file.
    guard self.state == .recording else { return }

    // Skip capture while the user is away, so stepping out for coffee does not become
    // minutes of motionless footage. A timeout of 0 records continuously.
    //
    // Dropping frames alone is not enough: presentation timestamps are wall-clock, so a
    // skipped break would still occupy its full (divided) duration as a frozen frame.
    // The elapsed idle span is therefore measured and accumulated into
    // `skippedDuration`, which `appendBuffer` subtracts to collapse the gap.
    if idleTimeout > 0, systemIdleSeconds >= idleTimeout {
      if idleStartedAt == nil { idleStartedAt = buffer.presentationTimeStamp }
      return
    }

    if let idleStart = idleStartedAt {
      skippedDuration = skippedDuration + (buffer.presentationTimeStamp - idleStart)
      idleStartedAt = nil
      logger.log("Resumed after idle; total skipped \(self.skippedDuration.seconds)s")
    }

    guard
      let attachmentsArray: NSArray = CMSampleBufferGetSampleAttachmentsArray(
        buffer,
        createIfNecessary: false),
      let attachments: NSDictionary = attachmentsArray.firstObject as? NSDictionary
    else {
      logger.error("Attachments Array does not work")
      return
    }

    // the status needs to be not `.complete`
    guard let rawStatusValue = attachments[SCStreamFrameInfo.status] as? Int,
      let status = SCFrameStatus(rawValue: rawStatusValue), status == .complete
    else {
      return
    }

    guard let writer = self.writer else { return }

    // Start the writer if not started and use the current buffer's timestamp as a start point
    if writer.status == .unknown {
      writer.startWriting()
      offset = buffer.presentationTimeStamp
      writer.startSession(atSourceTime: offset)
      return
    }

    guard writer.status != .failed else {
      logger.log("Screen - failed")
      return
    }

    (tmpFrameBuffer, lastAppendedFrame, frameChanged) = appendBuffer(
      buffer: buffer, source: .screen)

    // Logs the frames
    frameCount += 1
    if frameCount % baseConfig.logFrequency == 0 {
      logger.log("\(self) Appended buffers \(self.frameCount)")
    }
  }
}

/// Defines behavior when the state of the `SCStream` changes.
///
/// Technically required, but less used in this instance
class StreamDelegate: NSObject, SCStreamDelegate {
  /// Weak to avoid a retain cycle — the ``Screen`` owns this delegate.
  weak var owner: Screen?

  init(owner: Screen? = nil) {
    self.owner = owner
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    logger.error("The stream stopped with \(error.localizedDescription)")

    // Salvage whatever was captured. A stream can die mid-session for reasons the
    // user never asked for: display sleep, a monitor being unplugged, the app being
    // force quit. This handler previously only logged, so the AVAssetWriter was
    // never finalized, no moov atom was written, and the whole session was lost
    // rather than merely truncated.
    //
    // The state check skips the normal stop path — `saveRecording()` sets `.stopped`
    // before calling `stopCapture()` — which also prevents recursion here.
    guard let owner, owner.state == .recording else { return }

    logger.log("Stream stopped unexpectedly, finalizing to salvage the recording")
    owner.saveRecording()

    // Bring the UI in line with reality. Without this the menu bar keeps showing a
    // recording in progress and still offers "Exit and Save Recording" for a session
    // that has already been finalized.
    Task { @MainActor in
      RecorderViewModel.shared.state = .stopped
    }
  }
}

/// Gets the pixel ratio or `bakingScaleFactor` of the screen before starting recording
///
/// This is important because while Apple displays use a pixel ratio of 2.0, this may not be the case for
/// external monitors
func getPixelRatio(for displayID: CGDirectDisplayID) -> CGFloat? {
  guard
    let screens = NSScreen.screens.first(where: {
      guard
        let screenID = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          as? CGDirectDisplayID
      else {
        return false
      }
      return screenID == displayID
    })
  else {
    return nil
  }

  return screens.backingScaleFactor
}
