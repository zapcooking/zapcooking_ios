import Foundation
import Testing
@testable import wisp

/// Continue with Apple → new account: the name Apple shared pre-fills the
/// wizard's display name instead of asking for it again (Guideline 4).
@MainActor
struct SignUpAppleNameTests {

    @Test func suggestedName_formatsApplesName_andIsNilWhenThereIsNone() {
        var components = PersonNameComponents()
        components.givenName = "Ada"
        components.familyName = "Lovelace"
        let name = AppleAuthViewModel.suggestedName(from: components)
        #expect(name?.contains("Ada") == true)
        #expect(name?.contains("Lovelace") == true)

        // Apple returns the name only on the first authorization; later
        // sign-ins give nil or empty components. Never an empty string.
        #expect(AppleAuthViewModel.suggestedName(from: nil) == nil)
        #expect(AppleAuthViewModel.suggestedName(from: PersonNameComponents()) == nil)
        var blank = PersonNameComponents()
        blank.givenName = "  "
        #expect(AppleAuthViewModel.suggestedName(from: blank) == nil)
    }

    @Test func wizard_prefillsTheDisplayName_andLeavesItEditable() {
        let vm = SignUpViewModel(suggestedName: "Ada Lovelace", acceptance: .now())
        #expect(vm.name == "Ada Lovelace")
        vm.name = "Ada"
        #expect(vm.name == "Ada")

        #expect(SignUpViewModel(acceptance: .now()).name.isEmpty)
        #expect(SignUpViewModel(suggestedName: nil, acceptance: .now()).name.isEmpty)
    }
}
