import SwiftUI

/// 语言 + 主题的统一注入点：三个 Window scene + MenuBarExtra 的内容根视图都调用
/// `.appEnvironment(language:theme:)`，两件事合并成一次调用——触发时机相同
/// （`@AppStorage` 变化 → `App.body` 重新求值 → 每个 scene 拿到新值），分开写只会
/// 让每个 scene 构造点多一行重复调用，没有隔离收益。
extension View {
    func appEnvironment(language: AppPreferences.Language, theme: AppPreferences.Theme) -> some View {
        self
            .environment(\.locale, language.resolvedLocale)
            .preferredColorScheme(theme.resolvedColorScheme)
    }
}
