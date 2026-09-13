import SwiftUI
import WidgetKit

/// WidgetKit 入口：目前只挂充电功率小组件；后续新增桌面组件在此注册。
@main
struct CableScopeWidgetBundle: WidgetBundle {
    var body: some Widget {
        CableScopeChargingWidget()
    }
}
