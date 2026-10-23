//
//  CompanionHistorySectionView.swift
//  leanring-buddy
//
//  The collapsible History section under Status. Lists recent push-to-talk
//  interactions with the transcript, the screenshot that was sent, the
//  [POINT] coordinates and the response, for debugging pointing. The eye
//  button shows a 50px crop centred on the coordinates, and clicking an
//  image opens it in Quick Look.
//
//  Observes the history store directly, for the same reason the Status
//  section observes ServiceHealthMonitor: SwiftUI doesn't propagate
//  changes from an ObservableObject nested inside CompanionManager.
//

import SwiftUI

struct CompanionHistorySectionView: View {
    @ObservedObject var interactionHistoryStore: CompanionInteractionHistoryStore

    @State private var isHistorySectionExpanded = false
    @State private var isHistoryHeaderHovered = false

    /// Caps the list so ten entries with thumbnails don't make the panel
    /// taller than the screen; beyond this it scrolls.
    private static let maximumListHeight: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            historyHeaderRow

            if isHistorySectionExpanded {
                if interactionHistoryStore.entries.isEmpty {
                    Text("Nothing yet. Hold control + option and ask something.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(interactionHistoryStore.entries) { historyEntry in
                                CompanionHistoryEntryRow(historyEntry: historyEntry)
                            }
                        }
                    }
                    .frame(maxHeight: Self.maximumListHeight)

                    HStack {
                        Spacer()
                        ServiceStatusPillButton(label: "Clear", isDisabled: false) {
                            interactionHistoryStore.removeAllEntries()
                        }
                    }
                }
            }
        }
    }

    private var historyHeaderRow: some View {
        Button(action: {
            withAnimation(.easeOut(duration: 0.15)) {
                isHistorySectionExpanded.toggle()
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("History")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                Text(interactionHistoryStore.entries.isEmpty ? "Empty" : "\(interactionHistoryStore.entries.count) recent")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .rotationEffect(.degrees(isHistorySectionExpanded ? 90 : 0))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHistoryHeaderHovered ? Color.white.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering in
            isHistoryHeaderHovered = isHovering
        }
        .padding(.horizontal, -6)
    }
}

/// One interaction: heard text, model, screenshot, coordinates, response.
private struct CompanionHistoryEntryRow: View {
    let historyEntry: CompanionInteractionHistoryEntry

    @State private var isShowingPointCrop = false
    @State private var isEyeButtonHovered = false
    @State private var isScreenshotHovered = false

    /// The 50px crop is drawn at 2x so its pixels are visible in the panel.
    private static let pointCropDisplaySideLength: CGFloat = 100
    private static let screenshotThumbnailWidth: CGFloat = 150

    private static let timeFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"
        return dateFormatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(Self.timeFormatter.string(from: historyEntry.interactionDate)) · \(historyEntry.chatModelDescription)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Text("“\(historyEntry.transcript)”")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let errorMessage = historyEntry.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            screenshotAndCropRow

            Text(pointDescriptionText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(historyEntry.isPointOutsideScreenshot
                                 ? DS.Colors.destructiveText
                                 : DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let rawResponseText = historyEntry.rawResponseText {
                Text(rawResponseText)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.25))
        )
    }

    @ViewBuilder
    private var screenshotAndCropRow: some View {
        if let annotatedScreenshotImage = historyEntry.annotatedScreenshotImage {
            HStack(alignment: .top, spacing: 8) {
                // The thumbnail already carries the red crosshair; clicking
                // it opens the full-size screenshot (and the crop) in Quick Look.
                Button(action: {
                    historyEntry.presentInQuickLook()
                }) {
                    Image(decorative: annotatedScreenshotImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: Self.screenshotThumbnailWidth)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(isScreenshotHovered ? DS.Colors.textSecondary : DS.Colors.borderSubtle, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .onHover { isHovering in
                    isScreenshotHovered = isHovering
                }
                .help("Open in Quick Look")

                if historyEntry.pointCropImage != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        pointCropEyeButton

                        if isShowingPointCrop, let pointCropImage = historyEntry.pointCropImage {
                            Button(action: {
                                historyEntry.presentInQuickLook()
                            }) {
                                Image(decorative: pointCropImage, scale: 1)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: Self.pointCropDisplaySideLength, height: Self.pointCropDisplaySideLength)
                                    .overlay(pointCropCentreMarker)
                                    .overlay(
                                        Rectangle()
                                            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                            .help("Open in Quick Look")
                        }
                    }
                }
            }
        } else {
            Text("No screenshot sent (text-only model, or failed before capture)")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    private var pointCropEyeButton: some View {
        Button(action: {
            withAnimation(.easeOut(duration: 0.15)) {
                isShowingPointCrop.toggle()
            }
        }) {
            Image(systemName: isShowingPointCrop ? "eye.fill" : "eye")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isEyeButtonHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(isEyeButtonHovered ? 0.1 : 0.06))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering in
            isEyeButtonHovered = isHovering
        }
        .help("Show the 50px area around the point")
    }

    /// Small crosshair on the crop's exact centre, which is the point itself.
    private var pointCropCentreMarker: some View {
        ZStack {
            Rectangle()
                .fill(Color.red.opacity(0.8))
                .frame(width: 10, height: 1)
            Rectangle()
                .fill(Color.red.opacity(0.8))
                .frame(width: 1, height: 10)
        }
    }

    private var pointDescriptionText: String {
        guard let pointCoordinate = historyEntry.pointCoordinate else {
            if historyEntry.rawResponseText == nil { return "No response" }
            return historyEntry.pointElementLabel == "none" ? "POINT none" : "No POINT tag"
        }

        var pointDescription = "POINT \(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))"
        if let pointElementLabel = historyEntry.pointElementLabel {
            pointDescription += " · \(pointElementLabel)"
        }
        if let screenCapture = historyEntry.screenCapture {
            pointDescription += " · image \(screenCapture.screenshotWidthInPixels)×\(screenCapture.screenshotHeightInPixels)"
        }
        if historyEntry.isPointOutsideScreenshot {
            pointDescription += " · outside the image, clamped"
        }
        return pointDescription
    }
}
