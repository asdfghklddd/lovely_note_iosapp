//
//  ContentView.swift
//  笺间
//
//  MVP UI skeleton: TabView (List / Compose / Settings) + Detail navigation.
//

import SwiftUI
import Combine
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: Router

    var body: some View {
        TabView(selection: $router.selectedTabIndex) {
            NavigationStack(path: $router.inboxPath) { ListView() }
                .tag(0)
                .tabItem { Label("信箱", systemImage: "tray") }

            NavigationStack { ComposeView() }
                .tag(1)
                .tabItem { Label("写信", systemImage: "pencil") }

            NavigationStack { SettingsView() }
                .tag(2)
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}

// MARK: - List View

private struct ListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: Router
    @State private var selection: Letter.Status? = nil

    private var filtered: [Letter] {
        let now = Date()
        return model.letters.filter { letter in
            guard let sel = selection else { return true }
            return letter.status(now: now) == sel
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("筛选", selection: $selection) {
                Text("全部").tag(Letter.Status?.none)
                Text("在途").tag(Letter.Status?.some(.inTransit))
                Text("可开封").tag(Letter.Status?.some(.ready))
                Text("已开封").tag(Letter.Status?.some(.opened))
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])

            if filtered.isEmpty {
                ContentEmptyView()
            } else {
                List(filtered) { letter in
                    NavigationLink(value: letter.id) {
                        LetterRow(letter: letter)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationDestination(for: String.self) { id in
            DetailView(letterId: id)
        }
        .navigationTitle("信箱")
        .onAppear { model.refresh() }
        .onChange(of: router.pendingDetailLetterId) { _, newId in
            guard let id = newId else { return }
            // Navigate programmatically to detail
            router.inboxPath = [id]
            router.pendingDetailLetterId = nil
        }
    }
}

private struct LetterRow: View {
    @EnvironmentObject private var model: AppModel
    let letter: Letter

    private func subtitle(_ letter: Letter) -> (text: String, color: Color, icon: String) {
        let now = Date()
        switch letter.status(now: now) {
        case .inTransit:
            let remain = timeRemaining(until: letter.unlockAt, from: now)
            return ("预计 \(remain)后可开封", .gray, "timer")
        case .ready:
            return ("已抵达，可在家开封", .green, "checkmark.seal")
        case .opened:
            return ("已开封", .secondary, "envelope.open")
        }
    }

    var body: some View {
        let sub = subtitle(letter)
        HStack(spacing: 12) {
            // Placeholder thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.99, green: 0.98, blue: 0.97))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 0.5))
                Image(systemName: letter.openedAt == nil ? "envelope" : "envelope.open")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.primary)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 6) {
                Text(letter.content.count > 12 ? String(letter.content.prefix(12)) + "…" : letter.content)
                    .font(.headline)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Image(systemName: sub.icon)
                        .font(.footnote)
                        .foregroundColor(sub.color)
                    Text(sub.text)
                        .font(.subheadline)
                        .foregroundColor(sub.color)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Compose View

private struct ComposeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: Router

    @State private var draftText: String = ""
    @State private var committedText: String = "" // last accepted by rate limit
    @State private var lastAcceptTime: Date = Date()
    @State private var carryover: Double = 0 // fractional allowance
    @State private var showThrottledHint: Bool = false
    @State private var route: DelayPolicy.Route = .local1d

    private var weeklyInkUsed: Int { model.weeklyInkUsedByMeThisWeek() }
    private var weeklyLimit: Int { AppConstants.weeklyInkLimit }
    private var remainingInk: Int { max(0, weeklyLimit - weeklyInkUsed) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Paper backdrop placeholder
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(white: 0.98))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color(.separator), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.04), radius: 6, y: 3)

                    TextEditor(text: $draftText)
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .frame(minHeight: 220)
                        .font(.system(size: 18))
                        .onChange(of: draftText) { _, newValue in
                            enforceInkLimitAndRateLimit(newValue: newValue)
                        }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 8) {
                    InkMeter(used: weeklyInkUsed + committedText.count, total: weeklyLimit)
                    if showThrottledHint {
                        Text("正在缓缓落笔…（限速 \(Int(AppConstants.typingCharsPerSecond)) 字/秒）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("邮路")
                        .font(.subheadline).bold()
                    RouteSelector(selection: $route)
                }

                HStack {
                    Button {
                        guard !committedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        model.addLetter(content: committedText, route: route)
                        // Reset current draft after saving to App
                        draftText = ""
                        committedText = ""
                        showThrottledHint = false
                    } label: {
                        Label("放入信封（保存到 App）", systemImage: "seal")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()
                }
            }
            .padding()
        }
        .navigationTitle("写慢信")
        .onAppear {
            // Reset rate limiter state when entering
            lastAcceptTime = Date()
            carryover = 0
            // Prefill without rate-limit interference
            if let prefill = router.composePrefill, !prefill.isEmpty {
                committedText = prefill
                draftText = prefill
                router.composePrefill = nil
            }
        }
    }

    private func enforceInkLimitAndRateLimit(newValue: String) {
        // 1) Weekly ink hard cap
        let maxAllowedByInk = max(0, remainingInk)
        var proposed = String(newValue.prefix(maxAllowedByInk))

        // 2) Rate limit for additions only; deletions always allowed
        if proposed.count <= committedText.count {
            committedText = proposed
            draftText = proposed
            lastAcceptTime = Date()
            showThrottledHint = false
            return
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastAcceptTime)
        let allowance = elapsed * AppConstants.typingCharsPerSecond + carryover
        let addedCount = proposed.count - committedText.count
        let allowedAdd = Int(floor(allowance))

        if allowedAdd <= 0 {
            // reject; revert to last committed
            draftText = committedText
            showThrottledHint = true
            return
        }

        let acceptCount = min(allowedAdd, addedCount)
        let acceptedSuffix = proposed.suffix(addedCount).prefix(acceptCount)
        let newCommitted = committedText + acceptedSuffix

        committedText = String(newCommitted)
        draftText = committedText
        lastAcceptTime = now
        carryover = allowance - Double(acceptCount) // keep fractional remainder
        showThrottledHint = acceptCount < addedCount
    }
}

private struct InkMeter: View {
    let used: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("墨水")
                    .font(.subheadline).bold()
                Spacer()
                Text("\(max(0, total - used))/\(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("剩余墨水 \(max(0, total - used))，总量 \(total)")
            }
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.systemGray5))
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.70, green: 0.30, blue: 0.30), .black.opacity(0.9)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: meterWidth)
            }
            .frame(height: 8)
        }
    }

    private var meterWidth: CGFloat {
        let p = CGFloat(max(0, min(1, Double(used) / Double(total))))
        return p == 0 ? 0 : (UIScreen.main.bounds.width - 32) * p
    }
}

private struct RouteSelector: View {
    @Binding var selection: DelayPolicy.Route
    var body: some View {
        Picker("邮路", selection: $selection) {
            ForEach(DelayPolicy.Route.allCases) { route in
                Text(route.displayName).tag(route)
            }
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - Detail View

private struct DetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: Router
    let letterId: String
    @State private var now: Date = Date()

    private var letter: Letter? { model.letters.first(where: { $0.id == letterId }) }

    var body: some View {
        Group {
            if let letter {
                VStack(spacing: 16) {
                    switch letter.status(now: now) {
                    case .inTransit:
                        EnvelopeLockedView(title: "未到点",
                                           subtitle: "将在 \(timeRemaining(until: letter.unlockAt, from: now))后可开封。",
                                           showSaveHint: true)
                    case .ready:
                        EnvelopeReadyView(content: letter.content) {
                            // Gate by home status here
                            if model.homeStatus.isAtHome {
                                model.open(letter: letter)
                            }
                        }
                    case .opened:
                        ScrollView { PaperContentView(content: letter.content) }
                        Button {
                            let excerpt = letter.content.prefix(24)
                            router.composePrefill = "\n\n— 回信：\n> \(excerpt)\(letter.content.count > 24 ? "…" : "")\n\n"
                            router.selectedTabIndex = 1
                        } label: {
                            Label("回信", systemImage: "arrowshape.turn.up.left")
                                .font(.headline)
                        }
                        .buttonStyle(.bordered)
                    }
        }
        .padding()
            } else {
                Text("未找到这封信")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("信件")
        .onAppear {
            // Minute-level refresh for countdown
            now = Date()
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            now = Date()
        }
    }
}

private struct EnvelopeLockedView: View {
    let title: String
    let subtitle: String
    var showSaveHint: Bool = false
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title).font(.title2).bold()
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            if showSaveHint {
                Text("提示：保存到 App 可在到点时收到提醒。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct EnvelopeReadyView: View {
    let content: String
    var onOpen: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.open")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Button(action: onOpen) {
                Label("开封", systemImage: "sparkles")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            ScrollView { PaperContentView(content: content) }
        }
    }
}

private struct PaperContentView: View {
    let content: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.04), radius: 6, y: 3)
                .overlay(
                    Text(content)
                        .font(.system(size: 18))
                        .foregroundStyle(.primary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Settings View

private struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isAtHome: Bool = true
    @State private var notificationStatus: String = "未知"

    var body: some View {
        List {
            Section("到家开关") {
                Toggle(isOn: $isAtHome) {
                    Text("我已在家（到家后可开封）")
                }
                .onChange(of: isAtHome) { _, newValue in
                    model.setAtHome(newValue)
                }
                Text("说明：到家开关开启后，达时的信件即可开封。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("通知") {
                HStack {
                    Text("权限状态")
                    Spacer()
                    Text(notificationStatus).foregroundStyle(.secondary)
                }
                Button {
                    Task { await refreshNotificationStatus() }
                } label: { Label("检查权限", systemImage: "bell") }

                #if canImport(UIKit)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: { Label("打开系统设置", systemImage: "arrow.up.right.square") }
                #endif

                Text("仅“保存到 App”的信会安排到点提醒。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("关于") {
                Text("笺间以慢为序，每一封信都值得等待。")
            }
        }
        .navigationTitle("设置")
        .onAppear {
            isAtHome = model.homeStatus.isAtHome
            Task { await refreshNotificationStatus() }
        }
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: notificationStatus = "已授权"
            case .denied: notificationStatus = "已拒绝"
            case .notDetermined: notificationStatus = "未询问"
            @unknown default: notificationStatus = "未知"
            }
        }
    }
}

// MARK: - Shared helpers

private func timeRemaining(until: Date, from: Date) -> String {
    if until <= from { return "0 分钟" }
    let comps = Calendar.current.dateComponents([.day, .hour, .minute], from: from, to: until)
    let d = comps.day ?? 0
    let h = comps.hour ?? 0
    let m = comps.minute ?? 0
    if d > 0 { return "\(d)天\(h)小时" }
    if h > 0 { return "\(h)小时\(m)分钟" }
    return "\(max(1, m)) 分钟"
}

private struct ContentEmptyView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("暂无信件")
                .font(.headline)
            Text("去“写信”页写一封慢信吧。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

