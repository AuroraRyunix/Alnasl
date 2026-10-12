defmodule Alnasl.Listen do
  @moduledoc """
  Who the management site answers: the box itself only, or the hall's
  network as well - and where that choice is kept.

  The address is bound when the program starts, before the database is
  open, so the choice cannot be a row in it. It is one word (`lan` or
  `local`) in the file `listen` in the data directory, which
  `config/runtime.exs` reads. `ALNASL_LISTEN` in the environment wins over
  the file: a box whose unit says `lan` is not talked out of it by a page.

  The default is `local`. An installed box that nobody has set up has no
  PIN, and a site without a PIN on a hall's network is everybody's.
  A change takes effect the next time the program starts.
  """

  alias Alnasl.Paths

  @doc "`\"lan\"` or `\"local\"` when the environment decides, else `nil`."
  def forced do
    case System.get_env("ALNASL_LISTEN") do
      nil -> nil
      "" -> nil
      "lan" -> "lan"
      _anything_else -> "local"
    end
  end

  @doc "What the next start will do: `\"lan\"` or `\"local\"`."
  def chosen do
    forced() ||
      case File.read(file()) do
        {:ok, word} -> if String.trim(word) == "lan", do: "lan", else: "local"
        _none -> "local"
      end
  end

  def put(choice) when choice in ["lan", "local"], do: File.write(file(), choice <> "\n")

  defp file, do: Path.join(Paths.data(), "listen")
end
