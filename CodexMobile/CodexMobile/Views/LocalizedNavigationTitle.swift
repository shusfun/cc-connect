import SwiftUI

/// UIKit 导航栏不会总是重新解析相同的 LocalizedStringKey；语言变化时发布新的展示标题。
private struct LocalizedNavigationTitleModifier: ViewModifier {
    @Environment(\.locale) private var locale
    let key: String

    func body(content: Content) -> some View {
        let _ = locale
        content.navigationTitle(Text(verbatim: L10n.string(key)))
    }
}

extension View {
    /// 仅用于应用自有标题；任务名称、路径和设备备注继续原样展示。
    func localizedNavigationTitle(_ key: String) -> some View {
        modifier(LocalizedNavigationTitleModifier(key: key))
    }
}
