import AVFoundation
import ScreenCaptureKit
import UserNotifications

/// Represents an object interactable with a ``RecorderViewModel``
protocol Recordable: CustomStringConvertible {
  var metaData: OutputInfo { get set }
  var state: RecordingState { get set }
  var enabled: Bool { get set }

  var writer: AVAssetWriter? { get set }
  var input: AVAssetWriterInput? { get set }

  var timeMultiple: Double { get set }
  var offset: CMTime { get set }
  /// Total wall-clock time deliberately skipped (idle periods), collapsed out of the
  /// output timeline by ``offsettingTiming(by:skipping:multiplier:)``.
  var skippedDuration: CMTime { get set }
  /// Save folder currently held under security scope, released once writing finishes.
  var scopedSaveLocation: URL? { get set }
  var frameCount: Int { get set }

  var lastAppendedFrame: CMTime { get set }
  var tmpFrameBuffer: CMSampleBuffer? { get set }
  var frameChanged: Bool { get set }
  var frameRate: CMTimeScale { get }

  // MARK: Intents
  mutating func startRecording()
  mutating func stopRecording()
  mutating func resumeRecording()
  mutating func pauseRecording()
  mutating func saveRecording()

  func getFilename() -> String
}

extension Recordable {
  var frameRate: CMTimeScale {
    guard writer != nil else { return .zero }
    return CMTimeScale(30.0)
  }

  /// Starts recording if ``enabled``
  /// This does not actually get run because Screen and Camera need different arguments
  /// However, I found it weird to have a `stopRecording`, but not a `startRecording`
  mutating func startRecording() {
    guard self.enabled else { return }
    guard self.state != .recording else { return }

    self.state = .recording
  }

  /// Stops recording if ``enabled``
  mutating func stopRecording() {
    guard self.enabled else { return }

    self.state = .stopped
    saveRecording()
  }

  mutating func resumeRecording() {
    self.state = .recording
  }

  mutating func pauseRecording() {
    self.state = .paused
  }

  mutating func saveRecording() {
    logger.log("Saving recorder")
  }

  /// Turns a `String` into a valid file path (may be a temporary folder)
  ///
  /// - Note: On success the caller holds security-scoped access to the destination folder
  ///   and must release it via ``SaveLocationBookmark/endAccess(_:)`` once writing
  ///   finishes. ``scopedSaveLocation`` records the URL for exactly that purpose.
  /// - Returns: the destination file URL, plus the folder now held under security scope
  ///   (`nil` if none). Classes cannot call `mutating` protocol members, so the scope is
  ///   returned for the caller to store rather than assigned here.
  func getFileDestination(path: String) -> (url: URL, scope: URL?) {
    var url = URL(filePath: path, directoryHint: .notDirectory, relativeTo: .temporaryDirectory)
    var scope: URL?

    // Prefer the bookmarked folder. Under the sandbox this is the only way to write
    // outside the container, and it is what keeps the choice working across relaunches.
    if let scoped = SaveLocationBookmark.resolveAndBeginAccess() {
      scope = scoped
      url = URL(filePath: path, directoryHint: .notDirectory, relativeTo: scoped)
    } else if let location = UserDefaults.standard.url(forKey: "saveLocation"),
      FileManager.default.fileExists(atPath: location.path),
      FileManager.default.isWritableFile(atPath: location.path)
    {
      // Unsandboxed builds, or a folder that happens to be writable anyway.
      url = URL(filePath: path, directoryHint: .notDirectory, relativeTo: location)
    } else {
      logger.error(
        "No writable save location; falling back to the temporary directory. Pick a folder via Settings so a security-scoped bookmark is created."
      )
    }

    do {  // delete old video
      try FileManager.default.removeItem(at: url)
    } catch { logger.error("Failed to delete file \(error.localizedDescription)") }

    return (url, scope)
  }

  /// Sends a notification using `UserNotifications` framework
  /// Exists on `Recordable` because this can be modified is an **iOS** application is in the future
  func sendNotification(title: String, body: String, url: URL?) {
    guard UserDefaults.standard.bool(forKey: "showNotifications") else { return }

    let center = UNUserNotificationCenter.current()

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body

    if let url = url {
      content.userInfo = ["fileURL": url.absoluteString]
    }

    content.sound = .default  // .defaultCritical

    let request = UNNotificationRequest(
      identifier: "recordingStatusNotifications", content: content, trigger: nil)

    center.add(request) { error in
      if let error = error {
        logger.log("Failed to send notification with error \(error)")
      }
    }
  }

  /// Appends a buffer depending on a couple of factors
  /// The `tmpFrameBuffer` is used to keep track of deletable buffers
  /// Saves **30%** of space at only **2x** speed. Ostensibly much higher for higher time multiples
  func appendBuffer(buffer: CMSampleBuffer, source: InputTypes) -> (CMSampleBuffer, CMTime, Bool) {
    guard let input = input else { return (buffer, lastAppendedFrame, true) }

    // Determines if we should append
    let currentPTS = buffer.presentationTimeStamp

    let differenceTime = CMTimeMultiplyByFloat64(
      CMTime(seconds: 1.0 / 30, preferredTimescale: 30), multiplier: timeMultiple)

    var changed = frameChanged
    switch source {
    case .camera:
      changed = true  // a camera is always changed
    case .screen:
      // needs to get the attachments array
      if !changed,
        let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
          buffer,
          createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
        let attachments = attachmentsArray.first
      {
        // okay, so we have attachments
        if let rects = attachments[.dirtyRects] as? NSArray, rects.count > 0 {
          changed = true  // if we have dirty rects, something changed
        }
      } else {
        // if we can not extract, then changed MUST be true
        changed = true
      }
    default:
      logger.warning("Unrecognized input device")
    }

    guard currentPTS > lastAppendedFrame + differenceTime || (source == .screen && !frameChanged)
    else {
      // okay to replace the tmp buffer
      return (buffer, lastAppendedFrame, changed)
    }

    guard
      let newBuffer = try? tmpFrameBuffer?.offsettingTiming(
        by: offset, skipping: skippedDuration, multiplier: 1.0 / timeMultiple)
    else {
      return (buffer, lastAppendedFrame, true)
    }

    guard input.append(newBuffer) else {
      // A rejected append is not cosmetic: it means the writer has moved to `.failed`,
      // and from here the session can no longer produce a moov atom. Log why, loudly,
      // because the previous bare message made this indistinguishable from a dropped
      // frame.
      logger.error(
        "input.append rejected at pts \(newBuffer.presentationTimeStamp.seconds)s — writer is now unrecoverable. Underlying: \(String(describing: self.writer?.error))"
      )
      return (buffer, lastAppendedFrame, true)
    }

    if let tmpFrameBuffer = tmpFrameBuffer {
      // we have not changed originally
      return (buffer, tmpFrameBuffer.presentationTimeStamp, source != .screen)
    } else {
      // Initial condition
      return (buffer, buffer.presentationTimeStamp, source != .screen)
    }

  }

  /// Returns a `String` representation of the current date, used by both `Camera` and `Screen`
  ///  The intention is for this to be utilized
  var dateExtension: String {
    let currentDate = Date()

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

    let formattedDate = formatter.string(from: currentDate)

    return formattedDate
  }

  /// Returns a valid file extension for recording formats
  var fileExtension: String {
    var fileType: AVFileType = baseConfig.validFormats.first!
    if let fileTypeValue = UserDefaults.standard.object(forKey: "format"),
      let preferenceType = fileTypeValue as? AVFileType
    {
      fileType = preferenceType
    }

    return baseConfig.convertFormatToString(fileType)
  }

  /// Returns the length of the recording
  var time: CMTime {
    guard let tmpFrameBuffer = tmpFrameBuffer else { return CMTime.zero }

    return CMTimeMultiplyByFloat64(
      (tmpFrameBuffer.presentationTimeStamp - offset), multiplier: 1 / timeMultiple)
  }
}

extension CMSampleBuffer {
  /// Changes the speed of the sample buffer by `multiplier` in a recording with the `by` start time
  ///
  /// Does the work to create the time lapse
  /// - Parameter skipping: Wall-clock time spent idle and deliberately not captured.
  ///   Subtracting it collapses those gaps, so a break is removed from the timeline
  ///   rather than becoming a frozen frame of the same (divided) duration.
  func offsettingTiming(by offset: CMTime, skipping: CMTime = .zero, multiplier: Float64) throws
    -> CMSampleBuffer
  {
    let newSampleTimingInfos: [CMSampleTimingInfo]

    do {
      newSampleTimingInfos = try sampleTimingInfos().map {
        var newSampleTiming = $0
        newSampleTiming.presentationTimeStamp =
          offset
          + CMTimeMultiplyByFloat64(
            $0.presentationTimeStamp - offset - skipping, multiplier: multiplier)
        return newSampleTiming
      }
    } catch {
      newSampleTimingInfos = []
    }
    let newSampleBuffer = try CMSampleBuffer(copying: self, withNewTiming: newSampleTimingInfos)
    return newSampleBuffer
  }
}

extension URL {
  /// Returns whether or not the url is in the `URL.temporaryDirectory`
  func isInTemporaryFolder() -> Bool {
    return self.absoluteString.hasPrefix(URL.temporaryDirectory.absoluteString)
  }
}

/// Two-type input types
/// Used to not record non-changing frames
enum InputTypes {
  case camera
  case screen
}
