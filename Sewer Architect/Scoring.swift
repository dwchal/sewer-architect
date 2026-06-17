//
//  Scoring.swift
//  Sewer Architect
//
//  Report-card metrics, the satisfaction/environment trackers, game modes, and
//  the scenario objectives + win/loss conditions.
//

import Foundation

/// A snapshot of how the department is doing, produced each quarter.
struct ReportCard {
    let quarter: Int
    let population: Int
    let serviceCoverage: Double   // 0...100, % of parcels adequately served
    let overflowIncidents: Int    // CSO + sewage-backup events this quarter
    let environmentScore: Double  // 0...100, inverse of river pollution
    let financialHealth: Double   // 0...100
    let satisfaction: Double      // 0...100
    let cash: Int
    let debt: Int

    /// Overall letter grade from the weighted average of the metrics.
    var grade: String {
        let avg = (serviceCoverage + environmentScore
                   + financialHealth + satisfaction) / 4.0
                  - Double(overflowIncidents) * 2.0
        switch avg {
        case 90...:   return "A"
        case 80..<90: return "B"
        case 70..<80: return "C"
        case 60..<70: return "D"
        default:      return "F"
        }
    }

    /// A local-news headline keyed off the worst-performing metric.
    var headline: String {
        if overflowIncidents > 6 {
            return "Quarterly Report: \"River Briefly Becomes a Crime Scene\""
        }
        if financialHealth < 30 {
            return "Quarterly Report: \"Sewer Dept. Maxes Out the City Card\""
        }
        if satisfaction < 35 {
            return "Quarterly Report: \"Citizens Revolt Over Eau de Sewer\""
        }
        if serviceCoverage < 50 {
            return "Quarterly Report: \"Half the Town Still Flushing Into the Void\""
        }
        if environmentScore < 40 {
            return "Quarterly Report: \"Fish Reportedly 'Concerned'\""
        }
        if grade == "A" {
            return "Quarterly Report: \"A Well-Oiled (and Well-Flushed) Machine\""
        }
        return "Quarterly Report: \"Things Are, Broadly Speaking, Fine\""
    }
}

enum GameMode: String, CaseIterable {
    case sandbox
    case scenario

    var displayName: String {
        switch self {
        case .sandbox:  return "Sandbox"
        case .scenario: return "Scenario"
        }
    }
}

enum GameOutcome {
    case ongoing
    case won(String)
    case lost(String)
}

/// A scenario objective with optional fail thresholds. The default scenario:
/// grow the town while keeping overflows and finances in check.
struct Scenario {
    var name: String = "Growing Pains"
    var targetPopulation: Int = 400
    var maxOverflowsPerQuarter: Int = 5
    var requirePositiveCash: Bool = true
    var deadlineQuarters: Int = 20

    func evaluate(population: Int,
                  quarter: Int,
                  lastCard: ReportCard?,
                  finance: Finance,
                  environmentScore: Double) -> GameOutcome {
        if finance.isBankrupt {
            return .lost("Bankruptcy. The mayor has accepted your resignation.")
        }
        if environmentScore < 8 {
            return .lost("Environmental disaster. The state has taken over the system.")
        }
        if population >= targetPopulation {
            if !requirePositiveCash || finance.cash >= 0 {
                return .won("Target population reached with the city still standing. Promotion!")
            }
        }
        if quarter >= deadlineQuarters {
            return .lost("The deadline passed without hitting the population target.")
        }
        return .ongoing
    }
}

/// Accumulates per-quarter metrics. Reset after each report card is issued.
struct ScoreTracker {
    var overflowIncidentsThisQuarter: Int = 0
    var lifetimeOverflows: Int = 0
    var cards: [ReportCard] = []

    /// River pollution, 0 (pristine) ... high (disaster). Decays slowly toward
    /// clean as the river flushes itself.
    var riverPollution: Double = 0

    var environmentScore: Double {
        max(0, min(100, 100 - riverPollution))
    }

    mutating func addPollution(_ amount: Double) {
        riverPollution = min(200, riverPollution + amount)
    }

    mutating func decayPollution() {
        riverPollution = max(0, riverPollution - 0.4)
    }

    mutating func recordOverflow(count: Int = 1) {
        overflowIncidentsThisQuarter += count
        lifetimeOverflows += count
    }

    mutating func issueCard(quarter: Int,
                            population: Int,
                            serviceCoverage: Double,
                            satisfaction: Double,
                            finance: Finance) -> ReportCard {
        let card = ReportCard(
            quarter: quarter,
            population: population,
            serviceCoverage: serviceCoverage,
            overflowIncidents: overflowIncidentsThisQuarter,
            environmentScore: environmentScore,
            financialHealth: finance.healthScore,
            satisfaction: satisfaction,
            cash: finance.cash,
            debt: finance.debt
        )
        cards.append(card)
        overflowIncidentsThisQuarter = 0
        return card
    }
}
