//
//  AIQuotaView.swift
//  boringNotch
//

import SwiftUI

struct AIQuotaView: View {
    @ObservedObject private var quotaManager = AIQuotaManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AI Quota")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                if !quotaManager.isClaudeRunning {
                    Text("Paused · Claude closed")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.gray)
                }
                Button {
                    Task {
                        await quotaManager.refreshNow()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(quotaManager.isLoading ? Color.secondary : Color.white)
                .disabled(quotaManager.isLoading)
                .help(quotaManager.isClaudeRunning ? "Refresh AI quota" : "Refresh once (auto-refresh runs only while Claude is open)")
            }

            QuotaCardView(
                provider: .claude,
                result: quotaManager.claudeQuota,
                isLoading: quotaManager.isLoading,
                signInExpired: quotaManager.signInExpired
            )
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
