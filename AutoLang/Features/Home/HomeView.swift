import SwiftUI

struct HomeView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("AutoLang")
                .font(.largeTitle.bold())
            Text("Switches the keyboard language by itself: English in address bars, the chat's language in WhatsApp and other apps.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview {
    HomeView()
}
