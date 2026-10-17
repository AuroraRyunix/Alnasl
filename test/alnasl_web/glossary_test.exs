defmodule AlnaslWeb.GlossaryTest do
  @moduledoc """
  `docs/glossary.md` in the form a machine can hold anyone to: the words it
  retired stay out of the English catalogue, the Dutch one says "je" and the
  words OpenPairings and Alnasl agreed on, and no readable string names the
  brand of the boards. What a string should say instead is the glossary's
  business; this only notices when an old word creeps back in.
  """

  use ExUnit.Case, async: true

  @pot "priv/gettext/default.pot"
  @nl "priv/gettext/nl/LC_MESSAGES/default.po"

  # English: what the site was once called, and the box where the server is too.
  @retired_en [
    ~r/results server/i,
    ~r/\bat the box\b/i,
    ~r/\b(stays|kept) on (the|this) box\b/i,
    ~r/\boff the box\b/i,
    ~r/\bthis box's own tournament\b/i,
    ~r/\bOutbox\b/,
    ~r/\bDGT\b/
  ]

  # Dutch: the box was "box", a pairing "indeling", and the reader "u".
  @retired_nl [
    ~r/\bbox(en)?\b/i,
    ~r/\bindeling(en)?\b/i,
    ~r/\bingedeeld\b/i,
    ~r/uitslagenserver/i,
    ~r/relaysleutel/i,
    ~r/(?<![\w%{])(u|uw)(?![\w}])/,
    ~r/\bDGT\b/
  ]

  test "the English catalogue keeps to the glossary" do
    offenders =
      for id <- strings(@pot, "msgid"),
          re <- @retired_en,
          Regex.match?(re, id),
          do: {re.source, id}

    assert offenders == []
  end

  test "the Dutch catalogue keeps to the glossary" do
    offenders =
      for str <- strings(@nl, "msgstr"),
          re <- @retired_nl,
          Regex.match?(re, str),
          do: {re.source, str}

    assert offenders == []
  end

  # Every msgid (or msgstr) of a catalogue, its continuation lines joined.
  defp strings(path, key) do
    path
    |> File.read!()
    |> String.split(~r/\n\n+/)
    |> Enum.flat_map(fn block ->
      Regex.scan(~r/^#{key}(?:\[\d\])? ((?:".*"\n?)+)/m, block)
      |> Enum.map(fn [_, lines] ->
        ~r/"(.*)"/ |> Regex.scan(lines) |> Enum.map_join(fn [_, s] -> s end)
      end)
    end)
    |> Enum.reject(&(&1 == ""))
  end
end
