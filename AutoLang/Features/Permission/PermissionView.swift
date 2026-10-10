import SwiftUI

/// First run: the one permission the app needs, and why.
struct PermissionView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("يحتاج AutoLang إذن «تسهيلات الاستخدام» مرة وحدة").font(.headline)
            Text("عشان يعرف أي خانة أنت فيها ويقرأ آخر الرسائل. النص يُقرأ على جهازك فقط ولا يُحفظ ولا يُرسل.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("افتح الإعدادات") { model.askForPermission() }
                .buttonStyle(.borderedProminent)
            Text("فعّل AutoLang في القائمة، وبعدها تشتغل هذي القائمة لحالها.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Button("إنهاء AutoLang") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
}
