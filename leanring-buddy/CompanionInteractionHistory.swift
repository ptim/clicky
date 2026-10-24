//
//  CompanionInteractionHistory.swift
//  leanring-buddy
//
//  A short in-memory log of recent push-to-talk interactions for the
//  panel's History section: what was heard, the screenshot that was sent,
//  what the model answered, and where it said to point. It exists to debug
//  pointing, so it keeps the exact image and coordinate space the model saw.
//
//  Nothing is written to disk except the temporary PNGs Quick Look needs,
//  and the history is lost when the app quits.
//

import AppKit
import Combine
import Quartz

struct CompanionInteractionHistoryEntry: Identifiable {
    let id = UUID()
    let interactionDate: Date
    /// The transcript as speech-to-text interpreted it.
    let transcript: String
    /// Which backend and model answered, e.g. "Ollama · gemma4:latest".
    let chatModelDescription: String
    /// The screenshot sent with the question. Nil for text-only models,
    /// which get no screenshot, or when the pipeline failed before capture.
    let screenCapture: CompanionScreenCapture?
    /// The full response, including the [POINT] tag.
    let rawResponseText: String?
    /// The [POINT] coordinate in the screenshot's pixel space (top-left origin).
    let pointCoordinate: CGPoint?
    let pointElementLabel: String?
    /// Set when the pipeline failed; the response fields are then nil.
    let errorMessage: String?

    /// Rendered once when the entry is created rather than on every panel
    /// redraw, because redrawing a full screenshot is not free.
    let annotatedScreenshotImage: CGImage?
    let pointCropImage: CGImage?

    init(
        interactionDate: Date,
        transcript: String,
        chatModelDescription: String,
        screenCapture: CompanionScreenCapture?,
        rawResponseText: String?,
        pointCoordinate: CGPoint?,
        pointElementLabel: String?,
        errorMessage: String?
    ) {
        self.interactionDate = interactionDate
        self.transcript = transcript
        self.chatModelDescription = chatModelDescription
        self.screenCapture = screenCapture
        self.rawResponseText = rawResponseText
        self.pointCoordinate = pointCoordinate
        self.pointElementLabel = pointElementLabel
        self.errorMessage = errorMessage

        if let screenCapture {
            self.annotatedScreenshotImage = CompanionInteractionDebugImageRenderer.makeAnnotatedScreenshotImage(
                screenCapture: screenCapture,
                pointCoordinate: pointCoordinate
            )
        } else {
            self.annotatedScreenshotImage = nil
        }

        if let screenCapture, let pointCoordinate {
            self.pointCropImage = CompanionInteractionDebugImageRenderer.makePointCropImage(
                screenCapture: screenCapture,
                pointCoordinate: pointCoordinate
            )
        } else {
            self.pointCropImage = nil
        }
    }

    /// True when the model pointed outside the image it was given, which
    /// the pipeline silently clamps to the nearest edge.
    var isPointOutsideScreenshot: Bool {
        guard let pointCoordinate, let screenCapture else { return false }
        return pointCoordinate.x < 0 || pointCoordinate.y < 0
            || pointCoordinate.x > CGFloat(screenCapture.screenshotWidthInPixels)
            || pointCoordinate.y > CGFloat(screenCapture.screenshotHeightInPixels)
    }

    /// Sends this entry's images to Quick Look: the annotated screenshot,
    /// then the crop enlarged so its pixels are readable.
    @MainActor
    func presentInQuickLook() {
        let fileNameTimestamp = Self.fileNameDateFormatter.string(from: interactionDate)
        var quickLookImages: [(image: CGImage, fileName: String)] = []
        if let annotatedScreenshotImage {
            quickLookImages.append((annotatedScreenshotImage, "clicky-\(fileNameTimestamp)-screenshot.png"))
        }
        if let pointCropImage,
           let enlargedPointCropImage = CompanionInteractionDebugImageRenderer.makeEnlargedPixelatedImage(
               pointCropImage,
               scaleFactor: 8
           ) {
            quickLookImages.append((enlargedPointCropImage, "clicky-\(fileNameTimestamp)-point-crop-8x.png"))
        }
        CompanionInteractionQuickLookPresenter.shared.presentImages(quickLookImages)
    }

    private static let fileNameDateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH-mm-ss"
        return dateFormatter
    }()
}

@MainActor
final class CompanionInteractionHistoryStore: ObservableObject {
    /// Most recent first.
    @Published private(set) var entries: [CompanionInteractionHistoryEntry] = []

    /// Each entry holds a full screenshot (a few hundred KB), so keep it short.
    private static let maximumEntryCount = 10

    func record(_ entry: CompanionInteractionHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maximumEntryCount {
            entries.removeLast(entries.count - Self.maximumEntryCount)
        }
    }

    func removeAllEntries() {
        entries.removeAll()
    }
}

// MARK: - Debug Images

enum CompanionInteractionDebugImageRenderer {
    /// Side length, in screenshot pixels, of the crop around the point.
    static let pointCropSideLengthInPixels = 50

    static func makeScreenshotImage(for screenCapture: CompanionScreenCapture) -> CGImage? {
        guard let bitmapImageRep = NSBitmapImageRep(data: screenCapture.imageData) else { return nil }
        return bitmapImageRep.cgImage
    }

    /// A 50x50 pixel crop of the screenshot centred on the point. Drawn into
    /// a fixed-size canvas (rather than cropped and clamped) so the point is
    /// always the exact centre, even near an edge, where the canvas is
    /// padded with black instead of shifting the crop.
    static func makePointCropImage(screenCapture: CompanionScreenCapture, pointCoordinate: CGPoint) -> CGImage? {
        guard let screenshotImage = makeScreenshotImage(for: screenCapture) else { return nil }
        let cropSideLength = pointCropSideLengthInPixels
        let halfCropSideLength = CGFloat(cropSideLength) / 2

        guard let cropContext = makeDrawingContext(width: cropSideLength, height: cropSideLength) else { return nil }
        cropContext.setFillColor(NSColor.black.cgColor)
        cropContext.fill(CGRect(x: 0, y: 0, width: cropSideLength, height: cropSideLength))

        // The context's origin is bottom-left while the point is measured
        // from the top-left, so flip the point's y before offsetting.
        let screenshotWidth = CGFloat(screenshotImage.width)
        let screenshotHeight = CGFloat(screenshotImage.height)
        let pointYFromBottom = screenshotHeight - pointCoordinate.y
        cropContext.draw(
            screenshotImage,
            in: CGRect(
                x: halfCropSideLength - pointCoordinate.x,
                y: halfCropSideLength - pointYFromBottom,
                width: screenshotWidth,
                height: screenshotHeight
            )
        )
        return cropContext.makeImage()
    }

    /// The screenshot with a red crosshair on the point and the 50px crop
    /// area outlined, so a wrong hit is obvious at a glance.
    static func makeAnnotatedScreenshotImage(screenCapture: CompanionScreenCapture, pointCoordinate: CGPoint?) -> CGImage? {
        guard let screenshotImage = makeScreenshotImage(for: screenCapture) else { return nil }
        guard let pointCoordinate else { return screenshotImage }

        let screenshotWidth = screenshotImage.width
        let screenshotHeight = screenshotImage.height
        guard let annotationContext = makeDrawingContext(width: screenshotWidth, height: screenshotHeight) else {
            return screenshotImage
        }
        annotationContext.draw(screenshotImage, in: CGRect(x: 0, y: 0, width: screenshotWidth, height: screenshotHeight))

        let pointInContext = CGPoint(x: pointCoordinate.x, y: CGFloat(screenshotHeight) - pointCoordinate.y)
        let halfCropSideLength = CGFloat(pointCropSideLengthInPixels) / 2
        let crosshairArmLength: CGFloat = 40

        annotationContext.setStrokeColor(NSColor.systemRed.cgColor)
        annotationContext.setLineWidth(2)
        annotationContext.stroke(CGRect(
            x: pointInContext.x - halfCropSideLength,
            y: pointInContext.y - halfCropSideLength,
            width: halfCropSideLength * 2,
            height: halfCropSideLength * 2
        ))
        annotationContext.move(to: CGPoint(x: pointInContext.x - crosshairArmLength, y: pointInContext.y))
        annotationContext.addLine(to: CGPoint(x: pointInContext.x + crosshairArmLength, y: pointInContext.y))
        annotationContext.move(to: CGPoint(x: pointInContext.x, y: pointInContext.y - crosshairArmLength))
        annotationContext.addLine(to: CGPoint(x: pointInContext.x, y: pointInContext.y + crosshairArmLength))
        annotationContext.strokePath()

        return annotationContext.makeImage()
    }

    /// Scales an image up without smoothing, so each source pixel becomes a
    /// crisp block. Quick Look shows images at their real size, and a 50px
    /// crop would otherwise be a speck.
    static func makeEnlargedPixelatedImage(_ sourceImage: CGImage, scaleFactor: Int) -> CGImage? {
        let enlargedWidth = sourceImage.width * scaleFactor
        let enlargedHeight = sourceImage.height * scaleFactor
        guard let enlargementContext = makeDrawingContext(width: enlargedWidth, height: enlargedHeight) else { return nil }
        enlargementContext.interpolationQuality = .none
        enlargementContext.draw(sourceImage, in: CGRect(x: 0, y: 0, width: enlargedWidth, height: enlargedHeight))
        return enlargementContext.makeImage()
    }

    private static func makeDrawingContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}

// MARK: - Quick Look

/// Shows debug images in the system Quick Look panel. Quick Look previews
/// files, so the images are written as PNGs to a temporary folder first.
/// The space bar closes the panel and arrow keys move between images.
final class CompanionInteractionQuickLookPresenter: NSObject, QLPreviewPanelDataSource {
    static let shared = CompanionInteractionQuickLookPresenter()

    private var previewFileURLs: [URL] = []

    private static let previewDirectoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClickyHistoryPreviews", isDirectory: true)

    /// `images` pairs each image with a file name; the name is shown as
    /// Quick Look's title, so make it descriptive.
    @MainActor
    func presentImages(_ images: [(image: CGImage, fileName: String)]) {
        let fileManager = FileManager.default
        // Old previews are only useful while their panel is open, so each
        // presentation replaces them instead of letting them pile up.
        try? fileManager.removeItem(at: Self.previewDirectoryURL)
        try? fileManager.createDirectory(at: Self.previewDirectoryURL, withIntermediateDirectories: true)

        previewFileURLs = images.compactMap { image, fileName in
            let previewFileURL = Self.previewDirectoryURL.appendingPathComponent(fileName)
            guard let pngData = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  (try? pngData.write(to: previewFileURL)) != nil else {
                return nil
            }
            return previewFileURL
        }
        guard !previewFileURLs.isEmpty, let quickLookPanel = QLPreviewPanel.shared() else { return }

        // Clicky is a menu bar app that's usually inactive; without
        // activating, the Quick Look panel opens behind other apps' windows.
        NSApp.activate(ignoringOtherApps: true)
        quickLookPanel.dataSource = self
        quickLookPanel.reloadData()
        quickLookPanel.currentPreviewItemIndex = 0
        quickLookPanel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewFileURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewFileURLs[index] as NSURL
    }
}
