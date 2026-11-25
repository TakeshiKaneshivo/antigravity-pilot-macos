import SwiftUI

struct UpdatePopoverView: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject var appModel: AppModel
    @ObservedObject var updateStore: UpdateStore

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            headerRow

            Divider()

            contentBody

            Divider()

            footerRow
        }
        .padding(14)
        .frame(width: 348)
        .environment(\.appLanguage, lang)
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(headerTint)
                .frame(width: 32, height: 32)
                .background(headerTint.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(L10n.t("软件更新", "Software Update", lang))
                        .font(.callout.weight(.semibold))
                    statusPill
                }
                Text(L10n.t(
                    zhHans: "当前版本 v\(updateStore.currentVersion)",
                    zhHant: "目前版本 v\(updateStore.currentVersion)",
                    en: "Current version v\(updateStore.currentVersion)",
                    ru: "Текущая версия v\(updateStore.currentVersion)",
                    lang
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if !updateStore.state.isBusy {
                Button {
                    updateStore.checkForUpdates(config: appModel.config, userInitiated: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.t("检查更新", "Check for Updates", lang))
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        switch updateStore.state {
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t(
                    "点击下方按钮从 GitHub Releases 检查最新可用版本。",
                    "Check GitHub Releases for the latest available version.",
                    lang
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if let checked = updateStore.lastCheckedAt {
                    lastCheckedText(checked)
                }

                HStack {
                    Spacer()
                    Button(L10n.t("立即检查更新", "Check Now", lang)) {
                        updateStore.checkForUpdates(config: appModel.config, userInitiated: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

        case .checking:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.t("正在检查最新版本...", "Checking for updates...", lang))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)

        case .upToDate(let checkedAt, let route):
            VStack(alignment: .leading, spacing: 8) {
                PilotRecessedBox(padding: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t("当前已是最新版本", "You're up to date", lang))
                                .font(.callout.weight(.medium))
                            Text(route.localizedLabel(lang))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                lastCheckedText(checkedAt)
            }

        case .available(let manifest, let route, let osSupported, let eligibility):
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text("v\(updateStore.currentVersion) → v\(manifest.version)")
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                    Spacer()
                    if let size = manifest.dmg.size, size > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Text(route.localizedLabel(lang))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let notes = manifest.notes?.text(for: lang) {
                    PilotRecessedBox(padding: 9) {
                        ScrollView {
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 132)
                    }
                }

                if !osSupported {
                    warningBox(L10n.t(
                        zhHans: "此版本需要 macOS \(manifest.minMacOS ?? "13.0") 或更高版本，当前系统不支持更新。",
                        zhHant: "此版本需要 macOS \(manifest.minMacOS ?? "13.0") 或更高版本，目前系統不支援更新。",
                        en: "Requires macOS \(manifest.minMacOS ?? "13.0") or later; unsupported on this Mac.",
                        ru: "Требуется macOS \(manifest.minMacOS ?? "13.0") или новее; не поддерживается на этом Mac.",
                        lang
                    ))
                } else if case .manualFallbackRequired(let reason) = eligibility {
                    warningBox(reason)
                }

                HStack(spacing: 7) {
                    Button {
                        appModel.config.skippedUpdateVersion = nil
                        appModel.savePreferencesOnly()
                        updateStore.startDownloadAndInstall(config: appModel.config)
                    } label: {
                        Text(downloadButtonTitle(eligibility: eligibility))
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!osSupported)

                    Button(L10n.t("忽略此版本", "Skip Version", lang)) {
                        appModel.config.skippedUpdateVersion = manifest.version
                        appModel.savePreferencesOnly()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    Button(L10n.t("查看 Release", "Release Notes", lang)) {
                        updateStore.openReleasePage()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.caption)
                }
            }

        case .downloading(let manifest, let downloaded, let total, let route):
            let fraction = total > 0 ? min(max(Double(downloaded) / Double(total), 0), 1) : 0
            let percent = total > 0 ? Int((fraction * 100).rounded()) : 0
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.t(
                        zhHans: "正在下载 v\(manifest.version)...",
                        zhHant: "正在下載 v\(manifest.version)...",
                        en: "Downloading v\(manifest.version)...",
                        ru: "Загрузка v\(manifest.version)...",
                        lang
                    ))
                    .font(.callout.weight(.medium))
                    Spacer()
                    if total > 0 {
                        Text("\(percent)%")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                PilotLinearBar(fraction: fraction, tint: .accentColor, height: 7)

                HStack {
                    let downloadedStr = ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
                    let totalStr = total > 0 ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : "…"
                    Text("\(downloadedStr) / \(totalStr) · \(route.localizedLabel(lang))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button(L10n.t("取消", "Cancel", lang)) {
                        updateStore.cancelDownload()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

        case .verifying(_, let stage):
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(stage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)

        case .installing(let manifest):
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.t(
                    zhHans: "正在应用 v\(manifest.version) 并重启...",
                    zhHant: "正在套用 v\(manifest.version) 並重新啟動...",
                    en: "Applying v\(manifest.version) and relaunching...",
                    ru: "Установка v\(manifest.version) и перезапуск...",
                    lang
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)

        case .readyForManualInstall(_, _, let reason):
            VStack(alignment: .leading, spacing: 9) {
                warningBox(reason)

                HStack(spacing: 8) {
                    Button(L10n.t("打开安装包 (.dmg)", "Open Installer (.dmg)", lang)) {
                        updateStore.openManualInstaller()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Spacer()

                    Button(L10n.t("查看 Release", "Release Notes", lang)) {
                        updateStore.openReleasePage()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.caption)
                }
            }

        case .failed(let message, _):
            VStack(alignment: .leading, spacing: 9) {
                PilotRecessedBox(padding: 9) {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .padding(.top, 1)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    Button(L10n.t("重试", "Retry", lang)) {
                        updateStore.checkForUpdates(config: appModel.config, userInitiated: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Spacer()

                    Button(L10n.t("前往 Releases", "Open Releases", lang)) {
                        updateStore.openReleasePage()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.caption)
                }
            }
        }
    }

    private var footerRow: some View {
        Toggle(
            L10n.t("启动时自动检查更新", "Automatically check for updates", lang),
            isOn: $appModel.config.autoCheckUpdates
        )
        .font(.caption)
        .onChange(of: appModel.config.autoCheckUpdates) { _ in
            appModel.savePreferencesOnly()
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch updateStore.state {
        case .idle:
            EmptyView()
        case .checking:
            PilotStatusPill(text: L10n.t("检查中", "Checking", lang), color: .secondary, showDot: false)
        case .upToDate:
            PilotStatusPill(text: L10n.t("已是最新", "Up to Date", lang), color: .green)
        case .available(let manifest, _, _, _):
            PilotStatusPill(text: "v\(manifest.version)", color: .red)
        case .downloading:
            PilotStatusPill(text: L10n.t("下载中", "Downloading", lang), color: .blue)
        case .verifying, .installing:
            PilotStatusPill(text: L10n.t("安装中", "Installing", lang), color: .blue)
        case .readyForManualInstall:
            PilotStatusPill(text: L10n.t("待手动安装", "Manual Install", lang), color: .orange)
        case .failed:
            PilotStatusPill(text: L10n.t("检查失败", "Failed", lang), color: .red)
        }
    }

    private var headerTint: Color {
        switch updateStore.state {
        case .upToDate: return .green
        case .available: return .red
        case .readyForManualInstall: return .orange
        case .failed: return .red
        default: return .accentColor
        }
    }

    private func downloadButtonTitle(eligibility: InstallEligibility) -> String {
        switch eligibility {
        case .inPlaceSupported:
            return L10n.t("下载并更新", "Download & Update", lang)
        case .manualFallbackRequired:
            return L10n.t("下载安装包", "Download DMG", lang)
        }
    }

    private func lastCheckedText(_ date: Date) -> some View {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let rel = formatter.localizedString(for: date, relativeTo: Date())
        return Text(L10n.t(
            zhHans: "上次检查：\(rel)",
            zhHant: "上次檢查：\(rel)",
            en: "Last checked: \(rel)",
            ru: "Последняя проверка: \(rel)",
            lang
        ))
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func warningBox(_ message: String) -> some View {
        PilotRecessedBox(padding: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .padding(.top, 1)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
