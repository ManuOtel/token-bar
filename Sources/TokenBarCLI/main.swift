import Foundation
import TokenBarCore

// MARK: - Options

struct CLIOptions {
    var preset: DatePreset = .lifetime
    var source: SourceFilter = .all
    var allPresets: Bool = false
    var json: Bool = false
}

enum CLIError: Error, CustomStringConvertible {
    case unknownFlag(String)
    case missingValue(String)
    case invalidPreset(String)
    case invalidSource(String)

    var description: String {
        switch self {
        case .unknownFlag(let flag): return "Unknown flag: \(flag)"
        case .missingValue(let flag): return "Missing value for \(flag)"
        case .invalidPreset(let value): return "Invalid --preset '\(value)'. Expected one of: today, 24h, 7d, 30d, best-month, lifetime."
        case .invalidSource(let value): return "Invalid --source '\(value)'. Expected one of: all, codex, opencode."
        }
    }
}

func parsePreset(_ raw: String) throws -> DatePreset {
    switch raw.lowercased() {
    case "today": return .today
    case "24h", "last24hours", "last-24h", "24-hours", "last24h": return .last24Hours
    case "7d", "last7days", "last-7d", "7-days": return .last7Days
    case "30d", "last30days", "last-30d", "30-days": return .last30Days
    case "best-month", "bestmonth", "best_month", "best": return .bestMonth
    case "lifetime", "all-time", "all": return .lifetime
    default: throw CLIError.invalidPreset(raw)
    }
}

func parseSource(_ raw: String) throws -> SourceFilter {
    switch raw.lowercased() {
    case "all": return .all
    case "codex": return .codex
    case "opencode": return .opencode
    default: throw CLIError.invalidSource(raw)
    }
}

func parseArguments(_ args: [String]) throws -> (options: CLIOptions, showHelp: Bool) {
    var options = CLIOptions()
    var showHelp = false
    var index = 0
    while index < args.count {
        let arg = args[index]
        if arg == "--help" || arg == "-h" {
            showHelp = true
            index += 1
        } else if arg == "--all-presets" {
            options.allPresets = true
            index += 1
        } else if arg == "--json" {
            options.json = true
            index += 1
        } else if arg == "--preset" {
            guard index + 1 < args.count else { throw CLIError.missingValue("--preset") }
            options.preset = try parsePreset(args[index + 1])
            index += 2
        } else if arg.hasPrefix("--preset=") {
            options.preset = try parsePreset(String(arg.dropFirst("--preset=".count)))
            index += 1
        } else if arg == "--source" {
            guard index + 1 < args.count else { throw CLIError.missingValue("--source") }
            options.source = try parseSource(args[index + 1])
            index += 2
        } else if arg.hasPrefix("--source=") {
            options.source = try parseSource(String(arg.dropFirst("--source=".count)))
            index += 1
        } else {
            throw CLIError.unknownFlag(arg)
        }
    }
    return (options, showHelp)
}

func usageText(executable: String = "token-bar") -> String {
    """
    Usage: \(executable) [--preset <name>] [--source <name>] [--all-presets] [--json]

      --preset <name>   today | 24h | 7d | 30d | best-month | lifetime (default: lifetime)
      --source <name>   all | codex | opencode (default: all)
      --all-presets     print every preset for the chosen source, in fixed order
      --json            emit machine-readable JSON instead of human-readable text
      --help, -h        show this help

    Examples:
      \(executable)
      \(executable) --preset today
      \(executable) --preset 7d --source codex
      \(executable) --all-presets --source all
      \(executable) --preset lifetime --json
    """
}

// MARK: - Main

let executableName = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "token-bar"
let rawArgs = Array(CommandLine.arguments.dropFirst())

let options: CLIOptions
do {
    let parsed = try parseArguments(rawArgs)
    if parsed.showHelp {
        print(usageText(executable: executableName))
        exit(0)
    }
    options = parsed.options
} catch let error as CLIError {
    fputs("Error: \(error.description)\n\(usageText(executable: executableName))\n", stderr)
    exit(2)
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(2)
}

let now = Date()
let report = TokenBarStore.load(now: now)
let calendar = Calendar.current

let presets: [DatePreset] = options.allPresets
    ? [.today, .last24Hours, .last7Days, .last30Days, .bestMonth, .lifetime]
    : [options.preset]

let sections = presets.map { preset in
    ReportFormatter.section(records: report.records, source: options.source, preset: preset, now: now, calendar: calendar)
}

if options.json {
    do {
        print(try ReportFormatter.encodeJSON(sections: sections, warnings: report.warnings))
    } catch {
        fputs("Error: failed to encode JSON report.\n", stderr)
        exit(1)
    }
} else if options.allPresets {
    print(ReportFormatter.renderAll(sections: sections, warnings: report.warnings))
} else {
    print(ReportFormatter.render(section: sections[0], warnings: report.warnings))
}
