import SwiftUI

/// Top-level onboarding window. Left rail = step list with status pips,
/// right pane = step body. Window dismissal is non-destructive: closing
/// without finishing is treated as "skip" (no auto-reopen next launch).
struct OnboardingView: View {
    @ObservedObject var status: BridgeStatusModel
    @ObservedObject var onboarding: OnboardingState

    var body: some View {
        HStack(spacing: 0) {
            stepList
                .frame(width: 180)
                .padding(.vertical, 16)
                .padding(.horizontal, 12)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.5))

            Divider()

            stepBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
        }
        .frame(width: 720, height: 520)
        .onDisappear {
            // Closing the window mid-flow counts as "skip" (suppresses
            // auto-reopen on next launch). User can reopen manually from
            // the Status tab whenever.
            if onboarding.currentStep != .done {
                onboarding.markSkipped()
            }
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Setup")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 4)
            ForEach(OnboardingState.Step.allCases) { step in
                stepRow(step)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func stepRow(_ step: OnboardingState.Step) -> some View {
        let isCurrent = onboarding.currentStep == step
        let isPast = step.rawValue < onboarding.currentStep.rawValue
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isCurrent ? Color.accentColor : (isPast ? Color.green : Color.secondary.opacity(0.3)))
                    .frame(width: 18, height: 18)
                if isPast {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isCurrent ? .white : .secondary)
                }
            }
            Text(step.title)
                .font(isCurrent ? .body.weight(.semibold) : .body)
                .foregroundStyle(isCurrent ? .primary : (isPast ? .secondary : .primary))
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Allow free navigation — onboarding is a guide, not a gate.
            onboarding.goTo(step)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var stepBody: some View {
        switch onboarding.currentStep {
        case .welcome:     WelcomeStep(onboarding: onboarding)
        case .daemon:      DaemonStep(status: status, onboarding: onboarding)
        case .token:       TokenStep(onboarding: onboarding)
        case .permissions: PermissionsStep(onboarding: onboarding)
        case .connect:     ConnectStep(onboarding: onboarding)
        case .done:        DoneStep(onboarding: onboarding)
        }
    }
}

/// Reusable bottom toolbar — Back / Skip All / Continue.
struct OnboardingNav: View {
    @ObservedObject var onboarding: OnboardingState
    var continueLabel: String = "Continue"
    var continueIsPrimary: Bool = true
    var onContinue: (() -> Void)? = nil

    var body: some View {
        HStack {
            if onboarding.currentStep != .welcome {
                Button("Back") { onboarding.goBack() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
            }
            Spacer()
            if onboarding.currentStep != .done {
                Button("Skip Setup") {
                    onboarding.markSkipped()
                    closeWindow()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            Button(continueLabel) {
                if let onContinue { onContinue() } else { onboarding.goNext() }
            }
            .keyboardShortcut(.return, modifiers: [])
            .if(continueIsPrimary) { $0.buttonStyle(.borderedProminent) }
        }
        .padding(.top, 12)
    }

    private func closeWindow() {
        for w in NSApp.windows where w.identifier?.rawValue == "onboarding" {
            w.performClose(nil)
        }
    }
}

private extension View {
    @ViewBuilder
    func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}
