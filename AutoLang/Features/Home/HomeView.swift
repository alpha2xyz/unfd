import SwiftUI

/// The panel that opens from the menu bar.
struct HomeView: View {
    @Bindable var model: AppModel
    /// Debug snapshots only: show the main panel even before the permission is granted.
    var forceTrusted = false

    var body: some View {
        Group {
            if model.trusted || forceTrusted { panel } else { PermissionView(model: model) }
        }
        .padding(14)
        .onAppear { if !forceTrusted { model.refresh() } }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(Text("تبديل اللغة تلقائياً").font(.headline), $model.enabled)

            nowBox

            Divider()
            row(Text("شريط العنوان والروابط ← إنجليزي"), $model.rules.linkFields)
            row(Text("الخانة تأخذ لغة آخر الكلام"), $model.rules.textDecides)
            row(Text("تذكّر لغتي لكل محادثة"), $model.rules.chatMemory)
            row(Text("الأرقام دائماً 1234"), $model.westernDigits)
            if model.westernDigits && !model.arabic123Enabled {
                HStack {
                    Text("لوحة Arabic – 123 غير مفعّلة").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("فعّلها") { model.enableArabic123() }.controlSize(.small)
                }
            }
            HStack {
                Text("زر تصليح الكلام الغلط")
                Spacer()
                Text(verbatim: "⌥⇧Space").font(.callout.monospaced()).foregroundStyle(.secondary)
                    .environment(\.layoutDirection, .leftToRight)
            }

            Divider()
            HStack {
                Text("ضغطاتك اليدوية على زر اللغة اليوم")
                Spacer()
                Text(String(model.manualToday)).font(.headline.monospacedDigit())
            }
            HStack {
                Text("محادثات محفوظة: \(String(model.memory.count))").foregroundStyle(.secondary)
                Spacer()
                Button("مسح") { model.clearMemory() }.controlSize(.small).disabled(model.memory.isEmpty)
            }
            row(Text("يشتغل مع تشغيل الجهاز"), Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))

            Divider()
            Button("إنهاء AutoLang") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    /// Label on one side, switch on the other, so every switch lines up.
    private func row(_ label: Text, _ isOn: Binding<Bool>) -> some View {
        HStack {
            label
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }

    private var nowBox: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("الآن").font(.caption).foregroundStyle(.secondary)
            if let lang = model.nowLang, let reason = model.nowReason {
                Text("\u{200F}\(model.nowApp)\(model.nowPlace.isEmpty ? "" : " · \(model.nowPlace)") ← \(lang.arabicName)")
                    .lineLimit(2)
                Text("\u{200F}السبب: \(reason.arabic)").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("اضغط على أي خانة كتابة وبيختار اللغة قبل ما تكتب").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
