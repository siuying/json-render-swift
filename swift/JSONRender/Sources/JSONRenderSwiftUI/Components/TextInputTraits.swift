import SwiftUI

extension View {
    /// Applies catalog `keyboard`, `contentType` and `autocapitalization` values.
    /// Keyboard and content-type hints only exist on iOS; elsewhere this is a no-op.
    func textInputTraits(keyboard: String?, contentType: String?, autocapitalization: String?) -> some View {
        modifier(TextInputTraitsModifier(keyboard: keyboard, contentType: contentType, autocapitalization: autocapitalization))
    }
}

private struct TextInputTraitsModifier: ViewModifier {
    let keyboard: String?
    let contentType: String?
    let autocapitalization: String?

    /// Content where autocorrection only gets in the way.
    private static let literalContentTypes: Set<String> = [
        "email", "username", "newPassword", "password", "oneTimeCode", "url",
    ]

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .keyboardType(keyboardType)
            .textContentType(textContentType)
            .textInputAutocapitalization(capitalization)
            .autocorrectionDisabled(disablesAutocorrection)
        #else
        content.autocorrectionDisabled(disablesAutocorrection)
        #endif
    }

    private var disablesAutocorrection: Bool {
        keyboard == "email" || keyboard == "url" || contentType.map(Self.literalContentTypes.contains) == true
    }

    #if os(iOS)
    private var keyboardType: UIKeyboardType {
        switch keyboard {
        case "email": .emailAddress
        case "number": .numberPad
        case "decimal": .decimalPad
        case "phone": .phonePad
        case "url": .URL
        default: .default
        }
    }

    private var textContentType: UITextContentType? {
        switch contentType {
        case "name": .name
        case "givenName": .givenName
        case "familyName": .familyName
        case "email": .emailAddress
        case "phone": .telephoneNumber
        case "username": .username
        case "newPassword": .newPassword
        case "password": .password
        case "oneTimeCode": .oneTimeCode
        case "streetAddress": .fullStreetAddress
        case "city": .addressCity
        case "postalCode": .postalCode
        case "countryName": .countryName
        case "organizationName": .organizationName
        case "url": .URL
        default: nil
        }
    }

    private var capitalization: TextInputAutocapitalization? {
        switch autocapitalization {
        case "never": .never
        case "words": .words
        case "sentences": .sentences
        case "characters": .characters
        default: keyboard == "email" || keyboard == "url" ? .never : nil
        }
    }
    #endif
}
