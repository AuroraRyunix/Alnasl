defmodule Alnasl.Manual.Markup do
  @moduledoc """
  Turns one manual chapter's Markdown into the page's HTML, plus what the page
  is built around: the outline and the search sections. Runs at compile time,
  from `Alnasl.Manual`. The conventions are OpenPairings' manual's, so a
  chapter reads sensibly on GitHub as well as in the app.

  ## Callouts

  A blockquote whose first line is a marker becomes a callout box (GitHub's
  alert syntax):

      > [!TIP]
      > Number the boards before the hall fills up.

      > [!WARNING] Never without the PIN
      > Anybody on the network could renumber your boards.

  Markers: `NOTE`, `TIP`, `IMPORTANT`, `WARNING`, `CAUTION`. Text after the
  marker on the same line is the title; without it the title is the marker's
  name in the chapter's language.

  ## Steps

  Every numbered list is shown as a sequence of steps, so a procedure is one,
  and a list that is not an order is a bulleted list.

  ## Keys

  `<kbd>Left</kbd>`: the one piece of inline HTML understood.

  ## Links and headings

  A link to another chapter is a relative link to its file,
  `[Bridges](03-bridges.md)` or `[Roles](06-accounts-and-halls.md#roles)`, and
  opens `/help/bridges` (`#roles`). `##` and `###` headings get an id from
  their text. A translated chapter writes the English id at the end of the
  heading, `## Rollen {#roles}`, so a "?" link lands on the same section in
  every language; deriving the id from Dutch text would quietly break them.
  """

  alias Alnasl.Markdown

  @callouts %{
    "NOTE" => {"note", %{"en" => "Note", "nl" => "Opmerking"}},
    "TIP" => {"tip", %{"en" => "Tip", "nl" => "Tip"}},
    "IMPORTANT" => {"important", %{"en" => "Important", "nl" => "Belangrijk"}},
    "WARNING" => {"warning", %{"en" => "Warning", "nl" => "Opgelet"}},
    "CAUTION" => {"caution", %{"en" => "Caution", "nl" => "Let op"}}
  }

  @link_to %{"en" => "Link to this section: ", "nl" => "Link naar dit onderdeel: "}
  @table %{"en" => "Table", "nl" => "Tabel"}

  @callout_marker ~r/\A\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*([^\n]*)\n?/s

  @doc """
  Renders `markdown`. Options: `:locale` (`"en"` or `"nl"`), for the strings the
  renderer adds itself.

  Returns `%{title:, html:, toc:, sections:, summary:}`: `toc` is the `##` and
  `###` headings (`%{id:, text:, level:}`), `sections` the chapter cut at those
  headings for search (`%{id:, heading:, text:}`, the first with `id: nil` for
  the text before the first heading).
  """
  def chapter(markdown, opts \\ []) do
    locale = Keyword.get(opts, :locale, "en")
    ast = Markdown.parse(markdown)
    {title, ast} = take_title(ast)

    state = %{ids: %{}, toc: [], locale: locale}
    {ast, state} = transform_nodes(ast, state)

    %{
      title: title,
      html: Markdown.render_ast(ast),
      toc: Enum.reverse(state.toc),
      sections: sections(ast),
      summary: summary(ast)
    }
  end

  @doc "The visible text of a heading, as its id: lower-cased, other runs as `-`."
  def heading_id(text) do
    id =
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if id == "", do: "section", else: id
  end

  # ---------- the title ----------

  defp take_title([{"h1", _, children, _} | rest]), do: {String.trim(text_of(children)), rest}
  defp take_title(ast), do: {"", ast}

  # ---------- the tree walk ----------

  defp transform_nodes(nodes, state) do
    {nodes, state} = Enum.map_reduce(nodes, state, &transform/2)
    {List.flatten(nodes), state}
  end

  # Text: keyboard keys. Code and preformatted blocks are not walked at all,
  # so `<kbd>` inside backticks stays literal.
  defp transform(text, state) when is_binary(text), do: {kbd(text), state}

  defp transform({tag, _, _, _} = node, state) when tag in ["code", "pre"], do: {node, state}

  defp transform({"blockquote", _attrs, children, meta} = node, state) do
    case callout(children) do
      {:ok, kind, title, body} ->
        {kind_class, default_titles} = Map.fetch!(@callouts, kind)
        {body, state} = transform_nodes(body, state)
        title = if title == "", do: Map.fetch!(default_titles, state.locale), else: title

        {{"div",
          [
            {"class", "manual-callout manual-callout-#{kind_class}"},
            {"role", "note"},
            {"data-callout", kind_class}
          ],
          [
            {"p", [{"class", "manual-callout-title"}], [title], %{}}
            | body
          ], meta}, state}

      :error ->
        {children, state} = transform_nodes(children, state)
        {put_elem(node, 2, children), state}
    end
  end

  defp transform({level, attrs, children, meta}, state) when level in ["h2", "h3"] do
    {children, state} = transform_nodes(children, state)
    {children, explicit} = take_explicit_id(children)
    text = children |> text_of() |> String.trim()
    {id, state} = unique_id(explicit || heading_id(text), state)

    anchor =
      {"a",
       [
         {"class", "manual-anchor"},
         {"href", "#" <> id},
         {"aria-label", Map.fetch!(@link_to, state.locale) <> text}
       ], ["#"], %{}}

    toc = %{id: id, text: text, level: if(level == "h2", do: 2, else: 3)}

    {{level, [{"id", id} | drop_attr(attrs, "id")], children ++ [anchor], meta},
     %{state | toc: [toc | state.toc]}}
  end

  defp transform({"ol", attrs, children, meta}, state) do
    {children, state} = transform_nodes(children, state)

    start =
      case List.keyfind(attrs, "start", 0) do
        {"start", value} -> value |> to_string() |> Integer.parse() |> elem(0)
        nil -> 1
      end

    attrs = [{"class", "manual-steps"} | drop_attr(attrs, "class")]

    # The step numbers are a CSS counter, which knows nothing of `start`.
    attrs =
      if start > 1, do: attrs ++ [{"style", "counter-reset: step #{start - 1}"}], else: attrs

    {{"ol", attrs, children, meta}, state}
  end

  defp transform({"table", _, _, _} = table, state) do
    {table, state} = transform_children(table, state)

    {{"div",
      [
        {"class", "manual-table-wrap"},
        {"role", "region"},
        {"aria-label", Map.fetch!(@table, state.locale)},
        {"tabindex", "0"}
      ], [table], %{}}, state}
  end

  defp transform({"a", attrs, children, meta}, state) do
    {children, state} = transform_nodes(children, state)

    attrs =
      Enum.map(attrs, fn
        {"href", href} -> {"href", chapter_href(href)}
        other -> other
      end)

    {{"a", attrs, children, meta}, state}
  end

  defp transform({_, _, _, _} = node, state), do: transform_children(node, state)
  defp transform(other, state), do: {other, state}

  defp transform_children({tag, attrs, children, meta}, state) do
    {children, state} = transform_nodes(children, state)
    {{tag, attrs, children, meta}, state}
  end

  # ---------- callouts ----------

  defp callout([{"p", p_attrs, [first | rest], p_meta} | body]) when is_binary(first) do
    case Regex.run(@callout_marker, first, return: :index) do
      [{0, len}, kind_at, title_at] ->
        kind = binary_part(first, elem(kind_at, 0), elem(kind_at, 1))
        title = first |> binary_part(elem(title_at, 0), elem(title_at, 1)) |> String.trim()
        remainder = binary_part(first, len, byte_size(first) - len)
        children = if remainder == "", do: rest, else: [remainder | rest]

        body =
          if Enum.all?(children, &blank?/1),
            do: body,
            else: [{"p", p_attrs, children, p_meta} | body]

        {:ok, kind, title, body}

      _ ->
        :error
    end
  end

  defp callout(_), do: :error

  # ---------- links ----------

  # `03-bridges.md#anchor` -> `/help/bridges#anchor`. Anything else as written.
  defp chapter_href(href) do
    case Regex.run(~r{\A(?:\d+-)?([a-z0-9-]+)\.md(#[^"]*)?\z}, href) do
      [_, slug] -> "/help/" <> slug
      [_, slug, anchor] -> "/help/" <> slug <> anchor
      nil -> href
    end
  end

  # ---------- keyboard keys ----------

  defp kbd(text) do
    if String.contains?(text, "<kbd>") do
      ~r"<kbd>([^<>]{1,40})</kbd>"
      |> Regex.split(text, include_captures: true)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn piece ->
        case Regex.run(~r"\A<kbd>([^<>]{1,40})</kbd>\z", piece) do
          [_, key] -> {"kbd", [], [key], %{}}
          nil -> piece
        end
      end)
    else
      text
    end
  end

  # ---------- search sections ----------

  defp sections(ast) do
    {current, done} =
      Enum.reduce(ast, {%{id: nil, heading: nil, text: []}, []}, fn
        {level, attrs, children, _}, {current, done} when level in ["h2", "h3"] ->
          heading = children |> Enum.reject(&anchor?/1) |> text_of() |> String.trim()
          {%{id: attr(attrs, "id"), heading: heading, text: []}, [current | done]}

        node, {current, done} ->
          {%{current | text: [text_of(node) | current.text]}, done}
      end)

    [current | done]
    |> Enum.reverse()
    |> Enum.map(fn section ->
      text =
        section.text |> Enum.reverse() |> Enum.join(" ") |> String.replace(~r/\s+/, " ")

      %{section | text: String.trim(text)}
    end)
    |> Enum.reject(&(&1.id == nil and &1.text == ""))
  end

  defp summary(ast) do
    case Enum.find(ast, &match?({"p", _, _, _}, &1)) do
      nil ->
        ""

      p ->
        text = p |> text_of() |> String.replace(~r/\s+/, " ") |> String.trim()

        # Whole sentences, until there is enough to say what the chapter is.
        sentence =
          text
          |> String.split(~r/(?<=[.:])\s/)
          |> Enum.reduce_while("", fn s, acc ->
            acc = String.trim(acc <> " " <> s)
            if String.length(acc) >= 70, do: {:halt, acc}, else: {:cont, acc}
          end)

        if String.length(sentence) > 150,
          do: String.slice(sentence, 0, 147) <> "...",
          else: sentence
    end
  end

  # ---------- helpers ----------

  defp text_of(text) when is_binary(text), do: text
  defp text_of(nodes) when is_list(nodes), do: Enum.map_join(nodes, &text_of/1)
  defp text_of({"a", [{"class", "manual-anchor"} | _], _, _}), do: ""
  defp text_of({"span", _, [], _}), do: ""

  defp text_of({tag, _, children, _}) when tag in ~w(p li h2 h3 h4 tr td th pre div),
    do: " " <> text_of(children) <> " "

  defp text_of({_, _, children, _}), do: text_of(children)
  defp text_of(_), do: ""

  defp anchor?({"a", [{"class", "manual-anchor"} | _], _, _}), do: true
  defp anchor?(_), do: false

  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_), do: false

  defp attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_, value} -> to_string(value)
      nil -> ""
    end
  end

  defp drop_attr(attrs, name), do: List.keydelete(attrs, name, 0)

  @explicit_id ~r/\s*\{#([a-z0-9][a-z0-9-]*)\}\s*\z/

  defp take_explicit_id(children) do
    case List.last(children) do
      last when is_binary(last) ->
        case Regex.run(@explicit_id, last) do
          [whole, id] ->
            trimmed = binary_part(last, 0, byte_size(last) - byte_size(whole))
            {List.replace_at(children, -1, trimmed), id}

          nil ->
            {children, nil}
        end

      _ ->
        {children, nil}
    end
  end

  defp unique_id(id, state) do
    case Map.get(state.ids, id) do
      nil -> {id, %{state | ids: Map.put(state.ids, id, 1)}}
      n -> {"#{id}-#{n + 1}", %{state | ids: Map.put(state.ids, id, n + 1)}}
    end
  end
end
