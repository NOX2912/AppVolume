import AppKit
import Darwin

/// Die App, der ein Audio-Prozess zugeordnet wird.
struct AppIdentity: Hashable {
    let key: String          // Bundle-ID, sonst ein Ersatzschlüssel
    let name: String
    let icon: NSImage

    static func == (lhs: AppIdentity, rhs: AppIdentity) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// Ordnet Helfer-Prozesse (z. B. „Google Chrome Helper“, „com.apple.WebKit.GPU“) ihrer Haupt-App zu.
enum AppResolver {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    /// Private, aber stabile libsystem-Funktion: liefert den „verantwortlichen“ Prozess
    /// (für XPC-Dienste wie WebKit z. B. Safari).
    private static let responsiblePID: ResponsibleFn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    static func resolve(pid: pid_t, bundleID: String?) -> AppIdentity {
        // 1. Verantwortlicher Prozess ist eine reguläre App
        if let fn = responsiblePID {
            let rpid = fn(pid)
            if rpid > 0, let app = NSRunningApplication(processIdentifier: rpid), app.activationPolicy == .regular {
                return identity(for: app)
            }
        }
        // 2. Äußerstes .app-Bundle im Pfad der ausführbaren Datei
        //    (…/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/…)
        if let path = executablePath(of: pid), let bundleURL = outermostAppBundle(in: path),
           let identity = identity(forBundleAt: bundleURL) {
            return identity
        }
        // 3. Elternprozesse hochlaufen
        var current = pid
        for _ in 0..<16 {
            guard let parent = parentPID(of: current), parent > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular {
                return identity(for: app)
            }
            current = parent
        }
        // 4. Prozess selbst
        if let app = NSRunningApplication(processIdentifier: pid) {
            return identity(for: app)
        }
        let name = executablePath(of: pid).map { ($0 as NSString).lastPathComponent } ?? bundleID ?? "PID \(pid)"
        let icon = NSWorkspace.shared.icon(for: .unixExecutable)
        return AppIdentity(key: bundleID ?? "exec:\(name)", name: name, icon: icon)
    }

    private static func identity(for app: NSRunningApplication) -> AppIdentity {
        if let url = app.bundleURL, let identity = identity(forBundleAt: url) {
            return identity
        }
        return AppIdentity(key: app.bundleIdentifier ?? "pid:\(app.processIdentifier)",
                           name: app.localizedName ?? String(localized: "Unknown"),
                           icon: app.icon ?? NSWorkspace.shared.icon(for: .application))
    }

    private static func identity(forBundleAt url: URL) -> AppIdentity? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
        return AppIdentity(key: id, name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
    }

    private static func outermostAppBundle(in path: String) -> URL? {
        guard let range = path.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(path[..<path.index(range.upperBound, offsetBy: -1)]), isDirectory: true)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
