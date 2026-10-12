defmodule Alnasl.NoReg do
  @moduledoc """
  `reg.exe` for the tests: always "no such value", and nothing is written.
  The tests run on a developer's own Windows too, where a page that reads
  "Start with Windows" must not go and ask that machine's registry.
  (`config/test.exs`; `Alnasl.AutostartTest` has a stand-in that remembers.)
  """

  def cmd("reg", _args, _opts), do: {"", 1}
end
