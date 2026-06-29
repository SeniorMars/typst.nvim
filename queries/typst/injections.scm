((line_comment) @injection.content
  (#set! injection.language "comment"))
((block_comment) @injection.content
  (#set! injection.language "comment"))

(raw
  language: (raw_language) @injection.language
  content: (raw_content) @injection.content)
