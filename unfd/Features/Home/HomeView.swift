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
            row(Text("بحث Spotlight والإعدادات ← لغة الجهاز"), $model.rules.systemFields)
            row(Text("الخانة تأخذ لغة آخر الكلام"), $model.rules.textDecides)
            row(Text("تذكّر لغتي لكل محادثة"), $model.rules.chatMemory)
            row(Text("تعلّم من تصحيحاتي"), $model.rules.learn)
            row(Text("بعد / ← إنجليزي، والمسافة ترجّع لغتك"), $model.rules.slashCommands)
            row(Text(Self.arabic("صحّح الكلمة تلقائيًا وأنا أكتب")), $model.rules.autoFix)
            row(Text("الأرقام دائماً 1234"), $model.westernDigits)
            row(Text("أظهر اللغة عند المؤشر لما تتغير"), $model.showIndicator)
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
                Text("تصحيحاتك لاختيار البرنامج اليوم")
                Spacer()
                Text(String(model.correctionsToday)).font(.headline.monospacedDigit())
            }
            HStack {
                Text("تبديل وسط الكتابة اليوم").foregroundStyle(.secondary)
                Spacer()
                Text(String(model.midTextToday)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if model.rules.autoFix {
                HStack {
                    Text("تصحيحات تلقائية اليوم: \(String(model.autoFixesToday))").foregroundStyle(.secondary)
                    Spacer()
                    Text("تراجعت عنها: \(String(model.undoneFixesToday))").foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("محادثات محفوظة: \(String(model.memory.count))").foregroundStyle(.secondary)
                Spacer()
                Button("مسح") { model.clearMemory() }.controlSize(.small).disabled(model.memory.isEmpty)
            }
            HStack {
                Text("أماكن متعلَّمة: \(String(model.learner.count))").foregroundStyle(.secondary)
                Spacer()
                Button("مسح") { model.clearLearned() }.controlSize(.small).disabled(model.learner.count == 0)
            }
            row(Text("يشتغل مع تشغيل الجهاز"), Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))

            Divider()
            Button("إنهاء unfd") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    /// The panel is Arabic only today; a string that also has an English entry in the catalog is read from the
    /// Arabic table on purpose, so one row never shows up in English on an English-language Mac.
    private static func arabic(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource: "ar", ofType: "lproj"), let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Label on one side, switch on the other, so every switch lines up.
    private func row(_ label: Text, _ isOn: Binding<Bool>) -> some View {
        HStack {
            label.accessibilityHidden(true)
            Spacer(minLength: 8)
            // VoiceOver reads the row's text as the switch's name.
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .accessibilityLabel(label)
        }
    }

    private var nowBox: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("الآن").font(.caption).foregroundStyle(.secondary)
            if let lang = model.nowLang, let reason = model.nowReason {
                // Each name sits in its own isolate (U+2068 ... U+2069) so two English names never merge in the RTL line.
                Text("\u{200F}\u{2068}\(model.nowApp)\u{2069}\(model.nowPlace.isEmpty ? "" : " · \u{2068}\(model.nowPlace)\u{2069}") ← \(lang.arabicName)")
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
