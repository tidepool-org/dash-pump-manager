//
//  DashPumpManagerSetupViewController.swift
//  DashKitUI
//
//  Created by Pete Schwamb on 4/19/19.
//  Copyright © 2019 Tidepool. All rights reserved.
//

import Foundation
import LoopKit
import LoopKitUI
import PodSDK
import DashKit

public class DashPumpManagerSetupViewController: UINavigationController, PumpManagerSetupViewController, UINavigationControllerDelegate, CompletionNotifying {

    public var setupDelegate: PumpManagerSetupViewControllerDelegate?

    public var maxBasalRateUnitsPerHour: Double?

    public var maxBolusUnits: Double?

    public var basalSchedule: BasalRateSchedule?

    public var completionDelegate: CompletionDelegate?

    private(set) var pumpManager: DashPumpManager?

    class func instantiateFromStoryboard() -> DashPumpManagerSetupViewController {
        let storyboard = UIStoryboard(name: "DashPumpManager", bundle: Bundle(for: DashPumpManagerSetupViewController.self))
        if RegistrationManager.shared.isRegistered() {
            return storyboard.instantiateViewController(withIdentifier: "SetupWithoutRegistration") as! DashPumpManagerSetupViewController
        } else {
            return storyboard.instantiateViewController(withIdentifier: "SetupWithRegistration") as! DashPumpManagerSetupViewController
        }
    }

    open override func viewDidLoad() {
        super.viewDidLoad()
        
        delegate = self
    }


    /*
     1. Registration (if needed)

     2. Basal Rates & Delivery Limits

     3. Pod Pairing/Priming/Cannula Insertion

     4. Pod Setup Complete
     */

    public func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        // Set state values
        switch viewController {
        case let vc as ActivationFlowViewController:
            if let basalRateSchedule = basalSchedule {
                let pumpManagerState = DashPumpManagerState(timeZone: .currentFixed, basalSchedule: BasalSchedule(rateSchedule: basalRateSchedule))
                let pumpManager = DashPumpManager(state: pumpManagerState)
                vc.pumpManager = pumpManager
                self.pumpManager = pumpManager
                setupDelegate?.pumpManagerSetupViewController(self, didSetUpPumpManager: pumpManager)
            }
//        case let vc as InsertCannulaSetupViewController:
//            vc.pumpManager = pumpManager
        default:
            break
        }

    }

}

extension DashPumpManagerSetupViewController: SetupTableViewControllerDelegate {
    public func setupTableViewControllerCancelButtonPressed(_ viewController: SetupTableViewController) {
        completionDelegate?.completionNotifyingDidComplete(self)
    }
}
