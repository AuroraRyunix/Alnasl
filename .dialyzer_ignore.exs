# Every entry says why. A new finding is not added here by reflex.
[
  # `use Gettext.Backend` generates the plural call; Dialyzer disagrees with the
  # generated code about an opaque Expo struct. Not ours to change.
  {"lib/alnasl_web/gettext.ex", :call_without_opaque},
  # EarmarkParser.as_ast/2's recursive ast() type is cut off by Dialyzer at
  # [binary()], so the {"h1", ...} node pattern "can never match". It does,
  # and the manual's tests (title of every chapter) prove it. The dependency's type.
  {"lib/alnasl/manual/markup.ex", :pattern_match}
]
