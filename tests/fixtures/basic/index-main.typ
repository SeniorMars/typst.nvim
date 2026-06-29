= Intro <sec:intro>

#import "index-lib.typ": helper-func
#import "index-lib.typ": helper-func as helper-alias
#import "index-lib.typ": *
#import "index-lib.typ" as lib
#import "index-lib.typ":
  helper-func as helper-multiline,
  exported-value as exported-multiline
#import "index-hidden.typ" as hidden
#import "index-reexport.typ": reexported-helper
#import "index-reexport.typ": reexported-alias
#import "index-reexport.typ" as reexported
#import "@preview/cetz:0.3.4": canvas
#import "@preview/article-template:1.0.0": template
#include "index-include.typ"

#let local-card(body, fill: red) = body
#let multiline-card(
  body,
  fill: aqua,
  stroke: black,
) = body
#let glossary-entries = (
  (
    key: "api",
    short: "API",
    long: "Application Programming Interface",
  ),
  (
    key: "tls",
    short: "TLS",
    long: "Transport Layer Security",
  ),
)

#set text(font: "Unit Test Serif")
#rect(fill: fuchsia, stroke: color.map.viridis)

See @sec:intro, #ref(<sec:intro>), @doe2020, @yaml2022, and #cite(<multiline2026>).
Don't hide @apostrophe:label and <apostrophe:label>.
Alice's #let apostrophe-helper() = none
#let escaped-delimiter-text = "ignore ) ] } @escaped-string <escaped:string> \" still string"

#bibliography("refs.bib", style: "custom-style.csl")
#bibliography("refs.yml", style: "ieee")
#bibliography(
  "refs-multiline.bib",
  style: "custom-multiline-style.csl",
)
#image("diagram.svg")
#image(
  "diagram-multiline.svg"
)
#let loaded = read("data.json")
#read(
  "data-extra.json"
)
#link("https://example.com/typst")[Docs]

// TODO: wire layered TOC
#figure([Chart], caption: [A chart])
#table(columns: 1, [Cell])
$ x + y $

#canvas({})
#template.with(title: [Demo])
#local-card[Body]
#helper-func[Imported]
#helper-alias[Aliased import]
#multiline-card[Multiline]
#exported-value
#lib.helper-func[Module imported]
#hidden.hidden-value
#reexported-helper[Reexported]
#reexported-alias[Reexported alias]
#reexported.reexported-helper[Module reexported]
#reexported.reexported-alias[Module reexported alias]

// @fake-comment <fake:comment> #ref(<fake:ref>) #import "fake.typ": fake #include "fake.typ" #image("fake.svg") #bibliography("fake.bib") #let fake-comment() = none #figure #table $
#let fake-text = "#figure #table $ <fake:string> @fake-string // TODO fake-string"
Inline raw: `@fake-inline <fake:inline> #ref(<fake:inline-ref>) #import "fake-inline.typ": fake-inline #include "fake-inline.typ" #image("fake-inline.svg") #bibliography("fake-inline.bib") #let fake-inline-func() = none #figure #table $`
/*
= Fake Block Heading <fake:block-heading>
@fake-block <fake:block> #ref(<fake:block-ref>)
#import "fake-block.typ": fake-block
#include "fake-block.typ"
#image("fake-block.svg")
#bibliography("fake-block.bib")
#let fake-block-func() = none
// TODO fake block
#figure #table $
*/
```typ
= Fake Raw Heading <fake:raw-heading>
@fake-raw <fake:raw> #ref(<fake:raw-ref>)
#import "fake-raw.typ": fake-raw
#include "fake-raw.typ"
#image("fake-raw.svg")
#bibliography("fake-raw.bib")
#let fake-raw-func() = none
// TODO fake raw
#figure #table $
```
