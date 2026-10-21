import AppKit
import ServiceManagement

@MainActor
func runLoginItemTests() throws -> Int {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw NSError(domain: "LoginItemTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }
    var systemStatus = SMAppService.Status.notRegistered
    var registrations = 0
    var removals = 0
    var settingsOpened = 0
    var denyRegistration = false
    var failRemoval = false
    let loginItem = LoginItem(readStatus: { systemStatus }, register: {
        registrations += 1
        if denyRegistration {
            systemStatus = .requiresApproval
            throw CocoaError(.userCancelled)
        }
        systemStatus = .enabled
    }, unregister: {
        removals += 1
        if failRemoval { throw CocoaError(.fileWriteNoPermission) }
        systemStatus = .notRegistered
    }, openSettings: { settingsOpened += 1 })

    try check(!loginItem.isEnabled && registrations == 0, "Opening settings never silently enables login startup")
    loginItem.setEnabled(true)
    try check(loginItem.isEnabled && registrations == 1 && loginItem.error == nil,
        "Enabling startup reports actual system registration")
    loginItem.setEnabled(true)
    try check(registrations == 1, "An already enabled item is not re-registered")
    failRemoval = true
    loginItem.setEnabled(false)
    try check(loginItem.isEnabled && loginItem.error != nil,
        "A failed removal keeps the toggle on and reports the failure")
    failRemoval = false
    loginItem.setEnabled(false)
    try check(!loginItem.isEnabled && loginItem.error == nil && removals == 2,
        "Disabling startup unregisters it without stopping the app")
    denyRegistration = true
    loginItem.setEnabled(true)
    try check(loginItem.requiresApproval && !loginItem.isEnabled && loginItem.error == nil,
        "Pending system approval is never displayed as enabled")
    loginItem.showSystemSettings()
    try check(settingsOpened == 1, "The approval action opens the system login-items page")
    systemStatus = .enabled
    loginItem.refresh()
    try check(loginItem.isEnabled, "Approval completed in System Settings is reflected on return")
    systemStatus = .requiresApproval
    loginItem.refresh()
    try check(!loginItem.isEnabled && loginItem.requiresApproval,
        "Revoking startup in System Settings is not overridden by the app")
    loginItem.setEnabled(false)
    try check(systemStatus == .notRegistered, "A pending approval can be cancelled")
    let missing = LoginItem(readStatus: { .notFound }, register: { throw CocoaError(.fileNoSuchFile) })
    missing.setEnabled(true)
    try check(!missing.isEnabled && missing.error != nil, "Missing app registration produces a visible error")

    func launchEvent(id: AEEventID = kAEOpenApplication, property: OSType? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: id,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let property { event.setParam(NSAppleEventDescriptor(enumCode: property), forKeyword: keyAEPropData) }
        return event
    }
    try check(!LoginItem.isLoginLaunch(nil) && !LoginItem.isLoginLaunch(launchEvent()),
        "Manual launches open the normal editor")
    try check(LoginItem.isLoginLaunch(launchEvent(property: keyAELaunchedAsLogInItem)),
        "The native login Apple event selects background startup")
    try check(!LoginItem.isLoginLaunch(launchEvent(id: kAEReopenApplication, property: keyAELaunchedAsLogInItem)),
        "Reopening a running app is not mistaken for login startup")
    return checks
}
