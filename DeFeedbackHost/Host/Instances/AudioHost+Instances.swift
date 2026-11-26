//
//  AudioHost+Instances.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//
//  AudioHost's instance members. Each forwards to `InstanceList`, which holds the state and the rules.

import Foundation

extension AudioHost {

    var instances: [PluginInstance] { instanceList.instances }

    var selectedInstanceIndex: Int {
        get { instanceList.selectedInstanceIndex }
        set { instanceList.selectedInstanceIndex = newValue }
    }

    var selectedInstance: PluginInstance? { instanceList.selectedInstance }
    var canShowPreviousInstance: Bool { instanceList.canShowPrevious }
    var canShowNextInstance: Bool { instanceList.canShowNext }
    var canAddInstance: Bool { instanceList.canAdd }

    @discardableResult
    func addInstance() async -> PluginInstance? { await instanceList.add() }

    func instance(id: UUID) -> PluginInstance? { instanceList.instance(id: id) }
    func instance(named name: String) -> PluginInstance? { instanceList.instance(named: name) }

    func validateName(_ proposed: String, for instance: PluginInstance) -> InstanceNameError? {
        instanceList.validateName(proposed, for: instance)
    }

    @discardableResult
    func rename(_ instance: PluginInstance, to proposed: String) -> InstanceNameError? {
        instanceList.rename(instance, to: proposed)
    }

    func removeSelectedInstance() { instanceList.removeSelected() }

    @discardableResult
    func removeInstance(id: UUID) -> Bool { instanceList.remove(id: id) }

    func showPreviousInstance() { instanceList.showPrevious() }
    func showNextInstance() { instanceList.showNext() }
}
