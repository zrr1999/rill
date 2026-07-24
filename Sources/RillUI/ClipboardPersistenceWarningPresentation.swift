import SwiftUI
import RillCore

struct ClipboardPersistenceWarningPresentation: Equatable {
    let title: String
    let message: String
    let retryTitle: String?
    let resetTitle: String?

    static func make(
        availability: ClipboardPersistenceAvailability,
        resetFailed: Bool = false,
        language: AppLanguage
    ) -> ClipboardPersistenceWarningPresentation? {
        switch (availability, language) {
        case (.available, _):
            return nil
        case (.notConfigured, .english):
            return ClipboardPersistenceWarningPresentation(
                title: "Clipboard history is session-only",
                message: "Protected clipboard storage could not be started. Items, groups, and app routing created in this session will be lost when Rill quits.",
                retryTitle: nil,
                resetTitle: nil
            )
        case (.notConfigured, .simplifiedChinese):
            return ClipboardPersistenceWarningPresentation(
                title: "剪贴板历史仅在本次会话中可用",
                message: "受保护的剪贴板存储未能启动。本次会话创建的条目、分组和应用路由会在 Rill 退出后丢失。",
                retryTitle: nil,
                resetTitle: nil
            )
        case (.cleanupPending, .english):
            return ClipboardPersistenceWarningPresentation(
                title: "Clipboard storage cleanup is pending",
                message: "Saved and session-only clipboard data was removed, but encrypted database residue could not be fully purged. Rill will retry cleanup before opening storage next time.",
                retryTitle: nil,
                resetTitle: nil
            )
        case (.cleanupPending, .simplifiedChinese):
            return ClipboardPersistenceWarningPresentation(
                title: "剪贴板存储清理尚未完成",
                message: "已保存及本次会话中的剪贴板数据已删除，但加密数据库残留尚未完全清除。Rill 会在下次打开存储前重试清理。",
                retryTitle: nil,
                resetTitle: nil
            )
        case (.loadUnavailable, .english):
            return ClipboardPersistenceWarningPresentation(
                title: "Clipboard history storage is unavailable",
                message: resetFailed
                    ? "Reset could not be completed. Rill did not delete or overwrite the protected data or session-only clipboard state. Check storage access and try again."
                    : "Changes made in this session will not be saved. Rill did not overwrite your existing data. Repair storage access, or reset storage to permanently delete all saved and session-only clipboard items, groups, and routing.",
                retryTitle: nil,
                resetTitle: "Reset Storage…"
            )
        case (.loadUnavailable, .simplifiedChinese):
            return ClipboardPersistenceWarningPresentation(
                title: "剪贴板历史存储不可用",
                message: resetFailed
                    ? "重置未能完成；Rill 未删除或覆盖受保护数据及本次会话内容。请检查存储访问后重试。"
                    : "本次会话中的修改不会持久化；Rill 未覆盖原有数据。请修复存储访问，或重置存储以永久删除所有已保存及本次会话中的剪贴板条目、分组和路由。",
                retryTitle: nil,
                resetTitle: "重置存储…"
            )
        case (.saveFailed, .english):
            return ClipboardPersistenceWarningPresentation(
                title: "Clipboard history has not been saved",
                message: "Automatic retry is in progress. You can also retry immediately.",
                retryTitle: "Retry Now",
                resetTitle: nil
            )
        case (.saveFailed, .simplifiedChinese):
            return ClipboardPersistenceWarningPresentation(
                title: "剪贴板历史尚未保存",
                message: "正在自动重试；你也可以立即重试。",
                retryTitle: "立即重试",
                resetTitle: nil
            )
        }
    }
}

struct ClipboardPersistenceResetConfirmationPresentation: Equatable {
    let title: String
    let message: String
    let actionTitle: String

    static func make(language: AppLanguage) -> Self {
        switch language {
        case .english:
            return Self(
                title: "Reset clipboard storage?",
                message: "This permanently deletes all saved and session-only clipboard items, groups, and app routing. This cannot be undone.",
                actionTitle: "Reset Clipboard Storage"
            )
        case .simplifiedChinese:
            return Self(
                title: "要重置剪贴板存储吗？",
                message: "此操作会永久删除所有已保存及本次会话中的剪贴板条目、分组和应用路由，且无法撤销。",
                actionTitle: "重置剪贴板存储"
            )
        }
    }
}

struct ClipboardPersistenceWarningBanner: View {
    let presentation: ClipboardPersistenceWarningPresentation
    let resetConfirmation: ClipboardPersistenceResetConfirmationPresentation
    let resetCancelTitle: String
    let isRetrying: Bool
    let isResetting: Bool
    let retryFocus: FocusState<ClipboardViewFocusTarget?>.Binding
    let retry: () -> Void
    let reset: () -> Void
    @State private var isResetConfirmationPresented = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.callout.weight(.semibold))
                Text(presentation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let retryTitle = presentation.retryTitle {
                Button(action: retry) {
                    if isRetrying {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(retryTitle)
                        }
                    } else {
                        Text(retryTitle)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRetrying)
                .focused(retryFocus, equals: .persistenceRetry)
                .accessibilityIdentifier("clipboard.persistence.retry")
            }

            if let resetTitle = presentation.resetTitle {
                Button(role: .destructive) {
                    isResetConfirmationPresented = true
                } label: {
                    if isResetting {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(resetTitle)
                        }
                    } else {
                        Text(resetTitle)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isResetting)
                .focused(retryFocus, equals: .persistenceRetry)
                .accessibilityIdentifier("clipboard.persistence.reset")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            Color.orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35))
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipboard.persistence.warning")
        .confirmationDialog(
            resetConfirmation.title,
            isPresented: $isResetConfirmationPresented
        ) {
            Button(resetConfirmation.actionTitle, role: .destructive) {
                isResetConfirmationPresented = false
                reset()
            }
            Button(resetCancelTitle, role: .cancel) {
                isResetConfirmationPresented = false
            }
        } message: {
            Text(resetConfirmation.message)
        }
    }
}

struct ClipboardStorageWarningPresentation: Equatable {
    let title: String
    let message: String

    static func make(
        reason: ClipboardStorageRejectionReason?,
        context: ClipboardStoragePressureContext? = .mutationRejected,
        language: AppLanguage
    ) -> ClipboardStorageWarningPresentation? {
        guard let reason else { return nil }
        if context == .legacyOverCapacity {
            switch language {
            case .english:
                return ClipboardStorageWarningPresentation(
                    title: "Stored clipboard exceeds the current limit",
                    message: "Existing active items were preserved. New or enlarging items are blocked until you use or delete enough stored content."
                )
            case .simplifiedChinese:
                return ClipboardStorageWarningPresentation(
                    title: "现有剪贴板内容超过当前上限",
                    message: "已有活动条目已保留；在使用或删除足够内容前，新增或扩大的条目将被阻止。"
                )
            }
        }
        if context == .persistedStateRejected {
            switch language {
            case .english:
                return ClipboardStorageWarningPresentation(
                    title: "Stored clipboard state exceeds its declared limits",
                    message: "Rill did not load or overwrite the protected state. Repair storage access, or use the confirmed reset action above."
                )
            case .simplifiedChinese:
                return ClipboardStorageWarningPresentation(
                    title: "已存剪贴板状态超过声明上限",
                    message: "Rill 未加载或覆盖受保护状态。请修复存储访问，或使用上方需要确认的重置操作。"
                )
            }
        }
        switch (reason, language) {
        case (.itemTooLarge, .english):
            return ClipboardStorageWarningPresentation(
                title: "Clipboard item was not saved",
                message: "The latest item exceeds the local per-item storage limit. Existing clipboard items were not changed."
            )
        case (.itemTooLarge, .simplifiedChinese):
            return ClipboardStorageWarningPresentation(
                title: "剪贴板条目未保存",
                message: "最新条目超过本地单条存储上限；现有剪贴板内容未被修改。"
            )
        case (.imageRepresentationInvalid, .english):
            return ClipboardStorageWarningPresentation(
                title: "Clipboard image was not saved",
                message: "The latest PNG or TIFF representation is malformed or uses an unsupported encoding. Existing clipboard items were not changed."
            )
        case (.imageRepresentationInvalid, .simplifiedChinese):
            return ClipboardStorageWarningPresentation(
                title: "剪贴板图像未保存",
                message: "最新的 PNG 或 TIFF 表示格式损坏或使用了不受支持的编码；现有剪贴板内容未被修改。"
            )
        case (.activeItemLimitReached, .english):
            return ClipboardStorageWarningPresentation(
                title: "Active clipboard is full",
                message: "The latest item was not added because active or in-use items cannot be removed automatically. Use or delete items, then try again."
            )
        case (.activeItemLimitReached, .simplifiedChinese):
            return ClipboardStorageWarningPresentation(
                title: "活动剪贴板已满",
                message: "活动或使用中的条目不会被自动移除，因此最新条目未加入。请先使用或删除部分条目后重试。"
            )
        case (.activeItemInUse, .english):
            return ClipboardStorageWarningPresentation(
                title: "Clipboard items are currently in use",
                message: "The application assignment was not changed because one or more affected items are being pasted. Try again after the current paste finishes."
            )
        case (.activeItemInUse, .simplifiedChinese):
            return ClipboardStorageWarningPresentation(
                title: "剪贴板条目正在使用中",
                message: "部分受影响条目正在粘贴，因此应用分组未更改。请在当前粘贴完成后重试。"
            )
        case (.historyItemLimitReached, .english):
            return ClipboardStorageWarningPresentation(
                title: "Clipboard history is full",
                message: "The latest history-only item was not saved. Clear older history, then try again."
            )
        case (.historyItemLimitReached, .simplifiedChinese):
            return ClipboardStorageWarningPresentation(
                title: "剪贴板历史已满",
                message: "最新的仅历史条目未保存。请清理较早历史后重试。"
            )
        case (.totalByteLimitReached, .english):
            return ClipboardStorageWarningPresentation(
                title: "Clipboard storage is full",
                message: "Older history was not enough to free space, so the latest item was not added. Active and in-use items were preserved."
            )
        case (.totalByteLimitReached, .simplifiedChinese):
            return ClipboardStorageWarningPresentation(
                title: "剪贴板存储已满",
                message: "清理较早历史后仍无足够空间，因此最新条目未加入；活动和使用中的条目已保留。"
            )
        case (.itemEncodingFailed, .english):
            return ClipboardStorageWarningPresentation(
                title: "Clipboard item was not saved",
                message: "The latest item could not be prepared for protected local storage. Existing clipboard items were not changed."
            )
        case (.itemEncodingFailed, .simplifiedChinese):
            return ClipboardStorageWarningPresentation(
                title: "剪贴板条目未保存",
                message: "最新条目无法写入受保护的本地存储；现有剪贴板内容未被修改。"
            )
        case (.metadataLimitReached, .english):
            return ClipboardStorageWarningPresentation(
                title: "Clipboard organization limit reached",
                message: "The group or application routing change exceeds the local organization limit. Existing clipboard organization was not changed."
            )
        case (.metadataLimitReached, .simplifiedChinese):
            return ClipboardStorageWarningPresentation(
                title: "已达到剪贴板组织上限",
                message: "分组或应用路由变更超过本地组织上限；现有剪贴板组织未被修改。"
            )
        }
    }
}

struct ClipboardStorageWarningBanner: View {
    let presentation: ClipboardStorageWarningPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.callout.weight(.semibold))
                Text(presentation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            Color.orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35))
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipboard.storage.warning")
    }
}
