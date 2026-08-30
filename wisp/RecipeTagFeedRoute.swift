import Foundation

/// Navigation route for a recipe category feed — `recipe_tag/{tag}`.
///
/// `tag` is the category slug (`italian`), not the on-wire `#t` value
/// (`zapcooking-italian`). The repository prefixes both recipe roots
/// through ``RecipeFormat/tagFeedFilter(tag:limit:until:)``.
struct RecipeTagFeedRoute: Hashable {
    let tag: String

    init(tag: String) {
        self.tag = RecipeTagCatalog.normalize(tag)
    }
}
