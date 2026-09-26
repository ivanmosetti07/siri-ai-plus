import Contacts
import Foundation

// MARK: - Contatti (app Contatti dentro Siri AI+)

/// Voce con etichetta (telefono, email, sito): l'etichetta è quella di Contatti («_$!<Mobile>!$_») o una scritta a mano.
public struct LabeledField: Identifiable, Sendable, Equatable, Hashable {
    public var id = UUID()
    public var label: String
    public var value: String

    public init(label: String, value: String) { self.label = label; self.value = value }

    /// «cellulare», «casa», «lavoro»… nella lingua del Mac.
    public var localizedLabel: String {
        label.isEmpty ? "altro" : CNLabeledValue<NSString>.localizedString(forLabel: label)
    }
}

public struct PostalField: Identifiable, Sendable, Equatable, Hashable {
    public var id = UUID()
    public var label: String
    public var street = ""
    public var city = ""
    public var postalCode = ""
    public var state = ""
    public var country = ""

    public init(label: String, street: String = "", city: String = "", postalCode: String = "", state: String = "", country: String = "") {
        self.label = label; self.street = street; self.city = city; self.postalCode = postalCode; self.state = state; self.country = country
    }

    public var localizedLabel: String { label.isEmpty ? "altro" : CNLabeledValue<NSString>.localizedString(forLabel: label) }

    /// Su una riga, per le Mappe.
    public var oneLine: String {
        [street, [postalCode, city].filter { !$0.isEmpty }.joined(separator: " "), state, country]
            .map { $0.replacingOccurrences(of: "\n", with: ", ") }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    public var isEmpty: Bool { [street, city, postalCode, state, country].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
}

/// Riga dell'elenco.
public struct ContactSummary: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let organization: String
    public let detail: String
    public let sortKey: String
    public let isCompany: Bool
}

/// Tutto quello che si vede e si modifica di un contatto. Identificativo vuoto: contatto nuovo.
public struct ContactCard: Sendable, Equatable {
    public var id: String
    public var givenName: String
    public var familyName: String
    public var nickname: String
    public var organization: String
    public var jobTitle: String
    public var phones: [LabeledField]
    public var emails: [LabeledField]
    public var addresses: [PostalField]
    public var urls: [LabeledField]
    public var birthday: DateComponents?
    public var imageData: Data?

    public init(id: String = "", givenName: String = "", familyName: String = "", nickname: String = "", organization: String = "", jobTitle: String = "",
                phones: [LabeledField] = [], emails: [LabeledField] = [], addresses: [PostalField] = [], urls: [LabeledField] = [],
                birthday: DateComponents? = nil, imageData: Data? = nil) {
        self.id = id; self.givenName = givenName; self.familyName = familyName; self.nickname = nickname; self.organization = organization
        self.jobTitle = jobTitle; self.phones = phones; self.emails = emails; self.addresses = addresses; self.urls = urls
        self.birthday = birthday; self.imageData = imageData
    }

    public var isNew: Bool { id.isEmpty }

    public var displayName: String {
        let name = [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? (organization.isEmpty ? "Senza nome" : organization) : name
    }
}

public struct ContactGroup: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public let name: String
}

public enum ContactsStore {
    nonisolated(unsafe) static let store = CNContactStore()
    /// CNContactStore non è sicuro fra thread: un'operazione alla volta.
    private static let lock = NSLock()

    public static var authorized: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }

    static var listKeys: [CNKeyDescriptor] { [CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                                              CNContactTypeKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactNicknameKey] as [CNKeyDescriptor] }
    static var cardKeys: [CNKeyDescriptor] {
        listKeys + ([CNContactJobTitleKey, CNContactPostalAddressesKey, CNContactUrlAddressesKey, CNContactBirthdayKey,
                     CNContactImageDataAvailableKey, CNContactThumbnailImageDataKey] as [CNKeyDescriptor])
    }

    /// Tutti i contatti (o quelli di un gruppo), in ordine per cognome come in Contatti.
    public static func all(group: String? = nil) throws -> [ContactSummary] {
        let request = CNContactFetchRequest(keysToFetch: listKeys)
        request.sortOrder = .userDefault
        if let group { request.predicate = CNContact.predicateForContactsInGroup(withIdentifier: group) }
        var result: [ContactSummary] = []
        try lock.withLock {
            try store.enumerateContacts(with: request) { contact, _ in result.append(summary(contact)) }
        }
        // In ordine alfabetico per cognome; chi inizia con simboli o emoji («#») e i contatti senza nome in fondo, come in Contatti.
        func rank(_ key: String) -> Int { key.isEmpty ? 2 : key.first?.isLetter == true ? 0 : 1 }
        return result.sorted { a, b in
            let (ra, rb) = (rank(a.sortKey), rank(b.sortKey))
            if ra != rb { return ra < rb }
            return a.sortKey.localizedStandardCompare(b.sortKey) == .orderedAscending
        }
    }

    static func summary(_ contact: CNContact) -> ContactSummary {
        let person = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        let isCompany = contact.contactType == .organization || person.isEmpty
        let name = isCompany ? (contact.organizationName.isEmpty ? (contact.nickname.isEmpty ? "Senza nome" : contact.nickname) : contact.organizationName) : person
        let detail = contact.phoneNumbers.first?.value.stringValue ?? (contact.emailAddresses.first?.value as String?) ?? ""
        // Come in Contatti: per cognome, poi per nome (le aziende per nome).
        let key = name == "Senza nome" ? "" : isCompany ? name : [contact.familyName, contact.givenName].filter { !$0.isEmpty }.joined(separator: " ")
        return ContactSummary(id: contact.identifier, name: name, organization: isCompany ? "" : contact.organizationName,
                              detail: detail, sortKey: key.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Dates.locale),
                              isCompany: isCompany)
    }

    public static func groups() -> [ContactGroup] {
        lock.withLock { (try? store.groups(matching: nil)) ?? [] }
            .map { ContactGroup(id: $0.identifier, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func card(_ id: String) -> ContactCard? {
        guard let contact = lock.withLock({ try? store.unifiedContact(withIdentifier: id, keysToFetch: cardKeys) }) else { return nil }
        return ContactCard(id: contact.identifier, givenName: contact.givenName, familyName: contact.familyName, nickname: contact.nickname,
                           organization: contact.organizationName, jobTitle: contact.jobTitle,
                           phones: contact.phoneNumbers.map { LabeledField(label: $0.label ?? "", value: $0.value.stringValue) },
                           emails: contact.emailAddresses.map { LabeledField(label: $0.label ?? "", value: $0.value as String) },
                           addresses: contact.postalAddresses.map {
                               PostalField(label: $0.label ?? "", street: $0.value.street, city: $0.value.city, postalCode: $0.value.postalCode,
                                           state: $0.value.state, country: $0.value.country)
                           },
                           urls: contact.urlAddresses.map { LabeledField(label: $0.label ?? "", value: $0.value as String) },
                           birthday: contact.birthday, imageData: contact.imageDataAvailable ? contact.thumbnailImageData : nil)
    }

    /// Crea o salva il contatto; restituisce l'identificativo.
    @discardableResult
    public static func save(_ card: ContactCard) throws -> String {
        try lock.withLock {
            let contact: CNMutableContact
            let request = CNSaveRequest()
            if card.isNew {
                contact = CNMutableContact()
            } else {
                guard let existing = try? store.unifiedContact(withIdentifier: card.id, keysToFetch: cardKeys),
                      let mutable = existing.mutableCopy() as? CNMutableContact else {
                    throw storeError("Il contatto non esiste più.")
                }
                contact = mutable
            }
            contact.givenName = card.givenName.trimmingCharacters(in: .whitespaces)
            contact.familyName = card.familyName.trimmingCharacters(in: .whitespaces)
            contact.nickname = card.nickname.trimmingCharacters(in: .whitespaces)
            contact.organizationName = card.organization.trimmingCharacters(in: .whitespaces)
            contact.jobTitle = card.jobTitle.trimmingCharacters(in: .whitespaces)
            contact.phoneNumbers = card.phones.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { CNLabeledValue(label: $0.label.isEmpty ? CNLabelPhoneNumberMobile : $0.label, value: CNPhoneNumber(stringValue: $0.value)) }
            contact.emailAddresses = card.emails.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { CNLabeledValue(label: $0.label.isEmpty ? CNLabelHome : $0.label, value: $0.value.trimmingCharacters(in: .whitespaces) as NSString) }
            contact.urlAddresses = card.urls.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { CNLabeledValue(label: $0.label.isEmpty ? CNLabelURLAddressHomePage : $0.label, value: $0.value.trimmingCharacters(in: .whitespaces) as NSString) }
            contact.postalAddresses = card.addresses.filter { !$0.isEmpty }.map { field in
                let address = CNMutablePostalAddress()
                address.street = field.street
                address.city = field.city
                address.postalCode = field.postalCode
                address.state = field.state
                address.country = field.country
                return CNLabeledValue(label: field.label.isEmpty ? CNLabelHome : field.label, value: address as CNPostalAddress)
            }
            contact.birthday = card.birthday
            guard !contact.givenName.isEmpty || !contact.familyName.isEmpty || !contact.organizationName.isEmpty else {
                throw storeError("Scrivi almeno un nome o un'azienda.")
            }
            contact.contactType = contact.givenName.isEmpty && contact.familyName.isEmpty ? .organization : .person
            if card.isNew { request.add(contact, toContainerWithIdentifier: nil) } else { request.update(contact) }
            try store.execute(request)
            return contact.identifier
        }
    }

    public static func delete(_ id: String) throws {
        try lock.withLock {
            guard let existing = try? store.unifiedContact(withIdentifier: id, keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]),
                  let mutable = existing.mutableCopy() as? CNMutableContact else { throw storeError("Il contatto non esiste più.") }
            let request = CNSaveRequest()
            request.delete(mutable)
            try store.execute(request)
        }
    }

    // MARK: Gruppi

    @discardableResult
    public static func createGroup(_ name: String) throws -> String {
        try lock.withLock {
            let group = CNMutableGroup()
            group.name = name
            let request = CNSaveRequest()
            request.add(group, toContainerWithIdentifier: nil)
            try store.execute(request)
            return group.identifier
        }
    }

    public static func renameGroup(_ id: String, to name: String) throws {
        try lock.withLock {
            guard let group = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [id])).first,
                  let mutable = group.mutableCopy() as? CNMutableGroup else { throw storeError("Il gruppo non esiste più.") }
            mutable.name = name
            let request = CNSaveRequest()
            request.update(mutable)
            try store.execute(request)
        }
    }

    /// Elimina il gruppo (i contatti restano).
    public static func deleteGroup(_ id: String) throws {
        try lock.withLock {
            guard let group = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [id])).first,
                  let mutable = group.mutableCopy() as? CNMutableGroup else { throw storeError("Il gruppo non esiste più.") }
            let request = CNSaveRequest()
            request.delete(mutable)
            try store.execute(request)
        }
    }

    public static func setMember(_ contactID: String, of groupID: String, _ member: Bool) throws {
        try lock.withLock {
            guard let group = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [groupID])).first,
                  let contact = try? store.unifiedContact(withIdentifier: contactID, keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]) else {
                throw storeError("Contatto o gruppo non trovato.")
            }
            let request = CNSaveRequest()
            if member { request.addMember(contact, to: group) } else { request.removeMember(contact, from: group) }
            try store.execute(request)
        }
    }

    /// Gruppi di cui fa parte il contatto.
    public static func groups(of contactID: String) -> Set<String> {
        var result = Set<String>()
        for group in groups() {
            let predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.id)
            let members = lock.withLock { (try? store.unifiedContacts(matching: predicate, keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])) ?? [] }
            if members.contains(where: { $0.identifier == contactID }) { result.insert(group.id) }
        }
        return result
    }

    /// Etichette proposte per un nuovo telefono, email, indirizzo o sito.
    public static let phoneLabels = [CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone, CNLabelHome, CNLabelWork, CNLabelPhoneNumberMain, CNLabelOther]
    public static let emailLabels = [CNLabelHome, CNLabelWork, CNLabelEmailiCloud, CNLabelOther]
    public static let addressLabels = [CNLabelHome, CNLabelWork, CNLabelOther]
    public static let urlLabels = [CNLabelURLAddressHomePage, CNLabelHome, CNLabelWork, CNLabelOther]

    static func storeError(_ message: String) -> NSError {
        NSError(domain: AppInfo.name, code: 40, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
