#import "local-docs-lib.typ": helper-box

/// Draws an alert box.
///
/// - `body`: The content to display.
/// - `fill`: The background color.
#let alert-box(body, fill: red) = block(fill: fill)[#body]

#alert-box[Hello]
#helper-box[World]
