= Syntax Fixture <syntax-fixture>

/// Build a local documented helper.
// TODO: tighten package syntax captures.
// NOTE: parser-backed fixtures cover editor queries.
// WARN: lossy conceal should stay opt-in.
// FIXME: malformed examples live in the query test.
#let note(body, tone: "info") = [
  *Note:* #body
]

#import "index-lib.typ": exported as local-export

This paragraph has *strong text*, _emphasis_, `raw inline`, @syntax-fixture,
an explicit emoji #emoji.face.halo, and math $ alpha + beta + arrow.r + RR + x_1 + y^2 + emoji.face.halo $.

Function wrapper #strong[wrapped].

- First list item <first-item>
- Second list item with @first-item
+ Alternate list marker

== Code

#figure(
  [Figure body],
  caption: [Figure caption],
  kind: "demo",
)

```typst
#let z = 3
#show heading: strong
```

== More Math

$
  sum_(i = 1)^n i = n(n + 1) / 2
$
