import SwiftUI

struct SplashView: View {
    let onContinue: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var hasTriggeredEntry = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            HUDBackground()

            VStack(spacing: 34) {
                Spacer(minLength: 48)

                ZStack {
                    Circle()
                        .stroke(HUDTheme.accent.opacity(0.16), lineWidth: 1)
                        .frame(width: 240, height: 240)
                        .scaleEffect(pulse ? 1.04 : 0.96)

                    Circle()
                        .stroke(HUDTheme.mint.opacity(0.14), lineWidth: 1)
                        .frame(width: 300, height: 300)
                        .scaleEffect(pulse ? 1.02 : 0.98)

                    RoundedRectangle(cornerRadius: 42, style: .continuous)
                        .fill(.white.opacity(0.72))
                        .frame(width: 178, height: 178)
                        .overlay {
                            RoundedRectangle(cornerRadius: 42, style: .continuous)
                                .stroke(HUDTheme.stroke, lineWidth: 1)
                        }
                        .shadow(color: HUDTheme.shadow, radius: 30, x: 0, y: 18)

                    Image("AppIconImage")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 146, height: 146)
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                }
                .offset(y: dragOffset * 0.55)

                VStack(spacing: 12) {
                    Text("HUDini")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(HUDTheme.ink)

                    Text("Swipe up to enter.")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(HUDTheme.inkMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .offset(y: dragOffset * 0.28)

                Spacer()

                VStack(spacing: 14) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(HUDTheme.inkMuted)
                        .offset(y: pulse ? -6 : 0)

                    Text("Swipe up")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(HUDTheme.inkMuted)
                }
                .padding(.bottom, 34)
                .opacity(hasTriggeredEntry ? 0 : 1)
            }
            .padding(.horizontal, 28)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    guard !hasTriggeredEntry else { return }
                    dragOffset = min(0, value.translation.height)
                }
                .onEnded { value in
                    guard !hasTriggeredEntry else { return }
                    let predictedLift = min(value.translation.height, value.predictedEndTranslation.height)
                    if predictedLift < -120 {
                        triggerEntry()
                    } else {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .simultaneousGesture(
            TapGesture()
                .onEnded {
                    guard !hasTriggeredEntry else { return }
                    triggerEntry()
                }
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private func triggerEntry() {
        hasTriggeredEntry = true
        withAnimation(.spring(response: 0.58, dampingFraction: 0.86)) {
            dragOffset = -420
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            onContinue()
        }
    }
}

#Preview {
    SplashView(onContinue: {})
}
