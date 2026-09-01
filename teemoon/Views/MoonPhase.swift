//
//  MoonPhase.swift
//  teemoon
//
//  Today's moon phase as an SF Symbol name — the app's ambient imagery.
//

import Foundation

enum MoonPhase {
    /// SF Symbol name for today's moon phase.
    static var currentSymbolName: String {
        // Days since a known new moon (2000-01-06), folded into the ~29.53-day cycle.
        guard let baseDate = Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 6)),
              let daysSinceBaseDate = Calendar.current.dateComponents([.day], from: baseDate, to: Date()).day
        else { return "moonphase.new.moon" }

        let moonCycleLength = 29.53
        let daysIntoCycle = Double(daysSinceBaseDate).truncatingRemainder(dividingBy: moonCycleLength)

        switch daysIntoCycle {
        case 0..<1.8457:        return "moonphase.new.moon"
        case 1.8457..<5.536:    return "moonphase.waxing.crescent"
        case 5.536..<9.228:     return "moonphase.first.quarter"
        case 9.228..<12.919:    return "moonphase.waxing.gibbous"
        case 12.919..<16.610:   return "moonphase.full.moon"
        case 16.610..<20.302:   return "moonphase.waning.gibbous"
        case 20.302..<23.993:   return "moonphase.last.quarter"
        case 23.993..<27.684:   return "moonphase.waning.crescent"
        default:                return "moonphase.new.moon"
        }
    }
}
