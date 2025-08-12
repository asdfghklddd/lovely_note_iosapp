//
//  __App.swift
//  笺间
//
//  MVP skeleton with core models, storage and notification scheduler.
//

import SwiftUI
import UserNotifications

// MARK: - App Constants (Replace placeholders in your Xcode configuration)

enum AppConstants {
    // Replace with your real App Group identifier after enabling in both App and Extension targets
    static let appGroupId: String = "group.REPLACE_ME.jianjian"
    // Replace with your registered URL scheme if you add deep-links (e.g., jian://save?id=<id>)
    static let urlScheme: String = "jian"
    // Weekly ink capacity for MVP
    static let weeklyInkLimit: Int = 600
    // Typing rate limit (characters per second)
    static let typingCharsPerSecond: Double = 2.0
}

// MARK: - Time Provider

protocol TimeProvider {
    func now() -> Date
}

struct SystemTimeProvider: TimeProvider {
    func now() -> Date { Date() }
}

// MARK: - Data Model

struct Letter: Identifiable, Codable, Hashable {
    enum CodingKeys: String, CodingKey { case id, fromMe, content, createdAt, unlockAt, requiresHome, styleId, inkUsed, openedAt }

    var id: String
    var fromMe: Bool
    var content: String
    var createdAt: Date
    var unlockAt: Date
    var requiresHome: Bool
    var styleId: String?
    var inkUsed: Int
    var openedAt: Date?

    init(id: String = UUID().uuidString,
         fromMe: Bool,
         content: String,
         createdAt: Date,
         unlockAt: Date,
         requiresHome: Bool,
         styleId: String? = "paper-01",
         inkUsed: Int,
         openedAt: Date? = nil) {
        self.id = id
        self.fromMe = fromMe
        self.content = content
        self.createdAt = createdAt
        self.unlockAt = unlockAt
        self.requiresHome = requiresHome
        self.styleId = styleId
        self.inkUsed = inkUsed
        self.openedAt = openedAt
    }

    enum Status { case inTransit, ready, opened }

    // Status is derived only from time and open state.
    // Whether the letter can be opened is further gated by `requiresHome` and current home status.
    func status(now: Date) -> Status {
        if let _ = openedAt { return .opened }
        if now >= unlockAt { return .ready }
        return .inTransit
    }

    func canOpen(now: Date, isAtHome: Bool) -> Bool {
        status(now: now, isAtHome: isAtHome) == .ready
    }
}

// MARK: - Delay Policy

enum DelayPolicy {
    enum Route: String, CaseIterable, Codable, Identifiable { case local1d, province3d, nation7d
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .local1d: return "同城 1 天"
            case .province3d: return "同省 3 天"
            case .nation7d: return "跨省 7 天"
            }
        }
        var days: Int {
            switch self { case .local1d: return 1; case .province3d: return 3; case .nation7d: return 7 }
        }
    }

    static func unlockDate(from start: Date, route: Route, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: route.days, to: start) ?? start
    }
}

// MARK: - Home Status (UserDefaults with App Group)

final class HomeStatus {
    private let suite: UserDefaults
    private let key = "homeFlag"

    init(appGroupId: String) {
        if let ud = UserDefaults(suiteName: appGroupId) {
            self.suite = ud
        } else {
            self.suite = .standard
        }
        // Default on for MVP
        if self.suite.object(forKey: key) == nil { self.suite.set(true, forKey: key) }
    }

    var isAtHome: Bool {
        get { suite.bool(forKey: key) }
        set { suite.set(newValue, forKey: key) }
    }
}

// MARK: - Notification Scheduler

final class NotificationScheduler {
    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            if !granted {
                // Silent fallback; UI can show current permission in Settings
            }
        } catch {
            // Ignore for MVP; you can log error if needed
        }
    }

    func scheduleUnlockNotification(id: String, title: String, body: String, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let triggerDate = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerDate, repeats: false)
        let request = UNNotificationRequest(identifier: "unlock_\(id)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func cancelUnlockNotification(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["unlock_\(id)"])
    }
}

// MARK: - Letter Repository (App Group JSON Files)

final class LetterRepository {
    private let folderURL: URL

    init(appGroupId: String) {
        // Try App Group container first; fallback to Documents for MVP/dev
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            self.folderURL = container.appendingPathComponent("Letters", isDirectory: true)
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.folderURL = docs.appendingPathComponent("Letters", isDirectory: true)
        }
        createFolderIfNeeded()
    }

    private func createFolderIfNeeded() {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir) {
            try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }
    }

    private func fileURL(for id: String) -> URL {
        folderURL.appendingPathComponent("\(id).json", isDirectory: false)
    }

    func save(_ letter: Letter) throws {
        let data = try JSONEncoder().encode(letter)
        let target = fileURL(for: letter.id)
        let tmp = target.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: tmp, to: target)
        } catch {
            // Best-effort cleanup
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    func loadAll() -> [Letter] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else { return [] }
        var letters: [Letter] = []
        for url in items where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let letter = try? JSONDecoder().decode(Letter.self, from: data) {
                letters.append(letter)
            }
        }
        return letters.sorted(by: { $0.createdAt > $1.createdAt })
    }

    func markOpened(id: String, at date: Date) {
        var all = loadAll()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        var letter = all[index]
        letter.openedAt = date
        try? save(letter)
    }
}

// MARK: - App Model (Environment Object)

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var letters: [Letter] = []
    @Published var filter: Letter.Status? = nil

    let repository: LetterRepository
    let notifications: NotificationScheduler
    let homeStatus: HomeStatus
    let time: TimeProvider

    init(appGroupId: String = AppConstants.appGroupId,
         notifications: NotificationScheduler = NotificationScheduler(),
         time: TimeProvider = SystemTimeProvider()) {
        self.repository = LetterRepository(appGroupId: appGroupId)
        self.notifications = notifications
        self.homeStatus = HomeStatus(appGroupId: appGroupId)
        self.time = time
    }

    func refresh() {
        letters = repository.loadAll()
    }

    func addLetter(content: String, route: DelayPolicy.Route) {
        let now = time.now()
        let unlock = DelayPolicy.unlockDate(from: now, route: route)
        let letter = Letter(fromMe: true,
                            content: content,
                            createdAt: now,
                            unlockAt: unlock,
                            requiresHome: true,
                            styleId: "paper-01",
                            inkUsed: content.count,
                            openedAt: nil)
        try? repository.save(letter)
        refresh()
        // Schedule notification only for letters considered "saved to App"
        notifications.scheduleUnlockNotification(id: letter.id,
                                                 title: "信已抵达",
                                                 body: "这封信现在可以在家中开封。",
                                                 at: unlock)
    }

    func open(letter: Letter) {
        guard letter.canOpen(now: time.now(), isAtHome: homeStatus.isAtHome) else { return }
        repository.markOpened(id: letter.id, at: time.now())
        notifications.cancelUnlockNotification(id: letter.id)
        refresh()
    }

    func setAtHome(_ isAtHome: Bool) { homeStatus.isAtHome = isAtHome }

    func weeklyInkUsedByMeThisWeek(calendar: Calendar = .current) -> Int {
        let start = startOfCurrentWeek(calendar: calendar)
        return letters.filter { $0.fromMe && $0.createdAt >= start }.map { $0.inkUsed }.reduce(0, +)
    }

    private func startOfCurrentWeek(calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = 2 // Monday
        let now = time.now()
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        return cal.date(from: comps) ?? now
    }
}

// MARK: - Simple Router for programmatic navigation

@MainActor
final class Router: ObservableObject {
    // 0: 信箱, 1: 写信, 2: 设置
    @Published var selectedTabIndex: Int = 0
    // When set with a letterId, ListView will navigate to DetailView and then clear it
    @Published var pendingDetailLetterId: String? = nil
    // Navigation path for inbox stack
    @Published var inboxPath: [String] = []
    // Optional prefill for Compose
    @Published var composePrefill: String? = nil
}

// MARK: - App Entry

@main
struct __App: App {
    @StateObject private var model = AppModel()
    @StateObject private var router = Router()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(router)
                .task { await model.notifications.requestAuthorization() }
                .onAppear { model.refresh() }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    private func handleDeepLink(_ url: URL) {
        // Expect format: jian://save?id=<id>
        guard url.scheme?.lowercased() == AppConstants.urlScheme else { return }
        let host = url.host?.lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let id = components?.queryItems?.first(where: { $0.name == "id" })?.value
        if host == "save", let id {
            // Refresh repository (extension may have just written JSON)
            model.refresh()
            if let letter = model.letters.first(where: { $0.id == id }) {
                // Schedule notification if needed
                if letter.unlockAt > Date() {
                    model.notifications.scheduleUnlockNotification(id: letter.id,
                                                                    title: "信已抵达",
                                                                    body: "这封信将在到点时提醒开封。",
                                                                    at: letter.unlockAt)
                }
            }
            // Route to List tab and push detail
            router.selectedTabIndex = 0
            router.pendingDetailLetterId = id
        }
    }
}
