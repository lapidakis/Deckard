import Testing
import Foundation
import TOMLKit
@testable import BridgeConfig
@testable import BridgePolicy

// Pins the per-token interactive_approval policy: parsing, defaults, and how
// PolicyPipeline surfaces it for dispatch to consult. The gate-bypass behavior
// itself lives in MCPHostBuilder.dispatch — covered by code review since the
// dispatch entry point is private. These tests guard the contract dispatch
// reads from.

@Test func profileConfigDefaultsInteractiveApprovalToAlways() {
    // Plain default-constructed ProfileConfig keeps the original gate-prompt
    // behavior — no silent relaxation.
    let p = ProfileConfig()
    #expect(p.interactiveApproval == .always)
}

@Test func profileConfigParsesInteractiveApprovalFromTOML() throws {
    let toml = """
        default = "deny"
        interactive_approval = "never"

        [tools]
        "mail.send" = "approve"
        """
    let decoded = try TOMLDecoder().decode(ProfileConfig.self, from: toml)
    #expect(decoded.interactiveApproval == .never)
    #expect(decoded.tools["mail.send"] == .approve)
    #expect(decoded.default == .deny)
}

@Test func profileConfigOmittedFieldFallsBackToAlways() throws {
    // Existing configs without the new field must keep .always — the whole
    // point of the default is to never quietly weaken a deployed token.
    let toml = """
        default = "deny"
        [tools]
        "mail.send" = "approve"
        """
    let decoded = try TOMLDecoder().decode(ProfileConfig.self, from: toml)
    #expect(decoded.interactiveApproval == .always)
}

@Test func policyPipelineSurfacesNeverFromProfile() async {
    let audit = AuditSink(url: URL(fileURLWithPath: "/dev/null"))
    let profile = ProfileConfig(
        default: .deny,
        tools: ["mail.send": .approve],
        interactiveApproval: .never
    )
    let pipeline = PolicyPipeline(acl: ACLConfig(), profile: profile, audit: audit)
    #expect(pipeline.interactiveApprovalMode == .never)
}

@Test func policyPipelineDefaultsToAlwaysWhenNoProfile() async {
    // Global ACL path (no profile) keeps the on-host gate active. Tokens that
    // want auto-approve must opt in via a named profile.
    let audit = AuditSink(url: URL(fileURLWithPath: "/dev/null"))
    let pipeline = PolicyPipeline(acl: ACLConfig(), profile: nil, audit: audit)
    #expect(pipeline.interactiveApprovalMode == .always)
}
