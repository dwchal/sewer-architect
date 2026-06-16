//
//  Economy.swift
//  Sewer Architect
//
//  Budget: cash, the sewer rate the city charges residents, loans/bonds with
//  interest, and a running ledger of where the money went.
//

import Foundation

enum SpendReason {
    case construction
    case maintenance
    case fine          // regulatory penalty for overflows / pollution
    case interest
}

struct Finance {
    /// Starting funds for a modest town.
    private(set) var cash: Int = 5_000

    /// Monthly sewer fee charged per population unit served. Raising it brings
    /// money but angers citizens; lowering it is popular but starves the budget.
    var sewerRate: Double = 1.0
    static let minRate: Double = 0.0
    static let maxRate: Double = 5.0

    /// Outstanding loan principal and the per-tick interest rate on it.
    private(set) var debt: Int = 0
    static let interestPerTick: Double = 0.002 // ~ slow compounding

    // Running totals for the report card.
    private(set) var lifetimeRevenue: Int = 0
    private(set) var lifetimeConstruction: Int = 0
    private(set) var lifetimeMaintenance: Int = 0
    private(set) var lifetimeFines: Int = 0
    private(set) var lifetimeInterest: Int = 0

    // Most recent tick's cash flow, for the HUD.
    var lastRevenue: Int = 0
    var lastExpenses: Int = 0

    func canAfford(_ amount: Int) -> Bool { cash >= amount }

    mutating func spend(_ amount: Int, reason: SpendReason) {
        cash -= amount
        switch reason {
        case .construction: lifetimeConstruction += amount
        case .maintenance:  lifetimeMaintenance += amount
        case .fine:         lifetimeFines += amount
        case .interest:     lifetimeInterest += amount
        }
    }

    mutating func earn(_ amount: Int) {
        cash += amount
        lifetimeRevenue += amount
    }

    mutating func takeLoan(_ amount: Int) {
        cash += amount
        debt += amount
    }

    /// Pay down debt with available cash (up to `amount`).
    mutating func repayLoan(_ amount: Int) {
        let pay = min(amount, max(0, cash), debt)
        cash -= pay
        debt -= pay
    }

    /// Accrue one tick of interest on outstanding debt.
    mutating func accrueInterest() -> Int {
        guard debt > 0 else { return 0 }
        let interest = Int((Double(debt) * Finance.interestPerTick).rounded(.up))
        debt += interest
        lifetimeInterest += interest
        return interest
    }

    var isBankrupt: Bool { cash < -2_000 }

    /// 0...100 financial-health score: rewards cash reserves, punishes debt.
    var healthScore: Double {
        let cashScore = min(1.0, max(0.0, Double(cash) / 10_000.0))
        let debtPenalty = min(1.0, Double(debt) / 15_000.0)
        return max(0, min(100, (cashScore * 0.7 + (1 - debtPenalty) * 0.3) * 100))
    }
}
