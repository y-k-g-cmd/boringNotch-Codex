    //
    //  SystemEventIndicatorModifier.swift
    //  boringNotch
    //
    //  Created by Richard Kunkli on 12/08/2024.
    //

import SwiftUI
import Defaults

struct SystemEventIndicatorModifier: View {
    @EnvironmentObject var vm: BoringViewModel
    @Binding var eventType: SneakContentType
    @Binding var value: CGFloat {
        didSet {
            DispatchQueue.main.async {
                self.sendEventBack(value)
                self.vm.objectWillChange.send()
            }
        }
    }
    @Binding var icon: String
    let showSlider: Bool = false
    var sendEventBack: (CGFloat) -> Void
    
    var body: some View {
        HStack(spacing: 14) {
            switch (eventType) {
                case .volume:
                    if icon.isEmpty {
                        Image(systemName: SpeakerSymbol(value))
                            .contentTransition(.interpolate)
                            .frame(width: 20, height: 15, alignment: .leading)
                    } else {
                        Image(systemName: icon)
                            .contentTransition(.interpolate)
                            .opacity(value.isZero ? 0.6 : 1)
                            .scaleEffect(value.isZero ? 0.85 : 1)
                            .frame(width: 20, height: 15, alignment: .leading)
                    }
                case .brightness:
                    Image(systemName: "sun.max.fill")
                        .contentTransition(.symbolEffect)
                        .frame(width: 20, height: 15)
                        .foregroundStyle(.white)
                case .backlight:
                    Image(systemName: value > 0.5 ? "light.max" : "light.min")
                        .contentTransition(.interpolate)
                        .frame(width: 20, height: 15)
                        .foregroundStyle(.white)
                case .mic:
                    Image(systemName: "mic")
                        .symbolVariant(value > 0 ? .none : .slash)
                        .contentTransition(.interpolate)
                        .frame(width: 20, height: 15)
                        .foregroundStyle(.white)
                default:
                    EmptyView()
            }
            if (eventType != .mic) {
                DraggableProgressBar(value: $value)
            } else {
                Text("Mic \(value > 0 ? "unmuted" : "muted")")
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .allowsTightening(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .symbolVariant(.fill)
        .imageScale(.large)
    }
    
    func SpeakerSymbol(_ value: CGFloat) -> String {
        switch(value) {
            case 0:
                return "speaker.slash"
            case 0...0.3:
                return "speaker.wave.1"
            case 0.3...0.8:
                return "speaker.wave.2"
            case 0.8...1:
                return "speaker.wave.3"
            default:
                return "speaker.wave.2"
        }
    }
}

struct DraggableProgressBar: View {
    @EnvironmentObject var vm: BoringViewModel
    @Binding var value: CGFloat
    var onChange: ((CGFloat) -> Void)? = nil
    
    @State private var isDragging = false
    @State private var dragOffset: CGFloat = 0
    
    var body: some View {
        VStack {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.tertiary)
                    Capsule()
                        .fill(
                            Defaults[.enableGradient] ?
                                AnyShapeStyle(LinearGradient(
                                    colors: Defaults[.systemEventIndicatorUseAccent] ?
                                        [Color.effectiveAccent, Color.effectiveAccent.ensureMinimumBrightness(factor: 0.2)] :
                                        [Color.white, Color.white.opacity(0.2)],
                                    startPoint: .trailing,
                                    endPoint: .leading
                                )) :
                                AnyShapeStyle(Defaults[.systemEventIndicatorUseAccent] ? Color.effectiveAccent : Color.white)
                        )
                        .frame(width: max(0, min(geo.size.width * value, geo.size.width)))
                        .shadow(color: Defaults[.systemEventIndicatorShadow] ?
                            (Defaults[.systemEventIndicatorUseAccent] ?
                                Color.effectiveAccent.ensureMinimumBrightness(factor: 0.7) :
                                Color.white) :
                            Color.clear,
                            radius: 8, x: 3)
                        .opacity(value.isZero ? 0 : 1)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            withAnimation(.smooth(duration: 0.3)) {
                                isDragging = true
                                updateValue(gesture: gesture, in: geo)
                            }
                        }
                        .onEnded { _ in
                            withAnimation(.smooth(duration: 0.3)) {
                                isDragging = false
                            }
                        }
                )
            }
            .frame(height: Defaults[.inlineHUD] ? isDragging ? 8 : 5 : isDragging ? 9 : 6)
        }
    }
    
    private func updateValue(gesture: DragGesture.Value, in geometry: GeometryProxy) {
        let dragPosition = gesture.location.x
        let newValue = dragPosition / geometry.size.width
        
        value = max(0, min(newValue, 1))
        onChange?(value)
    }
}


struct SystemHUDCard: View {
    let type: SneakContentType
    let value: CGFloat
    var compact = true
    var onChange: (CGFloat) -> Void
    var onEditing: (Bool) -> Void
    @AppStorage("systemHUDPercentage") private var showPercentage = true
    private var icon: String {
        switch type {
        case .volume: return value <= 0 ? "speaker.slash.fill" : value < 0.33 ? "speaker.wave.1.fill" : value < 0.66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .brightness: return "sun.max.fill"
        default: return "light.max"
        }
    }
    var body: some View {
        VStack(spacing: compact ? 8 : 16) {
            HStack(spacing: 12) {
                Group {
                    if type == .volume {
                        Button { VolumeManager.shared.toggleMuteAction() } label: {
                            Image(systemName: icon).frame(width: compact ? 26 : 38, height: 28)
                        }.buttonStyle(.plain).help("Toggle mute")
                    } else {
                        Image(systemName: icon).frame(width: compact ? 26 : 38, height: 28)
                    }
                }.font(.system(size: compact ? 20 : 26))
                Text(type == .volume ? "Volume" : type == .brightness ? "Brightness" : "Keyboard backlight")
                    .font(.system(size: compact ? 14 : 17, weight: .semibold))
                Spacer()
                if showPercentage { Text("\(Int(min(1, max(0, value)) * 100))%")
                    .font(.system(size: compact ? 18 : 22, weight: .medium, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                }
            }
            GeometryReader { geometry in
                let level = min(1, max(0, value))
                let travel = max(1, geometry.size.width - 16)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.24)).frame(height: 8)
                    Capsule().fill(Defaults[.systemEventIndicatorUseAccent] ? Color.effectiveAccent : .white)
                        .frame(width: 8 + travel * level, height: 8)
                    Circle().fill(.white).frame(width: 16, height: 16)
                        .offset(x: travel * level)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onEditing(true)
                        onChange(min(1, max(0, (gesture.location.x - 8) / travel)))
                    }
                    .onEnded { _ in onEditing(false) })
            }.frame(height: 24)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(type == .volume ? "Volume" : type == .brightness ? "Brightness" : "Keyboard backlight"))
                .accessibilityValue(Text("\(Int(min(1, max(0, value)) * 100))%"))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: onChange(min(1, value + 0.05))
                    case .decrement: onChange(max(0, value - 0.05))
                    @unknown default: break
                    }
                }

        }
        .padding(.horizontal, compact ? 2 : 34).frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .animation(.linear(duration: 0.08), value: value)
    }
}
