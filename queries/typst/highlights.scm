; Comments and documentation comments.
((line_comment) @comment @spell
  (#set! bo.commentstring "// %s"))
((block_comment) @comment @spell
  (#set! bo.commentstring "/* %s */"))

((line_comment) @comment.todo
  (#match? @comment.todo "TODO"))
((block_comment) @comment.todo
  (#match? @comment.todo "TODO"))

((line_comment) @comment.note
  (#match? @comment.note "NOTE"))
((block_comment) @comment.note
  (#match? @comment.note "NOTE"))

((line_comment) @comment.warning
  (#match? @comment.warning "WARN(ING)?"))
((block_comment) @comment.warning
  (#match? @comment.warning "WARN(ING)?"))

((line_comment) @comment.error
  (#match? @comment.error "FIXME|XXX|BUG"))
((block_comment) @comment.error
  (#match? @comment.error "FIXME|XXX|BUG"))

; Parser errors.
(ERROR) @error

; Spell-checking regions.
(text) @spell
(heading_body) @spell
(raw) @nospell
(string) @nospell
(equation) @nospell
(math) @nospell

; Markup structure.
(heading) @markup.heading
((heading marker: (heading_marker) @markup.heading.1)
  (#eq? @markup.heading.1 "="))
((heading marker: (heading_marker) @markup.heading.2)
  (#eq? @markup.heading.2 "=="))
((heading marker: (heading_marker) @markup.heading.3)
  (#eq? @markup.heading.3 "==="))
((heading marker: (heading_marker) @markup.heading.4)
  (#eq? @markup.heading.4 "===="))
((heading marker: (heading_marker) @markup.heading.5)
  (#eq? @markup.heading.5 "====="))
((heading marker: (heading_marker) @markup.heading.6)
  (#eq? @markup.heading.6 "======"))

(strong) @markup.strong
(strong "*" @punctuation.delimiter)
(emphasis) @markup.italic
(emphasis "_" @punctuation.delimiter)

(label) @label
(reference) @markup.link.label
(reference "@" @punctuation.special)

(bullet_list_item marker: (bullet_list_marker) @markup.list)
(numbered_list_item marker: (numbered_list_marker) @markup.list)
(term_list_item marker: (term_list_marker) @markup.list)

; Raw text and fenced code.
(raw) @markup.raw
(raw (raw_delimiter) @punctuation.delimiter)
((raw (raw_delimiter) @_raw_delimiter) @markup.raw.block
  (#match? @_raw_delimiter "^```"))
(raw language: (raw_language) @string.special)
(raw content: (raw_content) @markup.raw.block)

; Code expressions.
(embedded_code "#" @punctuation.special)

(module_import "import" @keyword.import)
(module_include "include" @keyword.import)
"as" @keyword.operator

[
  "let"
  "set"
  "show"
  "context"
] @keyword

(for_loop ["for" "in"] @keyword.repeat)
(while_loop "while" @keyword.repeat)
(break_expression) @keyword.repeat
(continue_expression) @keyword.repeat

(if_expression ["if" "else"] @keyword.conditional)

(let_binding name: (identifier) @variable.definition)
(let_binding name: (identifier) @function parameters: (parameters))
(parameters (identifier) @variable.parameter)
(named_parameter name: (identifier) @variable.parameter)
(named_argument name: (identifier) @variable.parameter)
(sink_parameter name: (identifier) @variable.parameter)
(closure parameters: (identifier) @variable.parameter)

(function_call function: (identifier) @function.call)
(function_call function: (field_access field: (identifier) @function.call))

(string) @string
(integer) @number
(float) @number
(numeric) @number
(boolean) @boolean
(none) @constant.builtin
(auto) @constant.builtin

; Math.
(equation) @markup.math
(math_identifier) @constant
(math_letter) @constant
(math_field_access) @constant
(math_number) @number
(math_shorthand) @operator
(math_attachment ["_" "^"] @operator)
(equation "$" @punctuation.special)
(math_delimiter) @punctuation.bracket

; Punctuation and grouping.
[
  ":"
  ";"
  ","
] @punctuation.delimiter

[
  "("
  ")"
  "{"
  "}"
  "["
  "]"
] @punctuation.bracket

[
  "-"
  "+"
  "*"
  "/"
  "="
  "=>"
  "and"
  "or"
  "not"
  "in"
] @operator
