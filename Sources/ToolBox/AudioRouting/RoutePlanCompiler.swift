import Foundation

enum RoutePlanCompiler {
    static func compile(
        rules: [AppAudioRule],
        processes: [AudioProcessSnapshot],
        devices: [AudioOutputDevice],
        defaultOutputUID: String?,
        deviceConfigurationGeneration: Int = 0,
        policy: AudioRouteCompilationPolicy = .default
    ) -> AudioRouteCompilation {
        let availableDeviceUIDs = Set(devices.filter(\.isAvailable).map(\.uid))
        let devicesByUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })
        let rulesByBundleID = Dictionary(rules.map { ($0.bundleID, $0) }, uniquingKeysWith: { _, latest in latest })
        var sourcesByDeviceUID: [String: [AudioRouteSource]] = [:]
        var resolutions: [AudioRuleResolution] = []

        for rule in rulesByBundleID.values.sorted(by: { $0.bundleID < $1.bundleID }) {
            let matchingProcesses = processes.filter { $0.bundleID == rule.bundleID }
            guard !matchingProcesses.isEmpty else {
                resolutions.append(
                    AudioRuleResolution(bundleID: rule.bundleID, state: .waiting(.processNotRunning))
                )
                continue
            }

            if let excludedProcess = matchingProcesses
                .filter({
                    policy.excludedBundleIDs.contains($0.bundleID)
                        || policy.excludedProcessObjectIDs.contains($0.objectID)
                })
                .min(by: { $0.objectID < $1.objectID }) {
                resolutions.append(
                    AudioRuleResolution(
                        bundleID: rule.bundleID,
                        state: .rejected(.excludedProcess(objectID: excludedProcess.objectID))
                    )
                )
                continue
            }

            if let selectedUID = rule.outputDeviceUID, !availableDeviceUIDs.contains(selectedUID) {
                resolutions.append(
                    AudioRuleResolution(
                        bundleID: rule.bundleID,
                        state: .degraded(.outputDeviceUnavailable(uid: selectedUID))
                    )
                )
                continue
            }
            let selectedUID = rule.outputDeviceUID
            let requiresGain = rule.volumePercent != 100
            let requiresDeviceOverride = selectedUID != nil && selectedUID != defaultOutputUID
            guard requiresGain || requiresDeviceOverride else {
                resolutions.append(
                    AudioRuleResolution(bundleID: rule.bundleID, state: .planned(routeID: nil))
                )
                continue
            }
            guard let targetUID = selectedUID ?? defaultOutputUID else {
                resolutions.append(
                    AudioRuleResolution(
                        bundleID: rule.bundleID,
                        state: .rejected(.missingDefaultOutputDevice)
                    )
                )
                continue
            }

            if !availableDeviceUIDs.contains(targetUID) {
                resolutions.append(
                    AudioRuleResolution(
                        bundleID: rule.bundleID,
                        state: .rejected(.outputDeviceUnavailable(uid: targetUID))
                    )
                )
                continue
            }

            if let reason = policy.unsupportedOutputDeviceReasons[targetUID] {
                resolutions.append(
                    AudioRuleResolution(
                        bundleID: rule.bundleID,
                        state: .rejected(.unsupportedOutputDevice(uid: targetUID, reason: reason))
                    )
                )
                continue
            }
            if let issue = devicesByUID[targetUID]?.compatibilityIssue {
                resolutions.append(
                    AudioRuleResolution(
                        bundleID: rule.bundleID,
                        state: .rejected(
                            .unsupportedOutputDevice(uid: targetUID, reason: issue.message)
                        )
                    )
                )
                continue
            }

            for process in matchingProcesses {
                sourcesByDeviceUID[targetUID, default: []].append(
                    AudioRouteSource(
                        bundleID: process.bundleID,
                        processObjectID: process.objectID,
                        linearGain: Float(rule.volumePercent) / 100
                    )
                )
            }
            resolutions.append(
                AudioRuleResolution(bundleID: rule.bundleID, state: .planned(routeID: targetUID))
            )
        }

        let overCapacityRoutes = sourcesByDeviceUID.filter {
            $0.value.count > policy.maximumSourcesPerRoute
        }
        for (deviceUID, sources) in overCapacityRoutes {
            let affectedBundleIDs = Set(sources.map(\.bundleID))
            sourcesByDeviceUID.removeValue(forKey: deviceUID)
            resolutions = resolutions.map { resolution in
                guard affectedBundleIDs.contains(resolution.bundleID),
                      resolution.state == .planned(routeID: deviceUID) else {
                    return resolution
                }
                return AudioRuleResolution(
                    bundleID: resolution.bundleID,
                    state: .rejected(
                        .sourceCapacityExceeded(
                            limit: policy.maximumSourcesPerRoute,
                            requested: sources.count
                        )
                    )
                )
            }
        }

        return AudioRouteCompilation(
            plans: sourcesByDeviceUID.keys.sorted().map { deviceUID in
                AudioRoutePlan(
                    outputDeviceUID: deviceUID,
                    deviceConfigurationGeneration: deviceConfigurationGeneration,
                    sources: sourcesByDeviceUID[deviceUID, default: []].sorted {
                        ($0.bundleID, $0.processObjectID) < ($1.bundleID, $1.processObjectID)
                    }
                )
            },
            resolutions: resolutions.sorted { $0.bundleID < $1.bundleID }
        )
    }
}
