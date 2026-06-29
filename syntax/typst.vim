" Vim syntax file
" Language: Typst
" Maintainer: SeniorMars
" This is supposed to be a basic highlighting file in case
" you don't have tree-sitter

if exists("b:current_syntax")
  finish
endif

syntax case match
syntax sync minlines=200
syntax spell toplevel

syntax keyword typstTodo TODO FIXME XXX BUG NOTE WARN WARNING contained

syntax region typstCommentBlock
      \ start="/\*" end="\*/" keepend
      \ contains=typstTodo,@Spell
syntax match typstCommentLine
      \ +//.*+
      \ contains=typstTodo,@Spell

syntax region typstRawSpan
      \ start=/`/
      \ skip=/\\`/
      \ end=/`/
      \ oneline
syntax region typstRawBlock
      \ matchgroup=typstRawDelimiter
      \ start=/^\s*```/
      \ end=/^\s*```/
      \ keepend

syntax match typstLabel
      \ /<[-[:alnum:]_:][-[:alnum:]_.:]*>/
syntax match typstRef
      \ /@[-[:alnum:]_:][-[:alnum:]_.:]*/
syntax match typstUrl
      \ /\v<\w+:\/\/\S+/

syntax match typstHeading
      \ /^\s*=\{1,6}\s.*$/
      \ contains=typstLabel,@Spell
syntax match typstListMarker
      \ /^\s*\([-+]\|\d\+\.\)\s\+/
syntax region typstTermMarker
      \ oneline
      \ start=/^\s*\/\s/
      \ end=/:/
      \ contains=@Spell

syntax region typstStrong
      \ start=/\(^\|[^[:alnum:]\\]\)\zs\*\ze\S/
      \ end=/\S\zs\*\ze\($\|[^[:alnum:]]\)/
      \ oneline keepend
      \ contains=typstLabel,typstRef,typstRawSpan,@Spell
syntax region typstEmph
      \ start=/\(^\|[^[:alnum:]\\]\)\zs_\ze\S/
      \ end=/\S\zs_\ze\($\|[^[:alnum:]]\)/
      \ oneline keepend
      \ contains=typstLabel,typstRef,typstRawSpan,@Spell

syntax cluster typstCode
      \ contains=typstCommentBlock,typstCommentLine,typstKeyword,typstStatement,
      \ typstConstant,typstBoolean,typstNumber,typstString,typstFunction,
      \ typstIdentifier,typstLabel,typstRef,typstOperator,typstCodeParen,
      \ typstCodeBrace,typstCodeBracket,typstMath

syntax match typstHash
      \ /#/
      \ contained
syntax keyword typstKeyword
      \ contained
      \ if else for while break continue return as in and or not
syntax keyword typstStatement
      \ contained
      \ let set show import include context
syntax keyword typstConstant
      \ contained
      \ none auto
syntax keyword typstBoolean
      \ contained
      \ true false

syntax match typstIdentifier
      \ /#\s*[-[:alpha:]_][-[:alnum:]_.]*/
      \ contains=typstHash
syntax match typstFunction
      \ /#\s*[-[:alpha:]_][-[:alnum:]_.]*\ze\s*[\[(]/
      \ contains=typstHash
syntax match typstStatement
      \ /#\s*\(let\|set\|show\|import\|include\|context\)\>/
      \ contains=typstHash
syntax match typstKeyword
      \ /#\s*\(if\|else\|for\|while\|break\|continue\|return\)\>/
      \ contains=typstHash

syntax region typstCodeParen
      \ matchgroup=typstDelimiter
      \ start=/#\?(/ end=/)/
      \ contains=@typstCode
syntax region typstCodeBrace
      \ matchgroup=typstDelimiter
      \ start=/#\?{/ end=/}/
      \ contains=@typstCode
syntax region typstCodeBracket
      \ matchgroup=typstDelimiter
      \ start=/#\?\[/ end=/\]/
      \ contains=typstCommentBlock,typstCommentLine,typstRawBlock,typstRawSpan,
      \ typstLabel,typstRef,typstUrl,typstHeading,typstListMarker,typstTermMarker,
      \ typstStrong,typstEmph,typstHash,typstStatement,typstKeyword,
      \ typstFunction,typstIdentifier,typstMath,@Spell

syntax region typstString
      \ start=/"/
      \ skip=/\\\\\|\\"/
      \ end=/"/
      \ oneline
syntax match typstNumber
      \ /\<0b[01]\+\>/
syntax match typstNumber
      \ /\<0o[0-7]\+\>/
syntax match typstNumber
      \ /\<0x\x\+\>/
syntax match typstNumber
      \ /\<\d\+\%(\.\d*\)\=\%([eE][+-]\=\d\+\)\=\>/
syntax match typstNumber
      \ /\.\d\+\%([eE][+-]\=\d\+\)\=\>/
syntax match typstUnit
      \ /\%(pt\|mm\|cm\|in\|em\|deg\|rad\|fr\|%\)\>/
syntax match typstOperator
      \ /[-+*\/=<>!]\|=>\|:=/
      \ contained

syntax region typstMath
      \ matchgroup=typstMathDelimiter
      \ start=/\\\@<!\$/
      \ end=/\\\@<!\$/
      \ keepend
      \ contains=typstCommentBlock,typstCommentLine,typstString,typstNumber,
      \ typstUnit,typstMathSymbol,typstOperator,typstHash,typstStatement,
      \ typstKeyword,typstFunction,typstIdentifier
syntax match typstMathSymbol
      \ /\v<[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)*>/
      \ contained
syntax match typstMathSymbol
      \ /\<[A-Za-z][A-Za-z0-9.]*\ze[_^]/
      \ contained

highlight default link typstCommentBlock Comment
highlight default link typstCommentLine Comment
highlight default link typstTodo Todo
highlight default link typstRawBlock String
highlight default link typstRawDelimiter Delimiter
highlight default link typstRawSpan String
highlight default link typstLabel Structure
highlight default link typstRef Structure
highlight default link typstUrl Underlined
highlight default link typstHeading Title
highlight default link typstListMarker Structure
highlight default link typstTermMarker Structure
highlight default link typstHash Delimiter
highlight default link typstStatement Statement
highlight default link typstKeyword Keyword
highlight default link typstConstant Constant
highlight default link typstBoolean Boolean
highlight default link typstFunction Function
highlight default link typstIdentifier Identifier
highlight default link typstDelimiter Delimiter
highlight default link typstString String
highlight default link typstNumber Number
highlight default link typstUnit Number
highlight default link typstOperator Operator
highlight default link typstMath Special
highlight default link typstMathDelimiter Delimiter
highlight default link typstMathSymbol Identifier

highlight default typstStrong term=bold cterm=bold gui=bold
highlight default typstEmph term=italic cterm=italic gui=italic

let b:current_syntax = "typst"

" vim: sw=2 sts=2 et