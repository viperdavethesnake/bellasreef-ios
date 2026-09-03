// Bella's Reef iOS — closed source.

import SwiftUI
import WidgetKit

/// The widget extension's entry point (UX review D2).
///
/// One member today: the Live Activity for a manual hold. A `WidgetBundle`
/// rather than a bare `@main Widget` because Home Screen widgets are the
/// obvious next thing to land here, and adding one to a bundle is a line
/// where converting a lone widget into a bundle is a rewrite of the entry
/// point.
@main
struct HoldActivityBundle: WidgetBundle {
    var body: some Widget {
        HoldLiveActivity()
    }
}
