//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel
    private let codexMonitor = CodexMonitor.shared
    @ObservedObject private var dictionary = NotchDictionary.shared
    @State private var quotaWarningPresented = false
    @State private var quotaWarningTask: Task<Void, Never>?
    @State private var quotaWarningUntil = Date.distantPast
    @State private var dictionarySessionActive = false
    private var dictionaryPresented: Bool {
        (dictionary.visible || dictionarySessionActive) && dictionary.screenID == vm.screenUUID
    }
    private var dictionarySize: CGSize {
        let contentHeight: CGFloat = dictionary.entry == nil ? 90 : 128
        return CGSize(width: 440, height: min(openNotchSize.height, max(24, vm.effectiveClosedNotchHeight) + 20 + contentHeight))
    }


    @AppStorage("systemHUDCompact") private var compactSystemHUD = true
    @State private var hudDragging = false
    @AppStorage("systemHUDExpand") private var expandSystemHUD = true
    @State private var systemHUDOpened = false
    @State private var presentedHUDType: SneakContentType = .volume
    @State private var presentedHUDValue: CGFloat = 0
    @State private var hudCloseTask: Task<Void, Never>?
    private var isSystemHUD: Bool { [.volume, .brightness, .backlight].contains(coordinator.sneakPeek.type) }
    private var expandedHUDRequested: Bool { expandSystemHUD && coordinator.sneakPeek.show && isSystemHUD }
    @State private var codexState = CodexNotchState()
    @State private var codexReminderTask: Task<Void, Never>?
    @State private var codexReminderUntil = Date.distantPast
    @AppStorage("horizontalPageSwipe") private var horizontalPageSwipe = true
    @AppStorage("codexTaskNavigation") private var codexTaskNavigation = "region"
    @ObservedObject var webcamManager = WebcamManager.shared

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?
    @State private var releasedShelfDragSamples = 0

    @State private var gestureProgress: CGFloat = .zero

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    @Default(.showNotHumanFace) var showNotHumanFace

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.bottom
                : cornerRadiusInsets.closed.bottom
        )
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
        {
            chinWidth = 640
        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? Defaults[.cornerRadiusScaling]
                        ? (cornerRadiusInsets.opened.top) : (cornerRadiusInsets.opened.bottom)
                        : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
                    .frame(width: vm.notchState == .open ? vm.notchSize.width : nil)
                    .clipShape(currentNotchShape)
                    .background {
                        // Only the solid shell casts a shadow, independent of live card content.
                        currentNotchShape.fill(.black)
                            .shadow(color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                                ? .black.opacity(0.7) : .clear, radius: Defaults[.cornerRadiusScaling] ? 6 : 4)
                    }
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 2)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    .frame(height: vm.notchState == .open ? vm.notchSize.height : nil, alignment: .top)
                    .conditionalModifier(true) { view in
                        let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                        let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
                        
                        return view
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                            .animation(.smooth, value: gestureProgress)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        if !systemHUDOpened && !dictionaryPresented && !quotaWarningPresented { doOpen() }
                    }
                    .pageSwipe(enabled: !dictionaryPresented && horizontalPageSwipe && vm.notchState == .open && !vm.anyDropZoneTargeting && !ShelfSelectionModel.shared.isDragging, excludingTaskRegions: coordinator.currentView == .codex && codexTaskNavigation == "region") { step in
                        let pages: [NotchViews] = Defaults[.boringShelf] ? [.home, .shelf, .codex] : [.home, .codex]
                        guard let index = pages.firstIndex(of: coordinator.currentView) else { return }
                        let next = max(0, min(pages.count - 1, index + step))
                        withAnimation(.smooth) { coordinator.currentView = pages[next] }
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .onAppear {
                        codexMonitor.start()
                        NotchResources.shared.start()
                        SystemHUDMonitor.shared.start()
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            await MainActor.run {
                                if coordinator.firstLaunch {
                                    withAnimation(vm.animation) {
                                        doOpen()
                                    }
                                }
                            }
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open && !isHovering && !vm.isBatteryPopoverActive {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                                        self.closeAfterHover()
                                    }
                                }
                            }
                        }
                    }
                    // Failed provider reads can omit destination exit callbacks.
                    // Check physical release independently, also during event tracking.
                    .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in
                        guard coordinator.currentView == .shelf, vm.notchState == .open,
                              !CGEventSource.buttonState(.combinedSessionState, button: .left),
                              !ShelfSelectionModel.shared.isDragging else {
                            releasedShelfDragSamples = 0
                            return
                        }
                        releasedShelfDragSamples = min(releasedShelfDragSamples + 1, 2)
                        guard releasedShelfDragSamples == 2 else { return }
                        if vm.anyDropZoneTargeting || ShelfInternalDropRouter.shared.hasTarget {
                            ShelfDragDiagnostics.record("release-recovery drag=\(vm.dragDetectorTargeting) general=\(vm.generalDropTargeting) share=\(vm.dropZoneTargeting) hover=\(vm.isMouseHovering())")
                            NotificationCenter.default.post(name: .shelfDragDidFinish, object: nil)
                        } else if !vm.isMouseHovering() {
                            closeAfterHover()
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .shelfDragDidFinish)) { _ in
                        ShelfInternalDropRouter.shared.clearHighlight()
                        vm.dropEvent = false
                        vm.dragDetectorTargeting = false
                        vm.generalDropTargeting = false
                        vm.dropZoneTargeting = false
                        hoverTask?.cancel()
                        hoverTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            guard !Task.isCancelled else { return }
                            isHovering = vm.isMouseHovering()
                            if vm.notchState == .open { closeAfterHover() }
                        }
                    }
                    .onChange(of: dictionary.sequence) {
                        guard dictionary.visible && dictionary.screenID == vm.screenUUID else { return }
                        dictionarySessionActive = true
                        quotaWarningTask?.cancel(); quotaWarningPresented = false; quotaWarningUntil = .distantPast
                        hudCloseTask?.cancel(); hoverTask?.cancel(); codexReminderTask?.cancel()
                        systemHUDOpened = false
                        withAnimation(animationSpring) {
                            vm.open(preferredView: coordinator.currentView, size: dictionarySize)
                        }
                    }
                    .onReceive(coordinator.$sneakPeek) { state in handleSystemHUD(state) }
                    .onChange(of: compactSystemHUD) {
                        if systemHUDOpened && vm.notchState == .open {
                            withAnimation(animationSpring) { vm.notchSize = systemHUDSize }
                        }
                    }
                    .onChange(of: coordinator.currentView) {
                        if vm.notchState == .open { quotaWarningPresented = false; quotaWarningTask?.cancel() }
                        if dictionaryPresented && vm.notchState == .open {
                            dictionarySessionActive = false
                            dictionary.dismiss()
                        }
                        if systemHUDOpened && vm.notchState == .open {
                            withAnimation(animationSpring) { vm.notchSize = openNotchSize }
                        }
                        systemHUDOpened = false
                    }
                    .onChange(of: codexState.reminderSequence) { showCodexReminder() }
                    .onChange(of: vm.notchState) { _, newState in
                        handleDictionaryClose(isClosed: newState == .closed)
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    .onChange(of: vm.isBatteryPopoverActive) {
                        if !vm.isBatteryPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if !self.vm.isBatteryPopoverActive && !self.isHovering && self.vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                                        self.closeAfterHover()
                                    }
                                }
                            }
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Settings") {
                            SettingsWindowController.shared.showWindow()
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .background(dragDetector)
        .environmentObject(vm)
        .onReceive(codexMonitor.$notchState.removeDuplicates()) { state in
            // A recreated subscription replays the current snapshot when switching pages.
            // Close only when retries first pause, so manual access remains available.
            let enteredRetryPause = state.enteredRetryPause(from: codexState)
            if codexState != state { codexState = state }
            if enteredRetryPause {
                codexReminderTask?.cancel()
                codexReminderUntil = .distantPast
                if coordinator.currentView == .codex && vm.notchState == .open {
                    hoverTask?.cancel()
                    withAnimation(vm.animation) { vm.close() }
                }
            }
        }
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if vm.notchState == .closed {
                    doOpen(preferredView: .shelf)
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                // A completed drop must not consume the only leave/close check.
                // The actual pointer position still keeps an occupied shelf open.
                vm.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    closeAfterHover()
                }
            }
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading) {
                if coordinator.firstLaunch {
                    Spacer()
                    HelloAnimation().frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    ).onAppear(perform: {
                        vm.closeHello()
                    })
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if vm.notchState == .closed && codexState.hasRelevantTasks && !musicManager.isPlaying && !vm.hideOnClosed && !(!expandSystemHUD && coordinator.sneakPeek.show && isSystemHUD) {
                        HStack(spacing: 0) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 10, weight: .semibold)).frame(width: 24)
                            Color.clear.frame(width: vm.closedNotchSize.width)
                            Circle().fill(!codexState.connected ? Color.gray : codexState.attentionCount > 0 ? Color.orange : codexState.hasRunning ? Color.blue : Color.green)
                                .frame(width: 6, height: 6).frame(width: 24)
                        }
                        .foregroundStyle(.gray)
                        .frame(height: vm.effectiveClosedNotchHeight)
                        .onTapGesture {
                            doOpen(preferredView: .codex)
                        }
                    } else if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                        && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
                    {
                        HStack(spacing: 0) {
                            HStack {
                                Text(batteryModel.statusText)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }

                            Rectangle()
                                .fill(.black)
                                .frame(width: vm.closedNotchSize.width + 10)

                            HStack {
                                BoringBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    isForNotification: true
                                )
                            }
                            .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
                      } else if coordinator.sneakPeek.show && !expandedHUDRequested && Defaults[.inlineHUD] && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && vm.notchState == .closed {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(.opacity)
                      } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music) && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed {
                          MusicLiveActivity()
                              .frame(alignment: .center)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
                          BoringFaceAnimation()
                       } else if vm.notchState == .open {
                           Group {
                               if dictionaryPresented || quotaWarningPresented || (systemHUDOpened && compactSystemHUD) {
                                   Color.clear
                               } else { BoringHeader() }
                           }
                               .frame(height: max(24, vm.effectiveClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                       }

                      if coordinator.sneakPeek.show && !expandedHUDRequested {
                          if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && !Defaults[.inlineHUD] && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: $coordinator.sneakPeek.type,
                                  value: $coordinator.sneakPeek.value,
                                  icon: $coordinator.sneakPeek.icon,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeek.type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      case .backlight:
                                          KeyboardBacklightManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                          // Old sneak peek music
                          else if coordinator.sneakPeek.type == .music {
                              if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "music.note")
                                      GeometryReader { geo in
                                          MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName),  textColor: Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray, minDuration: 1, frameWidth: geo.size.width)
                                      }
                                  }
                                  .foregroundStyle(.gray)
                                  .padding(.bottom, 10)
                              }
                          }
                      }
                  }
              }
              .conditionalModifier((coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard) || (coordinator.sneakPeek.show && !expandedHUDRequested && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed))) { view in
                  view
                      .fixedSize()
              }
              .zIndex(2)
            if vm.notchState == .open {
                VStack(alignment: .leading, spacing: 0) {
                    if dictionaryPresented {
                        NotchDictionaryCard {
                            dictionary.dismiss()
                            withAnimation(animationSpring) { vm.close() }
                        }
                        .onChange(of: dictionarySize) {
                            withAnimation(animationSpring) { vm.notchSize = dictionarySize }
                        }
                        .frame(height: max(0, vm.notchSize.height - max(24, vm.effectiveClosedNotchHeight) - 20))
                    } else if quotaWarningPresented {
                        QuotaWarningCard { withAnimation(animationSpring) { vm.close() } }
                            .frame(height: max(0, vm.notchSize.height - max(24, vm.effectiveClosedNotchHeight) - 20))
                    } else if systemHUDOpened {
                        SystemHUDCard(type: presentedHUDType, value: presentedHUDValue,
                                      compact: compactSystemHUD, onChange: updateHUDLevel,
                                      onEditing: { editing in
                                          hudDragging = editing
                                          if !editing {
                                              coordinator.toggleSneakPeek(status: true, type: presentedHUDType, value: presentedHUDValue)
                                          }
                                      })
                            .frame(height: max(0, vm.notchSize.height - max(24, vm.effectiveClosedNotchHeight) - 20))
                    } else {
                    switch coordinator.currentView {
                    case .home:
                        NotchHomeView(albumArtNamespace: albumArtNamespace)
                    case .shelf:
                        ShelfView()
                    case .codex:
                        CodexView()
                            // Match the native content area without changing the other pages' layout.
                            .frame(height: max(0, openNotchSize.height - max(24, vm.effectiveClosedNotchHeight) - 20), alignment: .top)
                    }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
         .onReceive(NotificationCenter.default.publisher(for: NotchResources.quotaWarning)) { _ in showQuotaWarning() }
         .onDrop(of: [ShelfInternalTransfer.type, .fileURL, .url, .utf8PlainText, .plainText, .data], delegate: GeneralDropTargetDelegate(
            isTargeted: $vm.generalDropTargeting,
            enabled: Defaults[.boringShelf] && coordinator.currentView == .shelf,
            accept: { providers in
                vm.dropEvent = true
                let zone = UserDefaults.standard.string(forKey: "shelfActiveZone").flatMap(ShelfZone.init(rawValue:)) ?? .copy
                return ShelfStateViewModel.shared.acceptDrop(providers, into: zone)
            }))
    }

    private func handleDictionaryClose(isClosed: Bool) {
        if isClosed && quotaWarningPresented {
            NotchResources.shared.recordQuotaDiagnostic("closed")
            quotaWarningTask?.cancel(); quotaWarningUntil = .distantPast
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                if vm.notchState == .closed { quotaWarningPresented = false }
            }
        }
        if !isClosed {
            if Date() >= quotaWarningUntil { quotaWarningPresented = false }
            if !dictionary.visible { dictionarySessionActive = false }
            return
        }
        guard dictionaryPresented else { return }
        dictionary.dismiss()
        let sequence = dictionary.sequence
        Task { @MainActor in
            // Keep the outgoing card's identity until its removal transition has finished.
            try? await Task.sleep(for: .milliseconds(600))
            guard vm.notchState == .closed, dictionary.sequence == sequence else { return }
            dictionarySessionActive = false
        }
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 12),
                        height: max(0, vm.effectiveClosedNotchHeight - 12)
                    )
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)
                MinimalFaceFeatures()
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        HStack {
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .clipped()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(
                    width: max(0, vm.effectiveClosedNotchHeight - 12),
                    height: max(0, vm.effectiveClosedNotchHeight - 12)
                )

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                textColor: Defaults[.coloredSpectrogram]
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                )
                .frame(
                    width: (coordinator.expandingView.show
                        && coordinator.expandingView.type == .music
                        && Defaults[.sneakPeekStyles] == .inline)
                        ? 380
                        : vm.closedNotchSize.width
                            + -cornerRadiusInsets.closed.top
                )

            HStack {
                if useMusicVisualizer {
                    Rectangle()
                        .fill(
                            Defaults[.coloredSpectrogram]
                                ? Color(nsColor: musicManager.avgColor).gradient
                                : Color.gray.gradient
                        )
                        .frame(width: 50, alignment: .center)
                        .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                        .mask {
                            AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                                .frame(width: 16, height: 12)
                        }
                } else {
                    LottieAnimationContainer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                        + gestureProgress / 2
                ),
                height: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                ),
                alignment: .center
            )
        }
        .frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    var dragDetector: some View {
        if Defaults[.boringShelf] && vm.notchState == .closed {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            vm.dropEvent = true
            ShelfStateViewModel.shared.load(providers, into: .copy)
            return true
        }
        } else {
            EmptyView()
        }
    }

    private func closeAfterHover() {
        guard !dictionaryPresented else { return }
        guard !hudDragging, !(systemHUDOpened && coordinator.sneakPeek.show && isSystemHUD) else { return }
        guard !vm.isMouseHovering(), !ShelfSelectionModel.shared.isDragging,
              !vm.anyDropZoneTargeting, !vm.isBatteryPopoverActive,
              !SharingStateManager.shared.preventNotchClose else { return }
        guard Date() >= quotaWarningUntil else { return }
        guard coordinator.currentView != .codex || Date() >= codexReminderUntil else { return }
        guard (NSApp.keyWindow as? CodexInputWindow)?.codexInputEnabled != true else { return }
        vm.close()
    }

    private func showQuotaWarning() {
        guard vm.screenUUID == coordinator.selectedScreenUUID else { return }
        quotaWarningTask?.cancel()
        quotaWarningTask = Task { @MainActor in
            while dictionaryPresented || vm.anyDropZoneTargeting || ShelfSelectionModel.shared.isDragging || SharingStateManager.shared.preventNotchClose || Date() < codexReminderUntil || (NSApp.keyWindow as? CodexInputWindow)?.codexInputEnabled == true {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            let resources = NotchResources.shared
            guard resources.warningEnabled, resources.usageEnabled, resources.usageError != nil, codexMonitor.connected else { return }
            hoverTask?.cancel(); systemHUDOpened = false
            withAnimation(animationSpring) {
                vm.open(preferredView: coordinator.currentView, size: CGSize(width: 520, height: openNotchSize.height))
                quotaWarningPresented = true
            }
            resources.recordQuotaDiagnostic("presented")
            quotaWarningUntil = Date().addingTimeInterval(resources.warningSeconds)
            NotchHapticFeedback.perform(enabled: Defaults[.enableHaptics])
            try? await Task.sleep(for: .seconds(resources.warningSeconds))
            guard !Task.isCancelled else { return }
            quotaWarningUntil = .distantPast
            while vm.isMouseHovering() || resources.loading {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
            }
            guard quotaWarningPresented, !vm.anyDropZoneTargeting, !ShelfSelectionModel.shared.isDragging else { return }
            withAnimation(animationSpring) { vm.close() }
        }
    }

    private func showCodexReminder() {
        // One display announces a shared event. Never interrupt a drag/share transaction.
        guard vm.screenUUID == coordinator.selectedScreenUUID else { return }
        codexReminderTask?.cancel()
        codexReminderTask = Task { @MainActor in
            while dictionaryPresented || vm.anyDropZoneTargeting || ShelfSelectionModel.shared.isDragging || SharingStateManager.shared.preventNotchClose {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled, !codexState.retryPaused, codexMonitor.remindersEnabled else { return }
            hoverTask?.cancel()
            let duration: Double = codexMonitor.reminderNeedsAttention ? 12 : codexMonitor.completionReminderSeconds
            codexReminderUntil = Date().addingTimeInterval(duration)
            codexMonitor.beginReminderPresentation()
            quotaWarningTask?.cancel(); quotaWarningPresented = false; quotaWarningUntil = .distantPast
            systemHUDOpened = false
            doOpen(preferredView: .codex)
            NotchHapticFeedback.perform(enabled: Defaults[.enableHaptics])
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            codexReminderUntil = .distantPast
            if !vm.isMouseHovering() && !ShelfSelectionModel.shared.isDragging && coordinator.currentView == .codex && !vm.anyDropZoneTargeting && (NSApp.keyWindow as? CodexInputWindow)?.codexInputEnabled != true {
                vm.close()
            }
        }
    }

    private var systemHUDSize: CGSize {
        compactSystemHUD ? CGSize(width: max(340, vm.closedNotchSize.width + 80),
                                 height: max(110, vm.effectiveClosedNotchHeight + 80)) : openNotchSize
    }

    private func handleSystemHUD(_ state: sneakPeek) {
        guard !dictionaryPresented else { return }
        guard vm.screenUUID == coordinator.selectedScreenUUID else { return }
        let active = state.show && [.volume, .brightness, .backlight].contains(state.type)
        if active && expandSystemHUD {
            hudCloseTask?.cancel()
            presentedHUDType = state.type; presentedHUDValue = state.value
            if vm.notchState == .closed && !ShelfSelectionModel.shared.isDragging && !vm.anyDropZoneTargeting {
                systemHUDOpened = true
                withAnimation(animationSpring) {
                    vm.open(preferredView: coordinator.currentView,
                            size: systemHUDSize)
                }
            }
        } else if systemHUDOpened && vm.notchState == .open {
            hudCloseTask?.cancel()
            hudCloseTask = Task { @MainActor in
                // Keep controls available while hovered or dragging, then close the same shell.
                while vm.isMouseHovering() || hudDragging {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                }
                if !vm.isMouseHovering() && !ShelfSelectionModel.shared.isDragging && !vm.anyDropZoneTargeting {
                    withAnimation(animationSpring) { vm.close() }
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                }
                systemHUDOpened = false
            }
        }
    }

    private func updateHUDLevel(_ value: CGFloat) {
        let level = min(1, max(0, value))
        presentedHUDValue = level
        switch presentedHUDType {
        case .volume: VolumeManager.shared.setAbsolute(Float32(level))
        case .brightness: BrightnessManager.shared.setAbsolute(value: Float32(level))
        case .backlight: KeyboardBacklightManager.shared.setAbsolute(value: Float32(level))
        default: break
        }
        coordinator.toggleSneakPeek(status: true, type: presentedHUDType, value: level)
    }

    private func doOpen(preferredView: NotchViews? = nil) {
        withAnimation(animationSpring) {
            vm.open(preferredView: preferredView)
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        
        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }
            
            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }
            
            guard vm.notchState == .closed,
                  !coordinator.sneakPeek.show,
                  Defaults[.openNotchOnHover] else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.coordinator.sneakPeek.show else { return }
                    
                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }
                    
                    if self.vm.notchState == .open && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                        self.closeAfterHover()
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open && !vm.isHoveringCalendar else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose { 
                gestureProgress = .zero
                vm.close()
            }

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let enabled: Bool
    let accept: ([NSItemProvider]) -> Bool
    private let types: [UTType] = [ShelfInternalTransfer.type, .fileURL, .url, .utf8PlainText, .plainText, .data]

    func validateDrop(info: DropInfo) -> Bool { enabled && info.hasItemsConforming(to: types) }
    func dropEntered(info: DropInfo) {
        isTargeted = validateDrop(info: info)
        updateHeaderTarget(info: info)
    }
    func dropExited(info: DropInfo) {
        isTargeted = false
        if !ShelfSelectionModel.shared.isDragging {
            // Parent/child drop regions can exchange ownership while the pointer
            // stays over the same target. Preserve that target without re-announcing.
            if NSEvent.pressedMouseButtons & 1 == 0 {
                ShelfInternalDropRouter.shared.clearHighlight()
            } else {
                ShelfInternalDropRouter.shared.update(at: NSEvent.mouseLocation, external: true)
            }
        }
    }
    private func updateHeaderTarget(info: DropInfo) {
        guard !ShelfSelectionModel.shared.isDragging else { return }
        if validateDrop(info: info) {
            ShelfInternalDropRouter.shared.update(at: NSEvent.mouseLocation, external: true)
        } else {
            ShelfInternalDropRouter.shared.clearHighlight()
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateHeaderTarget(info: info)
        // Staging never moves the source. Do not cancel the child shelf destinations.
        return DropProposal(operation: validateDrop(info: info) ? .copy : .cancel)
    }
    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard validateDrop(info: info) else { return false }
        return accept(info.itemProviders(for: types))
    }
}

#Preview {
    let vm = BoringViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
