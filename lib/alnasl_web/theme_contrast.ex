defmodule AlnaslWeb.ThemeContrast do
  @moduledoc """
  Colour contrast computed from stylesheets with the WCAG formula, not judged
  by eye. Shared by `AlnaslWeb.AccessibilityTest`, which holds the built-in
  themes to it, and `mix alnasl.theme_check`, which holds a theme pack to the
  very same pairings before anybody installs it - a theme is not excused
  from being readable by not having been written here.

  A theme is the `:root` palette (Paper) with a `[data-theme="<id>"]` block
  over it. What is checked:

    * every pairing in `pairs/0` - each way the site puts text on a ground -
      at 4.5:1;
    * for a pack, that it defines the whole palette, as every built-in theme
      must (a token left out would quietly be Paper's, which is how a dark
      theme ends up with dark text on it); and
    * for a pack, every rule of its own that sets a text colour and a
      background together, at 4.5:1 as well.
  """

  # {text token, ground token}: every way the site puts text on a ground.
  @pairs [
    {"ink", "bg"},
    {"ink", "panel"},
    {"ink", "sunken"},
    {"quiet", "bg"},
    {"quiet", "panel"},
    {"quiet", "sunken"},
    {"accent", "bg"},
    {"accent", "panel"},
    {"on-accent", "accent"},
    {"ok", "ok-bg"},
    {"warn", "warn-bg"},
    {"bad", "bad-bg"},
    {"idle", "idle-bg"},
    {"ink", "ok-bg"},
    {"ink", "warn-bg"},
    {"ink", "bad-bg"},
    {"reconstructed", "reconstructed-bg"},
    {"guessed", "guessed-bg"},
    {"reconstructed", "panel"},
    {"guessed", "panel"},
    {"reconstructed", "bg"},
    {"guessed", "bg"},
    {"warn", "panel"},
    {"bad", "panel"},
    {"panel", "ink"}
  ]

  # Tokens in `:root` that are not colours, and so not part of the palette.
  @not_colours ~w(radius font mono)

  @doc "The text-on-ground pairings, as `{text token, ground token}`."
  def pairs, do: @pairs

  @doc "A stylesheet with its comments removed."
  def strip_comments(css), do: Regex.replace(~r{/\*.*?\*/}s, css, "")

  @doc """
  The names of the palette's tokens: everything the first `:root` block of
  `assets/css/app.css` declares, less radius, font and mono.
  """
  def palette_names(core_css) do
    [_, root] = Regex.run(~r/:root\s*\{(.*?)\n\}/s, strip_comments(core_css))
    for([_, n] <- Regex.scan(~r/--([a-z-]+):/, root), do: n) -- @not_colours
  end

  @doc """
  Everything `mix alnasl.theme_check` reports for the pack `id`, given the
  site's stylesheet and the pack's. `[]` is a pass.
  """
  def pack_failures(core_css, pack_css, id) do
    core = strip_comments(core_css)
    css = strip_comments(pack_css)
    blocks = theme_blocks(css, id)

    if blocks == [] do
      ["no [data-theme=\"#{id}\"] { ... } block of tokens in theme.css"]
    else
      own = Enum.reduce(blocks, %{}, &Map.merge(&2, raw_tokens(&1)))
      [_, root] = Regex.run(~r/:root\s*\{(.*?)\n\}/s, core)
      palette = resolve(Map.merge(raw_tokens(root), own))

      missing =
        for name <- palette_names(core), not Map.has_key?(own, name) do
          "--#{name} is not defined: a theme defines the whole palette, or it borrows Paper's"
        end

      missing ++ pairing_failures(palette) ++ rule_failures(css, palette)
    end
  end

  @doc "Every pairing of `palette` (`%{token => colour}`) below 4.5:1, as a sentence each."
  def pairing_failures(palette) do
    for {text, ground} <- @pairs,
        failure = pairing_failure(palette, text, ground),
        failure != nil,
        do: failure
  end

  defp pairing_failure(palette, text, ground) do
    fore = palette[text]
    back = palette[ground]

    cond do
      not opaque?(back) ->
        "--#{text} on --#{ground}: --#{ground} is not a plain, opaque colour, so nothing can be measured on it"

      fore == nil ->
        "--#{text} on --#{ground}: --#{text} is not a plain colour, so it cannot be measured"

      true ->
        measured = ratio(over(fore, back), back)

        if measured < 4.5,
          do: "--#{text} on --#{ground} is #{Float.round(measured, 2)}:1, needs 4.5:1"
    end
  end

  @doc """
  The pack's own rules that set a text colour and a background together,
  measured; a translucent background is laid over `--panel`.
  """
  def rule_failures(css, palette) do
    for [selector, body] <- Regex.scan(~r/([^{}]+)\{([^{}]*)\}/, css, capture: :all_but_first),
        selector = selector |> String.trim() |> String.replace(~r/\s+/, " "),
        [color] <- [Regex.run(~r/(?:^|[;{\s])color:\s*([^;]+);/, body, capture: :all_but_first)],
        [background] <- [
          Regex.run(~r/(?:^|[;{\s])background(?:-color)?:\s*([^;]+);/, body,
            capture: :all_but_first
          )
        ],
        back = colour(palette, background),
        fore = colour(palette, color),
        back != nil and fore != nil,
        back = over(back, palette["panel"] || {255.0, 255.0, 255.0, 1.0}),
        measured = ratio(over(fore, back), back),
        measured < 4.5 do
      "#{selector}: its text on its background is #{Float.round(measured, 2)}:1, needs 4.5:1"
    end
  end

  # The bodies of the pack's token blocks: rules whose whole selector is the
  # theme's scope, bare or on `:root` / `html`.
  defp theme_blocks(css, id) do
    attr = "\\[data-theme=(?:\"#{id}\"|'#{id}'|#{id})\\]"

    for [body] <-
          Regex.scan(~r/(?:^|[\n};])\s*(?::root|html)?#{attr}\s*\{([^{}]*)\}/, css,
            capture: :all_but_first
          ),
        do: body
  end

  defp raw_tokens(body) do
    for [name, value] <- Regex.scan(~r/--([\w-]+):\s*([^;]+);/, body, capture: :all_but_first),
        into: %{},
        do: {name, String.trim(value)}
  end

  # Values as colours; `var(--x)` followed a few steps, anything else that is
  # not a flat colour dropped.
  defp resolve(raw) do
    for {name, value} <- raw, colour = follow(raw, value, 5), colour != nil, into: %{} do
      {name, colour}
    end
  end

  defp follow(_raw, _value, 0), do: nil

  defp follow(raw, value, depth) do
    case Regex.run(~r/^var\(--([\w-]+)\)$/, value, capture: :all_but_first) do
      [name] -> if raw[name], do: follow(raw, raw[name], depth - 1)
      nil -> parse(value)
    end
  end

  @doc """
  A colour value as written in a rule, `var(--token)` read from `palette`.
  `nil` for anything that is not a flat colour (a gradient, `inherit`,
  `currentColor`), which is not measured.
  """
  def colour(palette, expr) do
    expr = expr |> String.trim() |> String.replace(~r/\s*!important$/, "")

    case Regex.run(~r/^var\(--([\w-]+)\)$/, expr, capture: :all_but_first) do
      [name] -> palette[name]
      nil -> parse(expr)
    end
  end

  @doc "A literal colour (`#rgb`, `#rrggbb`, `rgb()`, `rgba()`, a few names), or `nil`."
  def parse("#" <> <<hex::binary-size(6)>>) do
    if hex =~ ~r/\A[0-9a-fA-F]{6}\z/ do
      [r, g, b] = for <<channel::binary-size(2) <- hex>>, do: String.to_integer(channel, 16) * 1.0
      {r, g, b, 1.0}
    end
  end

  def parse("#" <> <<r::binary-size(1), g::binary-size(1), b::binary-size(1)>>),
    do: parse("#" <> r <> r <> g <> g <> b <> b)

  def parse("transparent"), do: {0.0, 0.0, 0.0, 0.0}
  def parse("white"), do: {255.0, 255.0, 255.0, 1.0}
  def parse("black"), do: {0.0, 0.0, 0.0, 1.0}

  def parse(value) when is_binary(value) do
    case Regex.run(~r/^rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)$/, value,
           capture: :all_but_first
         ) do
      [r, g, b] -> {number(r), number(g), number(b), 1.0}
      [r, g, b, a] -> {number(r), number(g), number(b), number(a)}
      nil -> nil
    end
  end

  def parse(_), do: nil

  defp number(text) do
    {value, ""} = Float.parse(if String.starts_with?(text, "."), do: "0" <> text, else: text)
    value
  end

  defp opaque?({_, _, _, a}), do: a >= 1.0
  defp opaque?(_), do: false

  @doc "`fg` laid over `bg`."
  def over(nil, _bg), do: nil
  def over(_fg, nil), do: nil

  def over({r, g, b, a}, {br, bg, bb, _}),
    do: {r * a + br * (1 - a), g * a + bg * (1 - a), b * a + bb * (1 - a), 1.0}

  @doc """
  The WCAG contrast ratio of two opaque colours, given as `#rrggbb` strings
  or as parsed colours.
  """
  def ratio(a, b) when is_binary(a), do: ratio(parse(a), b)
  def ratio(a, b) when is_binary(b), do: ratio(a, parse(b))

  def ratio(a, b) do
    [lighter, darker] = Enum.sort([luminance(a), luminance(b)], :desc)
    (lighter + 0.05) / (darker + 0.05)
  end

  defp luminance({r, g, b, _}) do
    [r, g, b] =
      for c <- [r, g, b] do
        c = c / 255
        if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
      end

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end
end
