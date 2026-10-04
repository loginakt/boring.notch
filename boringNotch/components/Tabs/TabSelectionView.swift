//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    var id: NotchViews { view }
    let label: String
    let icon: String
    let view: NotchViews
}

/// The open notch's tabs, in order. Shared by the tab bar and the horizontal swipe.
@MainActor
enum NotchTabs {
    static func isTabBarShown(shelfEmpty: Bool = ShelfStateViewModel.shared.isEmpty) -> Bool {
        Defaults[.showAIQuota]
            || ((!shelfEmpty || BoringViewCoordinator.shared.alwaysShowTabs) && Defaults[.boringShelf])
    }

    static func available() -> [NotchViews] {
        guard isTabBarShown() else { return [.home] }
        var views: [NotchViews] = [.home]
        if Defaults[.boringShelf] { views.append(.shelf) }
        if Defaults[.showAIQuota] { views.append(.quota) }
        return views
    }

    static func model(for view: NotchViews) -> TabModel? {
        switch view {
        case .home: return TabModel(label: "Home", icon: "house.fill", view: .home)
        case .shelf: return TabModel(label: "Shelf", icon: "tray.fill", view: .shelf)
        case .quota: return TabModel(label: "AI", icon: "chart.bar.fill", view: .quota)
        case .claude: return nil
        }
    }
}

extension BoringViewCoordinator {
    func selectTab(_ view: NotchViews) {
        withAnimation(.smooth) {
            currentView = view
        }
        if view == .quota {
            Task {
                await AIQuotaManager.shared.refreshIfClaudeRunning()
            }
        }
    }

    /// Moves one tab, or to the last/first tab when `toEnd`. Returns whether the tab changed.
    @discardableResult
    func stepTab(forward: Bool, toEnd: Bool = false) -> Bool {
        let tabs = NotchTabs.available()
        guard let current = tabs.firstIndex(of: currentView),
              let target = SwipeTabStepper.targetIndex(current: current, count: tabs.count, forward: forward, toEnd: toEnd)
        else { return false }
        selectTab(tabs[target])
        return true
    }
}

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Namespace var animation
    // Observed so the bar updates as soon as these settings change.
    @Default(.boringShelf) private var boringShelf
    @Default(.showAIQuota) private var showAIQuota

    private var tabs: [TabModel] {
        NotchTabs.available().compactMap(NotchTabs.model(for:))
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        coordinator.selectTab(tab.view)
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
