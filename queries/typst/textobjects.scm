(heading) @heading.outer
(heading body: (heading_body) @heading.inner)

(section) @section.outer
(section heading: (heading body: (heading_body) @section.inner))

(equation) @equation.outer
(equation body: (math) @equation.inner)

(content) @content.outer
(content (text) @content.inner)

(content_block) @block.outer
(content_block (_) @block.inner)
(code_block) @block.outer
(code_block (_) @block.inner)
(raw) @block.outer
(raw content: (raw_content) @block.inner)
(equation) @block.outer
(equation body: (math) @block.inner)
(function_call) @block.outer
(function_call arguments: (arguments) @block.inner)

(content_block) @structural_block.outer
(content_block (_) @structural_block.inner)
(code_block) @structural_block.outer
(code_block (_) @structural_block.inner)
(raw) @structural_block.outer
(raw content: (raw_content) @structural_block.inner)
(equation) @structural_block.outer
(equation body: (math) @structural_block.inner)
(function_call) @structural_block.outer
(function_call arguments: (arguments) @structural_block.inner)
(arguments) @structural_block.outer
(arguments (_) @structural_block.inner)
[
  (bullet_list_item)
  (numbered_list_item)
  (term_list_item)
] @structural_block.outer
[
  (bullet_list_item)
  (numbered_list_item)
  (term_list_item)
] (text) @structural_block.inner

(raw) @code_block.outer
(raw content: (raw_content) @code_block.inner)
(code_block) @code_block.outer
(code_block (_) @code_block.inner)
(raw) @raw_block.outer
(raw content: (raw_content) @raw_block.inner)

[
  (bullet_list_item)
  (numbered_list_item)
  (term_list_item)
] @list_item.outer
[
  (bullet_list_item)
  (numbered_list_item)
  (term_list_item)
] (text) @list_item.inner

(label) @label.outer
(reference) @label.outer

(module_import) @import.outer
(module_include) @import.outer

(function_call) @call.outer
(function_call arguments: (arguments) @call.inner)

(arguments (_) @argument.outer)
(arguments (content_block (content (text) @argument.inner)))
(arguments (string) @argument.inner)
(arguments (integer) @argument.inner)
(arguments (float) @argument.inner)
(arguments (numeric) @argument.inner)
(named_argument value: (_) @argument.outer)
(named_argument value: (content_block (content (text) @argument.inner)))
(named_argument value: (string) @argument.inner)
(named_argument value: (integer) @argument.inner)
(named_argument value: (float) @argument.inner)
(named_argument value: (numeric) @argument.inner)
