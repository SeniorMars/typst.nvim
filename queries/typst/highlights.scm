;; All scopes: comments and directives
[
  (line_comment)
  (block_comment)
] @comment

;; Code
["#"] @punctuation.special
[":" ";" ","] @punctuation.delimiter
["(" ")" "{" "}"] @punctuation.bracket
;; maybe give these a special color when used to denote content blocks?
[ "[" "]" ] @punctuation.bracket
"." @operator

;; keywords?
[ "include" "import" ] @include
[ "set" "let" "show" ] @keyword
(set_expression
    name: (function_call
        name: (identifier) @function.builtin (#set! "priority" 101)))
    

;; the parser should probably output a variable node type...
((identifier) @variable (#set! "priority" 95))

;; units and literals
(boolean_literal) @boolean
[ (quote) (string_literal) ] @string
[ (none) (auto) ] @keyword
[
    (numeric)
    (int_literal)
    (float_literal)
] @number
;; should I we have separate colors for units?

;; Function Calls
;; on anonymous functions such as (g())(args),
;; don't highlight (g()) as @function
;; only if the name is identifier
(function_call
    name: (identifier) @function)

(method_call
    method: _ @method)

(assigned_argument
    name: (_) @parameter
    value: (_))

;; dictionary pairs
(pair
    key: (_) @field)

;; operators
[
    "-"
    "+"
    "*"
    "/"

    "=="
    "!="
    "<"
    "<="
    ">"
    ">="

    "="
    "+="
    "-="
    "*="
    "/="

    "=>"

    "in"
    "and"
    "or"
    "not"
] @operator

;; Control Flow
[
    "for"
    "while"
    "break"
    "continue"
] @repeat

;; Inside of a for loop, "in" should be part of the repeat highlight
(for_expression "in" @repeat)

[
    "if"
    "else"
] @conditional

;; Markdown
(strong) @text.strong
(emphasis) @text.emphasis

