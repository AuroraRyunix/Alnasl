defmodule Alnasl.Markdown do
  @moduledoc """
  Markdown to HTML, for the user manual (`Alnasl.Manual`).

  The parse is `earmark_parser` (pure Elixir, so the release needs no
  toolchain for it); the HTML is generated here, where escaping is not
  optional and the tag set is closed:

    1. Text and attribute values are always escaped.
    2. The tags are an allowlist. Anything else renders its children and
       drops the element, so a raw `<script>` in a chapter becomes its own
       text, not a script.
    3. `href` must be http, https, mailto or relative, so `javascript:` is not
       a scheme this renderer can emit.

  The only input is a file in this repository, read at compile time. None of
  that is load-bearing today; it is a property of the code rather than of
  today's call sites, which is the cheaper place to keep it.
  """

  @tags ~w(
    h1 h2 h3 h4 h5 h6 p br hr
    ul ol li dl dt dd
    strong em code pre
    a
    table thead tbody tr th td
    blockquote del
    kbd div span
  )

  @void ~w(br hr)

  # Attribute names are not escapable (an attacker-supplied name is a new
  # attribute, not a value), so they are a closed set too. `style` is here
  # only because earmark_parser puts table alignment and the step counter
  # there.
  @attributes ~w(class style title id role aria-label aria-hidden tabindex start data-callout)

  @doc "The parser's AST for `markdown` (GFM), for the manual to rewrite before `render_ast/1`."
  def parse(markdown) when is_binary(markdown) do
    case EarmarkParser.as_ast(markdown, gfm: true, breaks: false) do
      {:ok, ast, _messages} -> ast
      {:error, ast, _messages} -> ast
    end
  end

  @doc "Renders an AST from `parse/1` to an HTML string."
  def render_ast(nodes) when is_list(nodes), do: nodes |> Enum.map(&render/1) |> Enum.join()

  defp render(text) when is_binary(text), do: escape_text(text)

  defp render({tag, attrs, children, _meta}) do
    cond do
      tag not in @tags ->
        render_ast(children)

      tag in @void ->
        "<" <> tag <> attributes(attrs) <> " />"

      true ->
        "<" <> tag <> attributes(attrs) <> ">" <> render_ast(children) <> "</" <> tag <> ">"
    end
  end

  defp render(_other), do: ""

  defp attributes(attrs) do
    attrs
    |> Enum.filter(fn
      {"href", value} -> safe_url?(to_string(value))
      {name, _value} -> name in @attributes
    end)
    |> Enum.map_join(fn {name, value} ->
      " " <> name <> ~s(=") <> escape_attribute(to_string(value)) <> ~s(")
    end)
  end

  defp safe_url?(url) do
    trimmed = url |> String.trim() |> String.downcase()

    cond do
      String.starts_with?(trimmed, "http://") -> true
      String.starts_with?(trimmed, "https://") -> true
      String.starts_with?(trimmed, "mailto:") -> true
      # A scheme is a colon before the first slash.
      String.contains?(trimmed, ":") -> false
      true -> true
    end
  end

  defp escape_text(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_attribute(value) do
    value
    |> escape_text()
    |> String.replace(~s("), "&quot;")
    |> String.replace("'", "&#39;")
  end
end
