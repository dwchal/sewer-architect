//
//  GameEvents.swift
//  Sewer Architect
//
//  The "flush log" / news ticker. Random citizen actions and infrastructure
//  failures generate log entries with a deliberately comedic, local-news tone.
//

import Foundation

enum EventSeverity {
    case info
    case warning
    case crisis
}

struct GameEvent {
    let tick: Int
    let severity: EventSeverity
    let headline: String
}

/// Rolling log of events, newest last. The UI shows the tail as a ticker.
final class EventLog {
    private(set) var entries: [GameEvent] = []
    private let maxEntries = 200

    func post(_ headline: String, severity: EventSeverity, tick: Int) {
        entries.append(GameEvent(tick: tick, severity: severity, headline: headline))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    var latest: GameEvent? { entries.last }

    func recent(_ n: Int) -> [GameEvent] {
        Array(entries.suffix(n))
    }
}

/// Flavor text pools. Picking is deterministic via the simulation RNG.
enum EventFlavor {
    static let blockage = [
        "Crews find a wall of grease the size of a small car under Main St.",
        "\"Flushable\" wipes once again prove they are, in fact, not.",
        "Tree roots stage hostile takeover of a clay pipe on Elm Ave.",
        "Mystery item recovered from sewer; nobody is claiming it.",
        "Diaper conglomerate blocks the line. The city is not amused."
    ]
    static let burst = [
        "Aging pipe gives up the ghost; geyser delights/horrifies onlookers.",
        "Pipe burst floods an intersection. Commuters file strongly worded emails.",
        "Decades of deferred maintenance present their invoice. It's a pipe."
    ]
    static let cso = [
        "Combined sewer overflow paints the river an unfortunate shade.",
        "Storm overwhelms combined system; manhole geysers go viral.",
        "Environmental agency 'taking a very close look' at today's discharge."
    ]
    static let pumpFailure = [
        "Lift station trips offline; flow has opinions about going uphill.",
        "Pump fails with no backup installed. Physics wins again."
    ]
    static let complaint = [
        "Resident reports 'a smell that has developed a personality.'",
        "Neighborhood association demands the plant 'do something about that.'",
        "Letter to the editor: 'Have you SMELLED Sector 7 lately?'"
    ]
    static let backup = [
        "Sewage backs up into basements; residents are, predictably, upset.",
        "Low-lying homes report the wrong kind of indoor water feature."
    ]
    static let pathogen = [
        "Sewer lab flags a norovirus spike days before the clinics do.",
        "Wastewater surveillance catches a flu wave early; county is thrilled.",
        "Lab detects rising pathogen markers; health dept. acts ahead of the curve.",
        "Your sewage data scoops the hospitals on the next outbreak.",
        "Pathogen monitoring pays off: an outbreak spotted in the poop, not the ER."
    ]

    static func pick(_ pool: [String], rng: inout SplitMix64) -> String {
        guard !pool.isEmpty else { return "" }
        return pool[Int(rng.next() % UInt64(pool.count))]
    }
}
