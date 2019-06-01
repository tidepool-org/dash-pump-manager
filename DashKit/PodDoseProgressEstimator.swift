//
//  PodDoseProgressEstimator.swift
//  DashKit
//
//  Created by Pete Schwamb on 5/31/19.
//  Copyright © 2019 Tidepool. All rights reserved.
//

import Foundation
import LoopKit

class PodDoseProgressEstimator: DoseProgressTimerEstimator {

    let dose: DoseEntry

    weak var pumpManager: PumpManager?

    override var progress: DoseProgress {
        let elapsed = -dose.startDate.timeIntervalSinceNow
        let duration = dose.endDate.timeIntervalSince(dose.startDate)
        let percentComplete = min(elapsed / duration, 1)
        let delivered = pumpManager?.roundToSupportedBolusVolume(units: percentComplete * dose.units) ?? dose.units
        return DoseProgress(deliveredUnits: delivered, percentComplete: percentComplete)
    }

    init(dose: DoseEntry, pumpManager: PumpManager, reportingQueue: DispatchQueue) {
        self.dose = dose
        self.pumpManager = pumpManager
        super.init(reportingQueue: reportingQueue)
    }

    override func timerParameters() -> (delay: TimeInterval, repeating: TimeInterval) {
        let timeSinceStart = dose.startDate.timeIntervalSinceNow
        let timeBetweenPulses: TimeInterval
        switch dose.type {
        case .bolus:
            timeBetweenPulses = Pod.pulseSize / Pod.bolusDeliveryRate
        case .basal, .tempBasal:
            timeBetweenPulses = Pod.pulseSize / dose.unitsPerHour
        default:
            fatalError("Can only estimate progress on basal rates or boluses.")
        }
        let delayUntilNextPulse = timeBetweenPulses - timeSinceStart.remainder(dividingBy: timeBetweenPulses)

        return (delay: delayUntilNextPulse, repeating: timeBetweenPulses)
    }
}
import Foundation
