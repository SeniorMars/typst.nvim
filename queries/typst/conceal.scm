(math_identifier) @conceal.symbol
(math_letter) @conceal.symbol
(math_field_access) @conceal.symbol

((math_field_access) @conceal.emoji
  (#match? @conceal.emoji "^emoji\\."))

((field_access) @conceal.symbol
  (#match? @conceal.symbol "^sym\\."))
((field_access) @conceal.emoji
  (#match? @conceal.emoji "^emoji\\."))

(equation "$" @conceal.math_delimiter)

(math_attachment) @conceal.script

(strong "*" @conceal.markup_delimiter)
(emphasis "_" @conceal.markup_delimiter)

(heading marker: (heading_marker) @conceal.heading_marker)

(bullet_list_item marker: (bullet_list_marker) @conceal.list_marker)
(numbered_list_item marker: (numbered_list_marker) @conceal.list_marker)
(term_list_item marker: (term_list_marker) @conceal.list_marker)

(raw (raw_delimiter) @conceal.raw_delimiter)
((raw (raw_delimiter) @conceal.raw_block_fence)
  (#match? @conceal.raw_block_fence "^```"))
(raw language: (raw_language) @conceal.raw_block_language)

(label) @conceal.label_delimiter

(reference "@" @conceal.reference_marker)

(embedded_code
  (function_call
    function: (identifier)
    arguments: (arguments)) @conceal.function_wrapper)
