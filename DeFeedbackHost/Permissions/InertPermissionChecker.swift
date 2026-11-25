//
//  InertPermissionChecker.swift
//  DeFeedbackHost
//
//  Used when running hosted under XCTest, so tests never raise a real system prompt
//  (contract edge case 7 in PermissionChecking.swift). Always `.unknown`, which never warns.
//
import Foundation

@MainActor
final class InertPermissionChecker: PermissionChecker {

    let permission: Permission

    init(_ permission: Permission) {
        self.permission = permission
    }

    func check() async -> PermissionState { .unknown }
    func request() async -> PermissionState { .unknown }
}
