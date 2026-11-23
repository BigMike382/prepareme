import Foundation

/// The walk-throughs beside the guides (step 10; packer/walkthroughs.py): the phone app tells every page it shows whose
/// phone it is, after each load, as the root's `data-role` ("adult" or "child", from `PhoneInventoryModel.isChild`),
/// which the page's styles read (packer.reading_style.READING): a child's phone gets a guide's kids' walk-through in
/// place of the adult one, and no button at all when there is no kids' version. Until the role is set the phone shows
/// neither button, so a child's phone never shows the adult one, even for a moment.
public enum WalkthroughRole {
    public static let attribute = "data-role"

    /// The script that marks the page with the phone's role.
    public static func script(child: Bool) -> String {
        "document.documentElement.setAttribute('\(attribute)','\(child ? "child" : "adult")')"
    }

    /// Both marks a phone page carries about the phone, its role and where Event mode is switched (`data-host`, the
    /// live script's word: LiveBlock.host), from the role the app holds: set before every page draws, and sent again to
    /// the pages already open when the role changes (F-092), so a page loaded before the Mac's answer follows it. A
    /// role not yet known gives the child's words in both (F-094: fail closed, as `isChild` and `host` do).
    public static func phoneMarks(canEdit: Bool, child: Bool) -> String {
        let host = LiveBlock.host(canEdit: canEdit)
        return "document.documentElement.setAttribute('data-host','\(host)');" + script(child: child)
    }
}
