import Combine
import Sparkle
import SwiftUI

/// Sparkle의 수동 업데이트 확인 메뉴와 활성 상태를 SwiftUI에 연결한다.
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("업데이트 확인…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}
