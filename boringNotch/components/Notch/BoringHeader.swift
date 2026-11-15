//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @StateObject var tvm = ShelfStateViewModel.shared
    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if vm.notchState == .open {
                    TabSelectionView()
                } else if vm.notchState == .open {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open {
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 4) {
                if vm.notchState == .open && coordinator.sneakPeek.show && [.volume, .brightness, .backlight].contains(coordinator.sneakPeek.type) {
                    let type = coordinator.sneakPeek.type
                    Image(systemName: type == .volume ? (coordinator.sneakPeek.value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") : type == .brightness ? "sun.max.fill" : "light.max")
                        .font(.system(size: 12))
                    ProgressView(value: min(1, max(0, coordinator.sneakPeek.value))).frame(width: 54).tint(.white)
                    Text("\(Int(coordinator.sneakPeek.value * 100))%")
                        .font(.system(size: 10, design: .monospaced)).monospacedDigit().frame(width: 30)
                } else if vm.notchState == .open {
                    if Defaults[.showMirror] {
                        Button(action: {
                            vm.toggleCameraPreview()
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Image(systemName: "web.camera")
                                        .foregroundColor(.white)
                                        .padding()
                                        .imageScale(.medium)
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    if Defaults[.settingsIconInNotch] {
                        Button(action: {
                            SettingsWindowController.shared.showWindow()
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Image(systemName: "gear")
                                        .foregroundColor(.white)
                                        .padding()
                                        .imageScale(.medium)
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    if Defaults[.showBatteryIndicator] {
                        BoringBatteryView(
                            batteryWidth: 30,
                            isCharging: batteryModel.isCharging,
                            isInLowPowerMode: batteryModel.isInLowPowerMode,
                            isPluggedIn: batteryModel.isPluggedIn,
                            levelBattery: batteryModel.levelBattery,
                            maxCapacity: batteryModel.maxCapacity,
                            timeToFullCharge: batteryModel.timeToFullCharge,
                            isForNotification: false
                        )
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
