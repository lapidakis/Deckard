import Foundation

public struct MailboxRef: Codable, Sendable, Hashable {
    public let account: String
    public let name: String
    public let unreadCount: Int?
    public init(account: String, name: String, unreadCount: Int? = nil) {
        self.account = account
        self.name = name
        self.unreadCount = unreadCount
    }
}

public struct MessageSummary: Codable, Sendable, Hashable {
    public let id: String          // Mail.app message id (numeric, scoped to account+mailbox)
    public let account: String
    public let mailbox: String
    public let subject: String
    public let sender: String
    public let dateSent: String?   // ISO 8601
    public let isRead: Bool
    public init(id: String, account: String, mailbox: String, subject: String, sender: String, dateSent: String?, isRead: Bool) {
        self.id = id
        self.account = account
        self.mailbox = mailbox
        self.subject = subject
        self.sender = sender
        self.dateSent = dateSent
        self.isRead = isRead
    }
}

public struct Message: Codable, Sendable {
    public let id: String
    public let account: String
    public let mailbox: String
    public let subject: String
    public let sender: String
    public let recipients: [String]
    public let dateSent: String?
    public let body: String
    public init(
        id: String, account: String, mailbox: String,
        subject: String, sender: String, recipients: [String],
        dateSent: String?, body: String
    ) {
        self.id = id
        self.account = account
        self.mailbox = mailbox
        self.subject = subject
        self.sender = sender
        self.recipients = recipients
        self.dateSent = dateSent
        self.body = body
    }
}
