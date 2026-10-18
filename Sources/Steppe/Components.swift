import SteppeCore
import SwiftUI

struct StageRow: View {
    let title: LocalizedStringKey
    let state: StageState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(state == .pending ? Theme.textSecondary : Theme.textPrimary)
                detail
            }
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(Theme.textSecondary.opacity(0.6))
        case .running:
            ProgressView().controlSize(.small).tint(Theme.amber)
        case .waitingForUser:
            Image(systemName: "hand.tap.fill").foregroundStyle(Theme.warning)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
        }
    }

    @ViewBuilder private var detail: some View {
        switch state {
        case .running(let progress, let text):
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                if let progress {
                    ThinProgress(value: progress)
                }
            }
        case .waitingForUser(let text):
            Text(verbatim: text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.warning)
        case .failed(let text):
            Text(verbatim: text).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }
}

struct ThinProgress: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(LinearGradient(colors: [Theme.amber, Theme.amberDeep], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 5)
        .animation(.linear(duration: 0.25), value: value)
    }
}

struct Brand: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            Text("Steppe")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

extension ByteCountFormatter {
    static func gigabytes(_ bytes: Int64) -> String {
        string(fromByteCount: bytes, countStyle: .file)
    }
}
