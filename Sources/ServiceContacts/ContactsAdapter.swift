import Foundation
import Contacts
import Logging
import BridgeCore

/// Contacts.app via the Contacts framework (`CNContactStore`).
///
/// TCC service is `kTCCServiceAddressBook`; first call surfaces the macOS
/// "Deckard would like to access your contacts" prompt. The
/// `com.apple.security.personal-information.addressbook` entitlement must
/// be on the codesigned binary.
///
/// CN reference types (`CNContact`, `CNGroup`, `CNMutableContact`) are NOT
/// Sendable — every framework call performs mapping inside the actor before
/// returning a Sendable summary/detail. Same shape as `RemindersAdapter`.
public actor ContactsAdapter {
    public enum AdapterError: Error, CustomStringConvertible {
        case accessDenied(String)
        case contactNotFound(String)
        case groupNotFound(String)
        case invalidArgument(String)
        case saveFailed(String)

        public var description: String {
            switch self {
            case .accessDenied(let m):     return "Contacts access denied: \(m)"
            case .contactNotFound(let id): return "Contact not found: \(id)"
            case .groupNotFound(let id):   return "Contact group not found: \(id)"
            case .invalidArgument(let m):  return "Invalid argument: \(m)"
            case .saveFailed(let m):       return "Save failed: \(m)"
            }
        }
    }

    private let store: CNContactStore
    private let logger: Logger
    private var accessGranted = false
    /// Same dedup pattern as RemindersAdapter — concurrent ensureAccess() calls
    /// otherwise stack independent `requestAccess` invocations on a wedged
    /// framework call (observed when TCC needs to revalidate a re-codesigned
    /// binary).
    private var accessTask: Task<Bool, Error>?

    private static let accessRequestTimeoutSec: UInt64 = 10

    public init(logger: Logger = Logger(label: "bridge.contacts")) {
        self.store = CNContactStore()
        self.logger = logger
    }

    private func ensureAccess() async throws {
        if accessGranted { return }
        let task: Task<Bool, Error>
        if let existing = accessTask {
            task = existing
        } else {
            task = makeAccessTask()
            accessTask = task
        }
        do {
            let granted = try await task.value
            accessTask = nil
            if !granted {
                throw AdapterError.accessDenied("user denied or system blocked Contacts access")
            }
            accessGranted = true
        } catch let err as AdapterError {
            accessTask = nil
            throw err
        } catch {
            accessTask = nil
            throw AdapterError.accessDenied("\(error)")
        }
    }

    private func makeAccessTask() -> Task<Bool, Error> {
        let timeoutNs = Self.accessRequestTimeoutSec * 1_000_000_000
        return Task<Bool, Error> { [weak self] in
            guard let self else { return false }
            return try await self.performAccessRequest(timeoutNs: timeoutNs)
        }
    }

    /// Same continuation+latch shape as RemindersAdapter.performAccessRequest.
    /// `requestAccess` is callback-based; we race it against a dispatch timer
    /// so a wedged framework call can't stall the whole bridge.
    private func performAccessRequest(timeoutNs: UInt64) async throws -> Bool {
        let store = self.store
        let logger = self.logger
        let latch = ResumeLatch()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            store.requestAccess(for: .contacts) { granted, error in
                guard latch.tryResume() else { return }
                if let error = error {
                    logger.error("Contacts requestAccess error: \(error)")
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: granted)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(timeoutNs))) {
                guard latch.tryResume() else { return }
                logger.error("Contacts access request timed out after \(timeoutNs / 1_000_000_000)s")
                cont.resume(throwing: AdapterError.accessDenied(
                    "Contacts access request timed out — open System Settings → Privacy & Security → Contacts, enable Deckard, then retry"
                ))
            }
        }
    }

    // MARK: - Read

    public struct SearchFilter: Sendable {
        public enum Kind: String, Sendable { case any, name, email, phone }
        public var query: String
        public var kind: Kind
        public var limit: Int

        public init(query: String, kind: Kind = .any, limit: Int = 50) {
            self.query = query
            self.kind = kind
            self.limit = limit
        }
    }

    public func search(_ filter: SearchFilter) async throws -> [ContactSummary] {
        try await ensureAccess()
        let q = filter.query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { throw AdapterError.invalidArgument("query is required") }

        // Stack predicates by kind. `.any` runs all three and unions by id.
        // CNContactStore doesn't have a cross-field full-text predicate, so
        // running each is the standard workaround.
        var contacts: [CNContact] = []
        var seen = Set<String>()
        let kinds: [SearchFilter.Kind] = filter.kind == .any ? [.name, .email, .phone] : [filter.kind]
        let keys = Self.summaryKeys()

        for kind in kinds {
            let predicate: NSPredicate
            switch kind {
            case .name:  predicate = CNContact.predicateForContacts(matchingName: q)
            case .email: predicate = CNContact.predicateForContacts(matchingEmailAddress: q)
            case .phone:
                let phone = CNPhoneNumber(stringValue: q)
                predicate = CNContact.predicateForContacts(matching: phone)
            case .any: continue
            }
            do {
                let matched = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
                for c in matched where !seen.contains(c.identifier) {
                    seen.insert(c.identifier)
                    contacts.append(c)
                    if contacts.count >= filter.limit { break }
                }
            } catch {
                logger.warning("Contacts search predicate failed (\(kind.rawValue)): \(error)")
            }
            if contacts.count >= filter.limit { break }
        }

        return contacts.prefix(filter.limit).map { Self.summarize($0) }
    }

    public func get(id: String) async throws -> ContactDetail {
        try await ensureAccess()
        let keys = Self.detailKeys()
        let contact: CNContact
        do {
            contact = try store.unifiedContact(withIdentifier: id, keysToFetch: keys)
        } catch {
            throw AdapterError.contactNotFound(id)
        }
        // Group membership is computed by iterating groups — CNContact has no
        // direct accessor and the private `_groupIDs` KVC isn't a stable
        // contract. O(groups), which is fine for personal address books.
        let groupKeys = [CNContactIdentifierKey as CNKeyDescriptor]
        var groupIds: [String] = []
        if let allGroups = try? store.groups(matching: nil) {
            for g in allGroups {
                let predicate = CNContact.predicateForContactsInGroup(withIdentifier: g.identifier)
                let members = (try? store.unifiedContacts(matching: predicate, keysToFetch: groupKeys)) ?? []
                if members.contains(where: { $0.identifier == id }) {
                    groupIds.append(g.identifier)
                }
            }
        }
        return Self.detail(contact, groupIds: groupIds)
    }

    public func listGroups() async throws -> [ContactGroupRef] {
        try await ensureAccess()
        let groups = try store.groups(matching: nil)
        let keys = [CNContactIdentifierKey as CNKeyDescriptor]
        return groups.map { g in
            let predicate = CNContact.predicateForContactsInGroup(withIdentifier: g.identifier)
            let count = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys).count) ?? 0
            return ContactGroupRef(id: g.identifier, name: g.name, memberCount: count)
        }
    }

    public func listInGroup(groupId: String, limit: Int) async throws -> [ContactSummary] {
        try await ensureAccess()
        // Confirm group exists for a clear error; predicate-only would silently
        // return [] for a bad id.
        let groups = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [groupId]))
        guard !groups.isEmpty else { throw AdapterError.groupNotFound(groupId) }
        let predicate = CNContact.predicateForContactsInGroup(withIdentifier: groupId)
        let matched = try store.unifiedContacts(matching: predicate, keysToFetch: Self.summaryKeys())
        return matched.prefix(limit).map { Self.summarize($0) }
    }

    // MARK: - Write

    public struct ContactInput: Sendable {
        public var givenName: String?
        public var familyName: String?
        public var organization: String?
        public var jobTitle: String?
        public var department: String?
        public var phones: [LabeledString]
        public var emails: [LabeledString]
        public var urls: [LabeledString]
        public var note: String?
        public var groupIds: [String]?

        public init(
            givenName: String? = nil, familyName: String? = nil,
            organization: String? = nil, jobTitle: String? = nil, department: String? = nil,
            phones: [LabeledString] = [], emails: [LabeledString] = [], urls: [LabeledString] = [],
            note: String? = nil, groupIds: [String]? = nil
        ) {
            self.givenName = givenName
            self.familyName = familyName
            self.organization = organization
            self.jobTitle = jobTitle
            self.department = department
            self.phones = phones
            self.emails = emails
            self.urls = urls
            self.note = note
            self.groupIds = groupIds
        }
    }

    public func create(_ input: ContactInput) async throws -> ContactDetail {
        try await ensureAccess()

        let hasName = !(input.givenName ?? "").isEmpty || !(input.familyName ?? "").isEmpty
        let hasOrg = !(input.organization ?? "").isEmpty
        guard hasName || hasOrg else {
            throw AdapterError.invalidArgument("at least one of given_name, family_name, or organization is required")
        }

        let mutable = CNMutableContact()
        Self.applyInput(input, to: mutable)

        let save = CNSaveRequest()
        save.add(mutable, toContainerWithIdentifier: nil)

        // Group adds happen in the same save transaction so contact + group
        // membership commit atomically (or fail together).
        if let groupIds = input.groupIds, !groupIds.isEmpty {
            let groups = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: groupIds))
            for g in groups { save.addMember(mutable, to: g) }
        }

        do {
            try store.execute(save)
        } catch {
            throw AdapterError.saveFailed("\(error)")
        }

        // Re-fetch unified copy so detail() sees server-side normalization
        // (label canonicalization, generated identifiers, etc.).
        let unified = try store.unifiedContact(withIdentifier: mutable.identifier, keysToFetch: Self.detailKeys())
        return Self.detail(unified)
    }

    public struct ContactUpdate: Sendable {
        public var id: String
        public var givenName: String??
        public var familyName: String??
        public var organization: String??
        public var jobTitle: String??
        public var department: String??
        public var phones: [LabeledString]?      // nil = leave; [] = clear
        public var emails: [LabeledString]?
        public var urls: [LabeledString]?
        public var note: String??

        public init(
            id: String,
            givenName: String?? = nil, familyName: String?? = nil,
            organization: String?? = nil, jobTitle: String?? = nil, department: String?? = nil,
            phones: [LabeledString]? = nil, emails: [LabeledString]? = nil, urls: [LabeledString]? = nil,
            note: String?? = nil
        ) {
            self.id = id
            self.givenName = givenName
            self.familyName = familyName
            self.organization = organization
            self.jobTitle = jobTitle
            self.department = department
            self.phones = phones
            self.emails = emails
            self.urls = urls
            self.note = note
        }
    }

    public func update(_ change: ContactUpdate) async throws -> ContactDetail {
        try await ensureAccess()

        // unifiedContact returns the merged view across linked records; for
        // mutation we need a per-record fetch so the CNSaveRequest knows
        // which container the contact belongs to. Fetching on the record's
        // own identifier yields a `mutableCopy()` we can edit.
        let keys = Self.detailKeys()
        let original: CNContact
        do {
            original = try store.unifiedContact(withIdentifier: change.id, keysToFetch: keys)
        } catch {
            throw AdapterError.contactNotFound(change.id)
        }
        guard let mutable = original.mutableCopy() as? CNMutableContact else {
            throw AdapterError.saveFailed("could not produce mutable copy of contact \(change.id)")
        }

        if case .some(let v) = change.givenName     { mutable.givenName = v ?? "" }
        if case .some(let v) = change.familyName    { mutable.familyName = v ?? "" }
        if case .some(let v) = change.organization  { mutable.organizationName = v ?? "" }
        if case .some(let v) = change.jobTitle      { mutable.jobTitle = v ?? "" }
        if case .some(let v) = change.department    { mutable.departmentName = v ?? "" }
        if let phones = change.phones {
            mutable.phoneNumbers = phones.map(Self.makePhone)
        }
        if let emails = change.emails {
            mutable.emailAddresses = emails.map(Self.makeEmail)
        }
        if let urls = change.urls {
            mutable.urlAddresses = urls.map(Self.makeURL)
        }
        // Notes intentionally not written: setting `mutable.note` without
        // the Apple-granted `com.apple.developer.contacts.notes` entitlement
        // throws CNErrorCodeAuthorizationDenied on save. Field is accepted
        // by the schema for forward-compat but currently no-ops.
        _ = change.note

        let save = CNSaveRequest()
        save.update(mutable)
        do {
            try store.execute(save)
        } catch {
            throw AdapterError.saveFailed("\(error)")
        }

        let refreshed = try store.unifiedContact(withIdentifier: change.id, keysToFetch: keys)
        return Self.detail(refreshed)
    }

    public func delete(id: String) async throws {
        try await ensureAccess()
        let keys = [CNContactIdentifierKey as CNKeyDescriptor]
        let original: CNContact
        do {
            original = try store.unifiedContact(withIdentifier: id, keysToFetch: keys)
        } catch {
            throw AdapterError.contactNotFound(id)
        }
        guard let mutable = original.mutableCopy() as? CNMutableContact else {
            throw AdapterError.saveFailed("could not produce mutable copy of contact \(id)")
        }
        let save = CNSaveRequest()
        save.delete(mutable)
        do {
            try store.execute(save)
        } catch {
            throw AdapterError.saveFailed("\(error)")
        }
    }

    /// Replace a contact's group memberships with `targetGroupIds` exactly.
    /// Computes (add, remove) diff against current memberships in one save
    /// transaction. Pass `[]` to remove from all groups.
    public func setGroups(contactId: String, targetGroupIds: [String]) async throws -> [String] {
        try await ensureAccess()
        let contactKeys = [CNContactIdentifierKey as CNKeyDescriptor]
        let contact: CNContact
        do {
            contact = try store.unifiedContact(withIdentifier: contactId, keysToFetch: contactKeys)
        } catch {
            throw AdapterError.contactNotFound(contactId)
        }
        guard let mutable = contact.mutableCopy() as? CNMutableContact else {
            throw AdapterError.saveFailed("could not produce mutable copy of contact \(contactId)")
        }

        let allGroups = try store.groups(matching: nil)
        var currentIds = Set<String>()
        for g in allGroups {
            let predicate = CNContact.predicateForContactsInGroup(withIdentifier: g.identifier)
            let members = (try? store.unifiedContacts(matching: predicate, keysToFetch: contactKeys)) ?? []
            if members.contains(where: { $0.identifier == contactId }) {
                currentIds.insert(g.identifier)
            }
        }

        let targetSet = Set(targetGroupIds)
        let toAdd = targetSet.subtracting(currentIds)
        let toRemove = currentIds.subtracting(targetSet)

        // Validate every target id exists; otherwise the save would partially
        // succeed and the caller would have no way to tell which group failed.
        let unknown = toAdd.filter { id in !allGroups.contains { $0.identifier == id } }
        if let bad = unknown.first { throw AdapterError.groupNotFound(bad) }

        let save = CNSaveRequest()
        for g in allGroups where toAdd.contains(g.identifier) {
            save.addMember(mutable, to: g)
        }
        for g in allGroups where toRemove.contains(g.identifier) {
            save.removeMember(mutable, from: g)
        }
        do {
            try store.execute(save)
        } catch {
            throw AdapterError.saveFailed("\(error)")
        }
        return Array(targetSet).sorted()
    }

    // MARK: - Mapping helpers

    /// Keys sufficient to render a `ContactSummary`. Kept narrow because
    /// `unifiedContacts(matching:keysToFetch:)` cost scales with key count.
    private static func summaryKeys() -> [CNKeyDescriptor] {
        [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactTypeKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        ]
    }

    private static func detailKeys() -> [CNKeyDescriptor] {
        // CNContactNoteKey is intentionally absent. macOS 13+ requires the
        // Apple-granted `com.apple.developer.contacts.notes` entitlement to
        // fetch or write notes; including the key here without the
        // entitlement throws CNErrorCodeAuthorizationDenied on the fetch.
        // The `note` field on `ContactDetail` therefore round-trips as nil.
        [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactTypeKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactNamePrefixKey as CNKeyDescriptor,
            CNContactNameSuffixKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactDepartmentNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactSocialProfilesKey as CNKeyDescriptor,
            CNContactInstantMessageAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactDatesKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        ]
    }

    nonisolated static func summarize(_ c: CNContact) -> ContactSummary {
        ContactSummary(
            id: c.identifier,
            displayName: displayName(c),
            organization: nonEmpty(c.organizationName),
            primaryEmail: c.emailAddresses.first.map { String($0.value) },
            primaryPhone: c.phoneNumbers.first.map { $0.value.stringValue },
            isOrganization: c.contactType == .organization
        )
    }

    nonisolated static func detail(_ c: CNContact, groupIds: [String] = []) -> ContactDetail {
        ContactDetail(
            id: c.identifier,
            displayName: displayName(c),
            givenName: nonEmpty(c.givenName),
            familyName: nonEmpty(c.familyName),
            middleName: nonEmpty(c.middleName),
            nickname: nonEmpty(c.nickname),
            prefix: nonEmpty(c.namePrefix),
            suffix: nonEmpty(c.nameSuffix),
            organization: nonEmpty(c.organizationName),
            jobTitle: nonEmpty(c.jobTitle),
            department: nonEmpty(c.departmentName),
            isOrganization: c.contactType == .organization,
            phones: c.phoneNumbers.map { LabeledString(label: localizedLabel($0.label), value: $0.value.stringValue) },
            emails: c.emailAddresses.map { LabeledString(label: localizedLabel($0.label), value: String($0.value)) },
            urls: c.urlAddresses.map { LabeledString(label: localizedLabel($0.label), value: String($0.value)) },
            addresses: c.postalAddresses.map {
                let a = $0.value
                return PostalAddress(
                    label: localizedLabel($0.label),
                    street: a.street, city: a.city, state: a.state,
                    postalCode: a.postalCode, country: a.country, isoCountryCode: a.isoCountryCode
                )
            },
            socialProfiles: c.socialProfiles.map {
                let s = $0.value
                let combined = s.service.isEmpty ? s.username : "\(s.service): \(s.username)"
                return LabeledString(label: localizedLabel($0.label), value: combined)
            },
            instantMessages: c.instantMessageAddresses.map {
                let m = $0.value
                let combined = m.service.isEmpty ? m.username : "\(m.service): \(m.username)"
                return LabeledString(label: localizedLabel($0.label), value: combined)
            },
            birthday: c.birthday.flatMap(formatDateComponents),
            dates: c.dates.compactMap { entry in
                guard let formatted = formatDateComponents(entry.value as DateComponents) else { return nil }
                return LabeledString(label: localizedLabel(entry.label), value: formatted)
            },
            note: nonEmpty(c.note),
            groupIds: groupIds
        )
    }

    nonisolated static func displayName(_ c: CNContact) -> String {
        if let formatted = CNContactFormatter.string(from: c, style: .fullName), !formatted.isEmpty {
            return formatted
        }
        if !c.organizationName.isEmpty { return c.organizationName }
        if !c.nickname.isEmpty { return c.nickname }
        return c.identifier
    }

    nonisolated static func localizedLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        // CNLabeledValue stores Apple's `_$!<Home>!$_` style labels; humanize
        // them. Returns the raw string when localization yields nothing.
        let localized = CNLabeledValue<NSString>.localizedString(forLabel: raw)
        return localized.isEmpty ? raw : localized
    }

    nonisolated static func formatDateComponents(_ comps: DateComponents) -> String? {
        // year is optional on birthdays; emit `--MM-dd` (vCard style) when missing.
        guard let month = comps.month, let day = comps.day else { return nil }
        if let year = comps.year {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        return String(format: "--%02d-%02d", month, day)
    }

    nonisolated static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    // MARK: - Input → CN mapping

    nonisolated static func applyInput(_ input: ContactInput, to mutable: CNMutableContact) {
        if let g = input.givenName { mutable.givenName = g }
        if let f = input.familyName { mutable.familyName = f }
        if let o = input.organization {
            mutable.organizationName = o
            // Mark as organization-typed only when name fields are empty —
            // otherwise the contact stays a person with an organization.
            let hasName = !(input.givenName ?? "").isEmpty || !(input.familyName ?? "").isEmpty
            if !hasName { mutable.contactType = .organization }
        }
        if let j = input.jobTitle { mutable.jobTitle = j }
        if let d = input.department { mutable.departmentName = d }
        mutable.phoneNumbers = input.phones.map(makePhone)
        mutable.emailAddresses = input.emails.map(makeEmail)
        mutable.urlAddresses = input.urls.map(makeURL)
        // input.note ignored — see ContactUpdate notes-handling comment.
        _ = input.note
    }

    nonisolated static func makePhone(_ ls: LabeledString) -> CNLabeledValue<CNPhoneNumber> {
        CNLabeledValue(label: canonicalLabel(ls.label), value: CNPhoneNumber(stringValue: ls.value))
    }

    nonisolated static func makeEmail(_ ls: LabeledString) -> CNLabeledValue<NSString> {
        CNLabeledValue(label: canonicalLabel(ls.label), value: ls.value as NSString)
    }

    nonisolated static func makeURL(_ ls: LabeledString) -> CNLabeledValue<NSString> {
        CNLabeledValue(label: canonicalLabel(ls.label), value: ls.value as NSString)
    }

    /// Friendly label → CN constant. Anything unrecognized passes through;
    /// CN accepts arbitrary strings, the localized rendering just won't
    /// hit Apple's preset list.
    nonisolated static func canonicalLabel(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        switch s.lowercased() {
        case "home":    return CNLabelHome
        case "work":    return CNLabelWork
        case "other":   return CNLabelOther
        case "mobile",
             "cell":    return CNLabelPhoneNumberMobile
        case "iphone":  return CNLabelPhoneNumberiPhone
        case "main":    return CNLabelPhoneNumberMain
        case "fax",
             "home fax": return CNLabelPhoneNumberHomeFax
        case "work fax": return CNLabelPhoneNumberWorkFax
        case "school":  return CNLabelSchool
        default:        return s
        }
    }
}
