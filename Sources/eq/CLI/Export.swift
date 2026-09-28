import Foundation

struct ExportReport: Encodable {
    var device: DeviceRef
    var source: String
    var format: String
    var path: String?
    var content: String?
}

extension CLI {
    static let exportUsage = "eq export [--format apo|graphiceq|eqmac|camilla|json] [--device DEVICE] [--out FILE] [--force]"

    static func export(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let (explicit, rest) = try splitDeviceOption(args, flag: "--device", ctx)
        var format = ExportFormat.apo
        var out: String?
        var force = false
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--format":
                guard i + 1 < rest.count else { throw CLIError.usage("--format needs a value") }
                guard let parsed = ExportFormat(rawValue: rest[i + 1].lowercased()) else {
                    throw CLIError.usage("unknown format \"\(rest[i + 1])\" — use one of \(ExportFormat.allCases.map(\.rawValue).joined(separator: " "))")
                }
                format = parsed
                i += 2
            case "--out":
                guard i + 1 < rest.count, !rest[i + 1].isEmpty else { throw CLIError.usage("--out needs a file name") }
                out = rest[i + 1]
                i += 2
            case "--force":
                force = true
                i += 1
            default:
                throw CLIError.usage(exportUsage)
            }
        }
        if force && out == nil { throw CLIError.usage("--force applies to --out") }

        let config = try loadConfig(ctx)
        let target: Target
        if let explicit { target = explicit } else { target = try currentDevice(ctx) }
        let resolved = config.profile(forDeviceUID: target.uid)
        var profile = resolved.profile
        profile.name = target.name
        let text: String
        do { text = try Exporter.render(profile, as: format, header: .init(device: target.name, date: ctx.today())) }
        catch let error as ExportError { throw CLIError.exportRefused("\(error)") }

        let device = DeviceRef(uid: target.uid, name: target.name)
        let source = resolved.source == .device ? "device" : "default"
        guard let out else {
            return Output(text, ExportReport(device: device, source: source, format: format.rawValue, content: text))
        }
        let url = URL(fileURLWithPath: out)
        try writeExport(Data((text + "\n").utf8), to: url, force: force)
        let done = Paint.ink(.green, "wrote ") + Paint.ink(.bold, url.path) + Paint.ink(.dim, " (\(format.rawValue), \(target.name))")
        return Output(done, ExportReport(device: device, source: source, format: format.rawValue, path: url.path))
    }

    /// A reader of `url` sees the old file or the whole new one, never half of it: the text goes
    /// to a hidden file beside it and is renamed into place. Without --force the rename itself
    /// refuses an existing file, so a file created meanwhile is not overwritten either.
    static func writeExport(_ data: Data, to url: URL, force: Bool) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { throw CLIError.exportFailed("\(url.path) is a directory") }
            if !force { throw CLIError.exportRefused("\(url.path) exists — add --force to replace it") }
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do { try data.write(to: temporary, options: .withoutOverwriting) }
        catch { throw CLIError.exportFailed("cannot write \(url.path): \(error.localizedDescription)") }
        defer { try? fm.removeItem(at: temporary) }

        if renamex_np(temporary.path, url.path, force ? 0 : UInt32(RENAME_EXCL)) == 0 { return }
        var code = errno
        // exFAT and network volumes have no exclusive rename; a plain one after the check above
        // leaves only the gap between that check and this line.
        if !force, code == ENOTSUP || code == EINVAL {
            if fm.fileExists(atPath: url.path) { code = EEXIST }
            else if rename(temporary.path, url.path) == 0 { return }
            else { code = errno }
        }
        if code == EEXIST { throw CLIError.exportRefused("\(url.path) exists — add --force to replace it") }
        throw CLIError.exportFailed("cannot write \(url.path): \(String(cString: strerror(code)))")
    }
}
