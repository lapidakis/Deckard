import Foundation

/// One labeled value off a contact (phone, email, address, etc.).
/// Mirrors `CNLabeledValue<T>` but flattened to a Sendable JSON-friendly shape.
public struct LabeledString: Codable, Sendable, Hashable {
    public let label: String?
    public let value: String

    public init(label: String?, value: String) {
        self.label = label
        self.value = value
    }
}

public struct PostalAddress: Codable, Sendable, Hashable {
    public let label: String?
    public let street: String
    public let city: String
    public let state: String
    public let postalCode: String
    public let country: String
    public let isoCountryCode: String

    public init(
        label: String?, street: String, city: String, state: String,
        postalCode: String, country: String, isoCountryCode: String
    ) {
        self.label = label
        self.street = street
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.country = country
        self.isoCountryCode = isoCountryCode
    }

    enum CodingKeys: String, CodingKey {
        case label, street, city, state, country
        case postalCode = "postal_code"
        case isoCountryCode = "iso_country_code"
    }
}

/// Lightweight summary returned by `contacts.search` and `contacts.list_in_group`.
/// Holds just enough to disambiguate; agents call `contacts.get` for full detail.
public struct ContactSummary: Codable, Sendable, Hashable {
    public let id: String              // CNContact.identifier (stable across syncs)
    public let displayName: String     // CNContactFormatter.string(for:style: .fullName) fallback to organization
    public let organization: String?
    public let primaryEmail: String?
    public let primaryPhone: String?
    public let isOrganization: Bool

    public init(
        id: String, displayName: String, organization: String?,
        primaryEmail: String?, primaryPhone: String?, isOrganization: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.organization = organization
        self.primaryEmail = primaryEmail
        self.primaryPhone = primaryPhone
        self.isOrganization = isOrganization
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case organization
        case primaryEmail = "primary_email"
        case primaryPhone = "primary_phone"
        case isOrganization = "is_organization"
    }
}

/// Full contact record. Empty-array / nil fields are preserved so consumers can
/// distinguish "no value" from "field absent". Photos / image data are NOT
/// included — they're large, rarely useful to LLMs, and would need separate
/// base64 plumbing if ever requested.
public struct ContactDetail: Codable, Sendable {
    public let id: String
    public let displayName: String
    public let givenName: String?
    public let familyName: String?
    public let middleName: String?
    public let nickname: String?
    public let prefix: String?
    public let suffix: String?
    public let organization: String?
    public let jobTitle: String?
    public let department: String?
    public let isOrganization: Bool
    public let phones: [LabeledString]
    public let emails: [LabeledString]
    public let urls: [LabeledString]
    public let addresses: [PostalAddress]
    public let socialProfiles: [LabeledString]   // value = "service: username"
    public let instantMessages: [LabeledString]  // value = "service: handle"
    public let birthday: String?                 // ISO yyyy-MM-dd or yyyy-MM-dd-less if year omitted
    public let dates: [LabeledString]            // anniversaries etc.; value = ISO date string
    public let note: String?
    public let groupIds: [String]                // CNGroup.identifier list

    public init(
        id: String, displayName: String,
        givenName: String?, familyName: String?, middleName: String?,
        nickname: String?, prefix: String?, suffix: String?,
        organization: String?, jobTitle: String?, department: String?,
        isOrganization: Bool,
        phones: [LabeledString], emails: [LabeledString], urls: [LabeledString],
        addresses: [PostalAddress],
        socialProfiles: [LabeledString], instantMessages: [LabeledString],
        birthday: String?, dates: [LabeledString], note: String?,
        groupIds: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.givenName = givenName
        self.familyName = familyName
        self.middleName = middleName
        self.nickname = nickname
        self.prefix = prefix
        self.suffix = suffix
        self.organization = organization
        self.jobTitle = jobTitle
        self.department = department
        self.isOrganization = isOrganization
        self.phones = phones
        self.emails = emails
        self.urls = urls
        self.addresses = addresses
        self.socialProfiles = socialProfiles
        self.instantMessages = instantMessages
        self.birthday = birthday
        self.dates = dates
        self.note = note
        self.groupIds = groupIds
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case givenName = "given_name"
        case familyName = "family_name"
        case middleName = "middle_name"
        case nickname, prefix, suffix
        case organization
        case jobTitle = "job_title"
        case department
        case isOrganization = "is_organization"
        case phones, emails, urls, addresses
        case socialProfiles = "social_profiles"
        case instantMessages = "instant_messages"
        case birthday, dates, note
        case groupIds = "group_ids"
    }
}

public struct ContactGroupRef: Codable, Sendable, Hashable {
    public let id: String              // CNGroup.identifier
    public let name: String
    public let memberCount: Int

    public init(id: String, name: String, memberCount: Int) {
        self.id = id
        self.name = name
        self.memberCount = memberCount
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case memberCount = "member_count"
    }
}
