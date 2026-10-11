defmodule AlnaslWeb.Logo do
  @moduledoc """
  The mark, read from one file: `priv/logo/mark.svg`. Drawn on a 24 x 24 grid
  in `currentColor` (the ink) with one accent, `var(--accent, ...)`, so it
  follows every theme. To change the logo, replace that file (the three
  candidates are in `priv/logo/candidates/`); the header, the PIN page and
  the favicon all follow, and nothing else needs touching.
  """

  @source Path.expand("../../priv/logo/mark.svg", __DIR__)
  @external_resource @source

  @mark File.read!(@source)

  @doc "The inner markup of the mark, for an `<svg viewBox=\"0 0 24 24\">` of the caller's own."
  def inner do
    [_, inner] = Regex.run(~r/<svg[^>]*>(.*)<\/svg>/s, @mark)
    inner
  end

  @doc """
  The favicon: the mark in white (and the night accent) on an ink tile. A tab
  does not know the page's theme, so it carries a ground of its own.
  """
  def favicon do
    inner =
      inner()
      |> String.replace(~r/var\(--accent,\s*#[0-9a-fA-F]+\)/, "#e2a08c")
      |> String.replace("currentColor", "#ffffff")

    ~s|<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect width="24" height="24" rx="4" fill="#1b1b1a"/><g transform="translate(2.4 2.4) scale(.8)">#{inner}</g></svg>|
  end
end
