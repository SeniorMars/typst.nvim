-- Compatibility shim. New compiler lifecycle code should use
-- `typst.compiler.state_machine` directly.
return require("typst.compiler.state_machine")
