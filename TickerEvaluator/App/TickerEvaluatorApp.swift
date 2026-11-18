import SwiftUI

struct TickerEvaluatorApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup("Ticker Evaluator") {
            ReportScreen(model: model)
                .frame(minWidth: 980, minHeight: 700)
        }
    }
}
