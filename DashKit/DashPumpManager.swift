//
//  DashPumpManager.swift
//  DashKit
//
//  Created by Pete Schwamb on 4/18/19.
//  Copyright © 2019 Tidepool. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import os.log
import PodSDK


public protocol PodStatusObserver: class {
    func didUpdatePodStatus()
}

public class DashPumpManager: PumpManager {

    public static var managerIdentifier = "OmnipodDash"

    var podCommManager: PodCommManagerProtocol

    public let log = OSLog(category: "DashPumpManager")

    public static let localizedTitle = LocalizedString("Omnipod DASH", comment: "Generic title of the omnipod DASH pump manager")

    public var lastReconciliation: Date? {
        // TODO
        return Date()
    }

    public func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
         return supportedBasalRates.filter({$0 <= unitsPerHour}).max() ?? 0
    }

    public func roundToSupportedBolusVolume(units: Double) -> Double {
        return supportedBolusVolumes.filter({$0 <= units}).max() ?? 0
    }

    public var supportedBolusVolumes: [Double] {
        // 0.05 units for rates between 0.05-30U/hr
        return (1...600).map { Double($0) / Double(Pod.pulsesPerUnit) }
    }

    public var supportedBasalRates: [Double] {
        // 0.05 units for rates between 0.05-30U/hr
        return (1...600).map { Double($0) / Double(Pod.pulsesPerUnit) }
    }

    public var maximumBasalScheduleEntryCount: Int {
        return Pod.maximumBasalScheduleEntryCount
    }

    public var minimumBasalScheduleEntryDuration: TimeInterval {
        return Pod.minimumBasalScheduleEntryDuration
    }

    private let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()

    public var pumpManagerDelegate: PumpManagerDelegate? {
        get {
            return pumpDelegate.delegate
        }
        set {
            pumpDelegate.delegate = newValue
        }
    }

    public var delegateQueue: DispatchQueue! {
        get {
            return pumpDelegate.queue
        }
        set {
            pumpDelegate.queue = newValue
        }
    }

    public let pumpRecordsBasalProfileStartEvents = false

    public var pumpReservoirCapacity: Double {
        return Pod.reservoirCapacity
    }

    public var hasActivePod: Bool {
        return state.podActivatedAt != nil
    }

    private func status(for state: DashPumpManagerState) -> PumpManagerStatus {
        return PumpManagerStatus(
            timeZone: state.timeZone,
            device: device(for: state),
            pumpBatteryChargeRemaining: nil,
            basalDeliveryState: basalDeliveryState(for: state),
            bolusState: bolusState(for: state)
        )
    }

    private func device(for state: DashPumpManagerState) -> HKDevice {
        return HKDevice(
            name: type(of: self).managerIdentifier,
            manufacturer: "Insulet",
            model: "DASH",
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: String(DashKitVersionNumber),
            localIdentifier: podCommManager.getPodId(),
            udiDeviceIdentifier: nil
        )
    }

    public var state: DashPumpManagerState {
        return lockedState.value
    }
    
    @discardableResult private func mutateState(_ changes: (_ state: inout DashPumpManagerState) -> Void) -> DashPumpManagerState {
        return setStateWithResult({ (state) -> DashPumpManagerState in
            changes(&state)
            return state
        })
    }
    
    private func setStateWithResult<ReturnType>(_ changes: (_ state: inout DashPumpManagerState) -> ReturnType) -> ReturnType {
        var oldValue: DashPumpManagerState!
        var returnValue: ReturnType!
        let newValue = lockedState.mutate { (state) in
            oldValue = state
            returnValue = changes(&state)
        }
        
        podStatusObservers.forEach { (observer) in
            observer.didUpdatePodStatus()
        }
        
        guard oldValue != newValue else {
            return returnValue
        }
        
        // PumpManagerStatus may have changed
        let oldStatus = status(for: oldValue)
        let newStatus = status(for: state)
        
        if oldStatus != newStatus {
            notifyStatusObservers(oldStatus: oldStatus)
        }
        
        pumpDelegate.notify { (delegate) in
            delegate?.pumpManagerDidUpdateState(self)
        }
        
        log.debug("state updated: %@", String(describing: state))

        return returnValue
    }

    
    private let lockedState: Locked<DashPumpManagerState>

    private func notifyStatusObservers(oldStatus: PumpManagerStatus) {
        let status = self.status

        pumpDelegate.notify { (delegate) in
            delegate?.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
        }
        statusObservers.forEach { (observer) in
            observer.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
        }
    }

    private var device: HKDevice {
        return HKDevice(
            name: type(of: self).managerIdentifier,
            manufacturer: "Insulet",
            model: "DASH",
            hardwareVersion: nil,
            firmwareVersion: "1.0",
            softwareVersion: String(DashKitVersionNumber),
            localIdentifier: podCommManager.getPodId(),
            udiDeviceIdentifier: nil
        )
    }

    public var status: PumpManagerStatus {
        return status(for: state)
    }

    private var statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()

    public func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {
        self.statusObservers.insert(observer, queue: queue)
    }

    public func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
        self.statusObservers.removeElement(observer)
    }

    private var podStatusObservers = WeakSynchronizedSet<PodStatusObserver>()

    public func addPodStatusObserver(_ observer: PodStatusObserver, queue: DispatchQueue) {
        self.podStatusObservers.insert(observer, queue: queue)
    }

    public func removePodStatusObserver(_ observer: PodStatusObserver) {
        self.podStatusObservers.removeElement(observer)
    }

    public var podActivatedAt: Date? {
        return state.podActivatedAt
    }

    public var podExpiresAt: Date? {
        return state.podActivatedAt?.addingTimeInterval(Pod.lifetime)
    }

    // From last status response
    public var reservoirLevel: ReservoirLevel? {
        return state.reservoirLevel
    }

    public var reservoirWarningLevel: Double {
        return 10 // TODO: Make configurable
    }

    public var isReservoirLow: Bool {
        return false  // TODO
    }

    public var isPodAlarming: Bool {
        return false // TODO
    }

    public var lastStatusDate: Date? {
        return state.lastStatusDate
    }

    public var podCommState: PodCommState {
        return podCommManager.podCommState
    }

    public var podId: String? {
        return podCommManager.getPodId()
    }

    public func getPodStatus(completion: @escaping (PodCommResult<PodStatus>) -> ()) {
        podCommManager.getPodStatus(userInitiated: false) { (response) in
            switch response {
            case .failure(let error):
                self.log.error("Fetching status failed: %{public}@", String(describing: error))
            case .success(let status):
                self.log.debug("getPodStatus result: %@", String(describing: status))
                self.mutateState({ (state) in
                    state.updateFromPodStatus(status: status)
                })
            }
            completion(response)
        }
    }

    public func startPodActivation(lowReservoirAlert: LowReservoirAlert?, podExpirationAlert: PodExpirationAlert?, eventListener: @escaping (ActivationStatus<ActivationStep1Event>) -> ())
    {

        print("Going to startPodActivation. Registration status = \(RegistrationManager.shared.isRegistered())")
        return podCommManager.startPodActivation(lowReservoirAlert: lowReservoirAlert, podExpirationAlert: podExpirationAlert) { (activationStatus) in
            print("ActivationStatus: \(activationStatus)")
            if case .event(let event) = activationStatus, case .podStatus(let status) = event {
                self.mutateState({ (state) in
                    state.updateFromPodStatus(status: status)
                })
            }
            eventListener(activationStatus)
        }
    }

    public func finishPodActivation(autoOffAlert: AutoOffAlert?, eventListener: @escaping (ActivationStatus<ActivationStep2Event>) -> ()) {
        // TODO: SDK needs to be updated to allow us to pass in TimeZone
        podCommManager.finishPodActivation(basalProgram: state.basalProgram, autoOffAlert: autoOffAlert) { (activationStatus) in
            if case .event(let event) = activationStatus, case .podStatus(let status) = event {
                self.mutateState({ (state) in
                    state.updateFromPodStatus(status: status)
                })
            }
            eventListener(activationStatus)
        }
    }

    public func discardPod(completion: @escaping (PodCommResult<Bool>) -> ()) {
        podCommManager.discardPod { (result) in
            self.mutateState({ (state) in
                state.podActivatedAt = nil
                state.lastStatusDate = nil
                state.reservoirLevel = nil
            })
            completion(result)
        }
    }

    public func deactivatePod(completion: @escaping (PodCommResult<PodStatus>) -> ()) {
        podCommManager.deactivatePod { (result) in
            completion(result)
        }
    }

    public func setBasalSchedule(dailyItems: [RepeatingScheduleValue<Double>], completion: @escaping (Error?) -> Void) {
        // TODO: SDK needs to be updated to allow us to pass in TimeZone
        guard let basalProgram = BasalProgram(items: dailyItems) else {
            completion(DashPumpManagerError.invalidBasalSchedule)
            return
        }
        
        suspendDelivery { (error) in
            if let error = error {
                completion(error)
                return
            }
            self.podCommManager.sendProgram(programType: .basalProgram(basal: basalProgram), beepOption: .none) { (result) in
                switch result {
                case .failure(let error):
                    completion(DashPumpManagerError(error))
                case .success(let podStatus):
                    let now = Date()
                    self.mutateState({ (state) in
                        state.updateFromPodStatus(status: podStatus)
                        state.unfinalizedResume = UnfinalizedDose(resumeStartTime: now, scheduledCertainty: .certain)
                        state.suspendState = .resumed(now)
                    })
                    completion(nil)
                }
            }
        }
    }

    private var isPumpDataStale: Bool {
        let pumpStatusAgeTolerance = TimeInterval(minutes: 6)
        let pumpDataAge = -(state.lastStatusDate ?? .distantPast).timeIntervalSinceNow
        return pumpDataAge > pumpStatusAgeTolerance
    }

    private func finalizeAndStoreDoses() {
        var dosesToStore: [UnfinalizedDose] = []

        lockedState.mutate { (state) in
            if let bolus = state.unfinalizedBolus, bolus.isFinished {
                state.finalizedDoses.append(bolus)
                state.unfinalizedBolus = nil
            }

            if let tempBasal = state.unfinalizedTempBasal, tempBasal.isFinished {
                state.finalizedDoses.append(tempBasal)
                state.unfinalizedTempBasal = nil
            }

            dosesToStore = state.finalizedDoses
            if let unfinalizedBolus = state.unfinalizedBolus {
                dosesToStore.append(unfinalizedBolus)
            }
            if let unfinalizedTempBasal = state.unfinalizedTempBasal {
                dosesToStore.append(unfinalizedTempBasal)
            }
            if let unfinalizedSuspend = state.unfinalizedSuspend {
                dosesToStore.append(unfinalizedSuspend)
            }
            if let unfinalizedResume = state.unfinalizedResume {
                dosesToStore.append(unfinalizedResume)
            }
        }

        let lastPumpReconciliation = lastReconciliation

        pumpDelegate.notify { (delegate) in
            delegate?.pumpManager(self, hasNewPumpEvents: dosesToStore.map { NewPumpEvent($0) }, lastReconciliation: lastPumpReconciliation, completion: { (error) in
                if let error = error {
                    self.log.error("Error storing pod events: %@", String(describing: error))
                } else {
                    self.lockedState.mutate { (state) in
                        state.finalizedDoses.removeAll { dosesToStore.contains($0) }
                    }
                    self.log.error("Stored pod events: %@", String(describing: dosesToStore))
                }
            })
        }
    }

    

    public func assertCurrentPumpData() {

        finalizeAndStoreDoses()

        guard hasActivePod else {
            return
        }

        guard !isPumpDataStale else {
            log.default("Fetching status because pumpData is too old")
            getPodStatus { (response) in
                switch response {
                case .success:
                    self.log.default("Recommending Loop")
                    self.finalizeAndStoreDoses()
                    self.pumpDelegate.notify({ (delegate) in
                        delegate?.pumpManagerRecommendsLoop(self)
                    })
                case .failure(let error):
                    self.log.default("Not recommending Loop because pump data is stale: %@", String(describing: error))
                    self.pumpDelegate.notify({ (delegate) in
                        delegate?.pumpManager(self, didError: PumpManagerError.communication(error))
                    })
                }
            }
            return
        }

        pumpDelegate.notify { (delegate) in
            self.log.default("Recommending Loop")
            delegate?.pumpManagerRecommendsLoop(self)
        }
    }

    private func basalDeliveryState(for state: DashPumpManagerState) -> PumpManagerStatus.BasalDeliveryState {
        if podCommManager.podCommState == .noPod {
            return .suspended(state.lastStatusDate ?? .distantPast)
        }
        
        if let transition = state.activeTransition {
            switch transition {
            case .suspendingPump:
                return .suspending
            case .resumingPump:
                return .resuming
            case .cancelingTempBasal:
                return .cancelingTempBasal
            case .startingTempBasal:
                return .initiatingTempBasal
            default:
                break
            }
        }
        
        if let tempBasal = state.unfinalizedTempBasal, !tempBasal.isFinished {
            return .tempBasal(DoseEntry(tempBasal))
        }
        
        switch state.suspendState {
        case .resumed(let date):
            return .active(date)
        case .suspended(let date):
            return .suspended(date)
        }
    }

    private func bolusState(for state: DashPumpManagerState) -> PumpManagerStatus.BolusState {
        if podCommManager.podCommState == .noPod {
            return .none
        }

        if let transition = state.activeTransition {
            switch transition {
            case .startingBolus:
                return .initiating
            case .cancelingBolus:
                return .canceling
            default:
                break
            }
        }
        if let bolus = state.unfinalizedBolus, !bolus.isFinished {
            return .inProgress(DoseEntry(bolus))
        }
        return .none
    }

    public func createBolusProgressReporter(reportingOn dispatchQueue: DispatchQueue) -> DoseProgressReporter? {
        if case .inProgress(let dose) = bolusState(for: self.state) {
            return PodDoseProgressEstimator(dose: dose, pumpManager: self, reportingQueue: dispatchQueue)
        }
        return nil
    }

    public func enactBolus(units: Double, at startDate: Date, willRequest: @escaping (DoseEntry) -> Void, completion: @escaping (PumpManagerResult<DoseEntry>) -> Void) {
        do {
            let preflightError = self.setStateWithResult({ (state) -> Error? in
                if state.activeTransition != nil {
                    return SetBolusError.certain(DashPumpManagerError.busy)
                }
                if let bolus = state.unfinalizedBolus, !bolus.isFinished {
                    return SetBolusError.certain(DashPumpManagerError.busy)
                }
                
                state.activeTransition = .startingBolus
                return nil
            })
            
            guard preflightError == nil else {
                completion(.failure(preflightError!))
                return
            }
            
            // Round to nearest supported volume
            let enactUnits = roundToSupportedBolusVolume(units: units)
            let program = ProgramType.bolus(bolus: try Bolus(immediateVolume: Int(round(enactUnits * 100))))

            let endDate = startDate.addingTimeInterval(enactUnits / Pod.bolusDeliveryRate)
            let dose = DoseEntry(type: .bolus, startDate: startDate, endDate: endDate, value: enactUnits, unit: .units)

            willRequest(dose)

            podCommManager.sendProgram(programType: program, beepOption: nil) { (result) in
                switch(result) {
                case .success(let podStatus):
                    self.mutateState({ (state) in
                        state.unfinalizedBolus = UnfinalizedDose(bolusAmount: enactUnits, startTime: startDate, scheduledCertainty: .certain)
                        state.updateFromPodStatus(status: podStatus)
                        state.activeTransition = nil
                    })
                    self.finalizeAndStoreDoses()
                    completion(.success(dose))
                case .failure(let error):
                    self.mutateState({ (state) in
                        state.activeTransition = nil
                    })
                    self.finalizeAndStoreDoses()
                    completion(.failure(DashPumpManagerError(error)))
                }
            }
        } catch let error {
            completion(.failure(error))
        }
    }

    public func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        
        let preflightError = self.setStateWithResult({ (state) -> DashPumpManagerError? in
            if state.activeTransition != nil {
                return DashPumpManagerError.busy
            }
            
            state.activeTransition = .cancelingBolus
            return nil
        })
        
        guard preflightError == nil else {
            completion(.failure(preflightError!))
            return
        }

        podCommManager.stopProgram(programType: .bolus) { (result) in
            switch result {
            case .success(let status):
                self.mutateState({ (state) in
                    state.unfinalizedBolus?.cancel(at: Date())
                    state.updateFromPodStatus(status: status)
                    state.activeTransition = nil
                })
                self.finalizeAndStoreDoses()
                completion(.success(self.state.unfinalizedBolus?.doseEntry()))
            case .failure(let error):
                self.mutateState({ (state) in
                    state.activeTransition = nil
                })
                completion(.failure(DashPumpManagerError(error)))
            }
        }
    }

    public func cancelTempBasal(completion: @escaping (DashPumpManagerError?) -> Void) {

        let preflightError = self.setStateWithResult({ (state) -> DashPumpManagerError? in
            if state.activeTransition != nil {
                return DashPumpManagerError.busy
            }
            
            state.activeTransition = .cancelingTempBasal
            return nil
        })
        
        guard preflightError == nil else {
            completion(preflightError!)
            return
        }

        podCommManager.stopProgram(programType: .tempBasal) { (result) in
            switch result {
            case .success(let status):
                self.mutateState({ (state) in
                    if var canceledTempBasal = state.unfinalizedTempBasal {
                        canceledTempBasal.cancel(at: Date())
                        state.unfinalizedTempBasal = nil
                        state.finalizedDoses.append(canceledTempBasal)
                    }
                    state.updateFromPodStatus(status: status)
                    state.activeTransition = nil
                })
                completion(nil)
            case .failure(let error):
                self.mutateState({ (state) in
                    state.activeTransition = nil
                })
                completion(DashPumpManagerError(error))
            }
        }
    }

    public func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval, completion: @escaping (PumpManagerResult<DoseEntry>) -> Void) {
        
        // Round to nearest supported volume
        let enactRate = roundToSupportedBasalRate(unitsPerHour: unitsPerHour)
        let program: ProgramType?
        
        do {
            if duration < .ulpOfOne {
                program = nil
            } else {
                let tempBasal = try TempBasal(value: .flatRate(Int(round(enactRate * 100))), duration: duration)
                program = ProgramType.tempBasal(tempBasal: tempBasal)
            }
        } catch let error {
            completion(.failure(error))
            return
        }
        
        cancelTempBasal { (error) in
            if let error = error {
                completion(.failure(error))
            } else {
                
                guard let program = program else {
                    // 0 duration temp basals are used to cancel any existing temp basal
                    let date = Date()
                    self.finalizeAndStoreDoses()
                    completion(.success(DoseEntry(type: .tempBasal, startDate: date, endDate: date, value: 0, unit: .unitsPerHour)))
                    return
                }
                
                let preflightError = self.setStateWithResult({ (state) -> DashPumpManagerError? in
                    if state.activeTransition != nil {
                        return DashPumpManagerError.busy
                    }
                    
                    state.activeTransition = .startingTempBasal
                    return nil
                })
                
                guard preflightError == nil else {
                    completion(.failure(preflightError!))
                    return
                }
                
                let startDate = Date()
                
                let dose = DoseEntry(type: .tempBasal, startDate: startDate, endDate: startDate.addingTimeInterval(duration), value: enactRate, unit: .unitsPerHour)
                
                self.podCommManager.sendProgram(programType: program, beepOption: .init(beepAtEnd: false)) { (result) in
                    switch(result) {
                    case .success(let podStatus):
                        self.mutateState({ (state) in
                            state.unfinalizedTempBasal = UnfinalizedDose(tempBasalRate: enactRate, startTime: startDate, duration: duration, scheduledCertainty: .certain)
                            state.updateFromPodStatus(status: podStatus)
                            state.activeTransition = nil
                        })
                        self.finalizeAndStoreDoses()
                        completion(.success(dose))
                    case .failure(let error):
                        self.mutateState({ (state) in
                            state.activeTransition = nil
                        })
                        self.finalizeAndStoreDoses()
                        completion(.failure(DashPumpManagerError(error)))
                    }
                }
            }
        }
    }

    public func setMustProvideBLEHeartbeat(_ mustProvideBLEHeartbeat: Bool) {
        // Seems to be causing a deadlock in the SDK
//        if mustProvideBLEHeartbeat {
//            podCommManager.configPeriodicStatusCheck(interval: .minutes(1)) { (result) in
//                switch result {
//                case .failure(let error):
//                    self.log.error("podCommManager periodic status check error: %{public}@", String(describing: error))
//                case .success(let status):
//                    self.log.debug("podCommManager periodic status: %@", String(describing: status))
//                    self.pumpDelegate.notify({ (delegate) in
//                        delegate?.pumpManagerBLEHeartbeatDidFire(self)
//                    })
//                }
//            }
//        }
    }

    public func suspendDelivery(completion: @escaping (Error?) -> Void) {
        
        let preflightError = self.setStateWithResult({ (state) -> Error? in
            if state.activeTransition != nil {
                return SetBolusError.certain(DashPumpManagerError.busy)
            }
            state.activeTransition = .suspendingPump
            return nil
        })
        
        guard preflightError == nil else {
            completion(preflightError!)
            return
        }

        let reminder = try! StopProgramReminder(value: StopProgramReminder.maxSuspendDuration)
        podCommManager.stopProgram(programType: .stopAll(reminder: reminder)) { (result) in
            switch result {
            case .failure(let error):
                self.mutateState({ (state) in
                    state.activeTransition = nil
                })
                completion(DashPumpManagerError(error))
            case .success(let podStatus):

                self.mutateState({ (state) in
                    let now = Date()
                    if let unfinalizedTempBasal = state.unfinalizedTempBasal,
                        let finishTime = unfinalizedTempBasal.finishTime,
                        finishTime > now
                    {
                        state.unfinalizedTempBasal?.cancel(at: now)
                    }
                    
                    if let unfinalizedBolus = state.unfinalizedBolus,
                        let finishTime = unfinalizedBolus.finishTime,
                        finishTime > now
                    {
                        state.unfinalizedBolus?.cancel(at: now, withRemaining: podStatus.bolusUnitsRemaining)
                        self.log.info("Interrupted bolus: %@", String(describing: state.unfinalizedBolus))
                    }
                    
                    state.unfinalizedSuspend = UnfinalizedDose(suspendStartTime: now, scheduledCertainty: .certain)
                    state.suspendState = .suspended(now)
                    state.updateFromPodStatus(status: podStatus)
                    state.activeTransition = nil
                })

                self.finalizeAndStoreDoses()
                completion(nil)
            }
        }
    }

    public func resumeDelivery(completion: @escaping (Error?) -> Void) {
        let preflightError = self.setStateWithResult({ (state) -> Error? in
            if state.activeTransition != nil {
                return SetBolusError.certain(DashPumpManagerError.busy)
            }
            state.activeTransition = .resumingPump
            return nil
        })
        
        guard preflightError == nil else {
            completion(preflightError!)
            return
        }

        podCommManager.sendProgram(programType: .basalProgram(basal: state.basalProgram), beepOption: .none) { (result) in
            switch result {
            case .failure(let error):
                self.mutateState({ (state) in
                    state.activeTransition = nil
                })
                completion(error)
            case .success(let podStatus):
                self.mutateState({ (state) in
                    let now = Date()
                    state.unfinalizedResume = UnfinalizedDose(resumeStartTime: now, scheduledCertainty: .certain)
                    state.suspendState = .resumed(now)
                    state.updateFromPodStatus(status: podStatus)
                    state.activeTransition = nil
                })
                self.finalizeAndStoreDoses()
                completion(nil)
            }
        }
    }

    public init(state: DashPumpManagerState, podCommManager: PodCommManagerProtocol = PodCommManager.shared) {
        self.lockedState = Locked(state)
        self.podCommManager = podCommManager
        self.podCommManager.delegate = self

        podCommManager.setLogger(logger: self)

        podCommManager.enableAutoConnection(launchOptions: [:])
    }

    public convenience required init?(rawState: PumpManager.RawStateValue) {
        guard let state = DashPumpManagerState(rawValue: rawState) else
        {
            return nil
        }

        self.init(state: state)
    }

    public var rawState: PumpManager.RawStateValue {
        return state.rawValue
    }

    public var debugDescription: String {
        let lines = [
            "## DashPumpManager",
            state.debugDescription,
            "",
        ]

        return lines.joined(separator: "\n")
    }
}

// Capture dash logs
extension DashPumpManager: LoggingProtocol {
    public func info(_ message: String) {
        log.default("PodSDK Info: %{public}@", message)
    }

    public func debug(_ message: String) {
        log.default("PodSDK Debug: %{public}@", message)
    }

    public func error(_ message: String) {
        log.default("PodSDK Error: %{public}@", message)
    }
}

extension DashPumpManager: PodCommManagerDelegate {
    public func onAlert(alerts: PodAlerts) {
        log.default("Pod Alert: %{public}@", String(describing: alerts))
    }
    
    public func onAlarm(alarm: PodAlarm) {
        log.default("Pod Alarm: %{public}@", String(describing: alarm))
    }
    
    public func onStatusUpdate(status: PodStatus) {
        log.default("Pod Status Update: %{public}@", String(describing: status))
    }
    
    public func onSystemError(error: SystemErrorCode) {
        log.default("Pod System Error: %{public}@", String(describing: error))
    }
    
    public func onPodCommStateChanged(podCommState: PodCommState) {
        log.default("Pod Comm State Changed: %{public}@", String(describing: podCommState))
    }
    
    public func onConnectionStateChanged(connectionState: ConnectionState) {
        self.mutateState { (state) in
            state.connectionState = connectionState
        }
        log.default("Pod Connection State Changed: %{public}@", String(describing: connectionState))
    }
}
