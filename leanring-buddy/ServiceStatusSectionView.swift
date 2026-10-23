//
//  ServiceStatusSectionView.swift
//  leanring-buddy
//
//  The collapsible Status section in the menu bar panel. Collapsed, it is a
//  single row with a green/red dot summarising every component. Expanded, it
//  lists each component with its last result, a Test button, and (for
//  failures) the raw error with a Copy button.
//
//  Lives in its own view so it can observe the ServiceHealthMonitor
//  directly — SwiftUI doesn't propagate changes from an ObservableObject
//  nested inside CompanionManager.
//

import AppKit
import SwiftUI

struct ServiceStatusSectionView: View {
    @ObservedObject var serviceHealthMonitor: ServiceHealthMonitor
    let companionManager: CompanionManager

    @State private var isStatusSectionExpanded = false
    @State private var isStatusHeaderHovered = false
    @State private var isTestAllButtonHovered = false
    @State private var expandedErrorDetailComponent: MonitoredServiceComponent?
    @State private var hoveredComponent: MonitoredServiceComponent?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            statusHeaderRow

            if isStatusSectionExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(MonitoredServiceComponent.allCases) { component in
                        componentRow(for: component)
                    }
                }
                .padding(.top, 2)

                testAllButton
                    .padding(.top, 4)
            }
        }
        .onAppear {
            // Open straight onto the problem if something already failed
            if serviceHealthMonitor.hasAnyFailingComponent {
                isStatusSectionExpanded = true
            }
        }
        .onChange(of: serviceHealthMonitor.hasAnyFailingComponent) { _, hasAnyFailingComponent in
            if hasAnyFailingComponent {
                isStatusSectionExpanded = true
            }
        }
    }

    // MARK: - Header

    private var statusHeaderRow: some View {
        Button(action: {
            withAnimation(.easeOut(duration: 0.15)) {
                isStatusSectionExpanded.toggle()
            }
        }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(overallStatusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: overallStatusDotColor.opacity(0.6), radius: 3)
                    .frame(width: 16)

                Text("Status")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                Text(overallStatusSummaryText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(serviceHealthMonitor.hasAnyFailingComponent
                                     ? DS.Colors.destructiveText
                                     : DS.Colors.textTertiary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .rotationEffect(.degrees(isStatusSectionExpanded ? 90 : 0))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isStatusHeaderHovered ? Color.white.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering in
            isStatusHeaderHovered = isHovering
        }
        .padding(.horizontal, -6)
    }

    private var overallStatusDotColor: Color {
        if serviceHealthMonitor.hasAnyFailingComponent {
            return DS.Colors.destructive
        }
        if serviceHealthMonitor.isAnyComponentChecking {
            return DS.Colors.blue400
        }
        if serviceHealthMonitor.hasAnyHealthyComponent {
            return DS.Colors.success
        }
        return DS.Colors.textTertiary
    }

    private var overallStatusSummaryText: String {
        let failingComponentCount = MonitoredServiceComponent.allCases.filter {
            serviceHealthMonitor.health(for: $0).status == .failing
        }.count
        if failingComponentCount == 1 {
            return "1 problem"
        }
        if failingComponentCount > 1 {
            return "\(failingComponentCount) problems"
        }
        if serviceHealthMonitor.isAnyComponentChecking {
            return "Checking…"
        }
        if serviceHealthMonitor.hasAnyHealthyComponent {
            return "All good"
        }
        return "Not checked"
    }

    // MARK: - Component Rows

    private func componentRow(for component: MonitoredServiceComponent) -> some View {
        let componentHealth = serviceHealthMonitor.health(for: component)
        let canShowErrorDetail = componentHealth.status == .failing && componentHealth.detailedErrorText != nil
        let isShowingErrorDetail = canShowErrorDetail && expandedErrorDetailComponent == component

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: component.iconSystemName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(component.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)

                        // Signals that a failing row can be clicked for the raw error
                        if canShowErrorDetail {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                                .rotationEffect(.degrees(isShowingErrorDetail ? 90 : 0))
                        }
                    }

                    Text(componentHealth.summaryMessage)
                        .font(.system(size: 10))
                        .foregroundColor(componentHealth.status == .failing
                                         ? DS.Colors.destructiveText
                                         : DS.Colors.textTertiary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                componentStatusIndicator(for: componentHealth.status)
                    .padding(.top, 3)

                componentTestButton(for: component, isChecking: componentHealth.status == .checking)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(canShowErrorDetail && hoveredComponent == component
                          ? Color.white.opacity(0.06)
                          : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                guard canShowErrorDetail else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    expandedErrorDetailComponent = isShowingErrorDetail ? nil : component
                }
            }
            .pointerCursor(isEnabled: canShowErrorDetail)
            .onHover { isHovering in
                if isHovering {
                    hoveredComponent = component
                } else if hoveredComponent == component {
                    hoveredComponent = nil
                }
            }

            if isShowingErrorDetail, let detailedErrorText = componentHealth.detailedErrorText {
                errorDetailView(detailedErrorText: detailedErrorText)
                    .padding(.leading, 30)
                    .padding(.trailing, 6)
            }
        }
        .padding(.horizontal, -6)
    }

    @ViewBuilder
    private func componentStatusIndicator(for status: ServiceComponentHealthStatus) -> some View {
        switch status {
        case .checking:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 8, height: 8)
        case .healthy:
            Circle().fill(DS.Colors.success).frame(width: 6, height: 6)
        case .failing:
            Circle().fill(DS.Colors.destructive).frame(width: 6, height: 6)
        case .unknown:
            Circle().fill(DS.Colors.textTertiary.opacity(0.5)).frame(width: 6, height: 6)
        }
    }

    private func componentTestButton(for component: MonitoredServiceComponent, isChecking: Bool) -> some View {
        ServiceStatusPillButton(
            label: component == .permissions ? "Recheck" : "Test",
            isDisabled: isChecking
        ) {
            Task {
                await companionManager.testServiceComponent(component)
            }
        }
    }

    private func errorDetailView(detailedErrorText: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detailedErrorText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            ServiceStatusPillButton(label: "Copy error", isDisabled: false) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(detailedErrorText, forType: .string)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.25))
        )
    }

    // MARK: - Test All

    private var testAllButton: some View {
        Button(action: {
            Task {
                await companionManager.testAllServiceComponents()
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 11, weight: .medium))
                Text(serviceHealthMonitor.isAnyComponentChecking ? "Testing…" : "Test all")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(isTestAllButtonHovered ? 0.1 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(serviceHealthMonitor.isAnyComponentChecking)
        .pointerCursor(isEnabled: !serviceHealthMonitor.isAnyComponentChecking)
        .onHover { isHovering in
            isTestAllButtonHovered = isHovering
        }
        .help("Claude and ElevenLabs tests each make one tiny paid request")
    }
}

/// Small outlined capsule button used for the per-row Test and Copy actions.
private struct ServiceStatusPillButton: View {
    let label: String
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isDisabled ? DS.Colors.textTertiary : DS.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(isHovered && !isDisabled ? Color.white.opacity(0.08) : Color.clear)
                )
                .overlay(
                    Capsule()
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .pointerCursor(isEnabled: !isDisabled)
        .onHover { isHovering in
            isHovered = isHovering
        }
    }
}
