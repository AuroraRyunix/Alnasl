defmodule AlnaslWeb.AccessibilityTest do
  @moduledoc """
  The accessibility pass, as far as a machine can make one.

  - **Contrast**: every pairing of the colour tokens that is used for text
    reaches 4.5:1 (WCAG AA) in the light and in the dark theme. The numbers
    are computed from `assets/css/app.css` itself, so a token cannot be
    changed into an unreadable one without this failing.
  - **Structure**, on every page with boards connected: one `h1`; a skip link
    to `main`; every field has a label; every button and link has a name;
    every picture is either named or hidden from a screen reader; no id is
    used twice.
  - **Never colour alone**: every board state has its own shape and its own
    word.

  What it cannot check - focus order as experienced, the wording, whether
  the shapes are told apart at arm's length - is for a person.
  """

  use AlnaslWeb.SiteCase

  # --- contrast ----------------------------------------------------------------

  # {text token, background token}: every way text is put on a ground.
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
    {"warn", "panel"},
    {"bad", "panel"},
    {"panel", "ink"}
  ]

  defp tokens(block) do
    for [_, name, hex] <- Regex.scan(~r/--([a-z-]+):\s*(#[0-9a-fA-F]{6})\s*;/, block),
        into: %{},
        do: {name, hex}
  end

  defp themes do
    css = File.read!("assets/css/app.css")
    [_, light] = Regex.run(~r/:root\s*\{(.*?)\n\}/s, css)
    [_, dark] = Regex.run(~r/:root\[data-theme="dark"\]\s*\{(.*?)\n\}/s, css)
    [_, system_dark] = Regex.run(~r/:root:not\(\[data-theme="light"\]\)\s*\{(.*?)\n  \}/s, css)
    %{light: tokens(light), dark: tokens(dark), system_dark: tokens(system_dark)}
  end

  defp luminance("#" <> hex) do
    [r, g, b] =
      for <<pair::binary-size(2) <- hex>> do
        c = String.to_integer(pair, 16) / 255
        if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
      end

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  defp ratio(a, b) do
    [hi, lo] = Enum.sort([luminance(a), luminance(b)], :desc)
    (hi + 0.05) / (lo + 0.05)
  end

  test "every text pairing of the tokens reaches 4.5:1 in both themes" do
    themes = themes()

    report =
      for theme <- [:light, :dark], {text, ground} <- @pairs do
        t = themes[theme]

        assert is_binary(t[text]) and is_binary(t[ground]),
               "token --#{text} or --#{ground} missing in #{theme}"

        {theme, text, ground, Float.round(ratio(t[text], t[ground]), 2)}
      end

    failing = Enum.filter(report, fn {_theme, _text, _ground, r} -> r < 4.5 end)
    assert failing == [], "below 4.5:1: #{inspect(failing)}"

    worst = Enum.min_by(report, &elem(&1, 3))
    IO.puts("\n  contrast: #{length(report)} pairings checked, lowest #{inspect(worst)}")
  end

  test "the dark theme is the same whether the system asks for it or the arbiter picks it" do
    themes = themes()
    assert themes.dark == themes.system_dark
    assert Map.keys(themes.dark) -- Map.keys(themes.light) == []
  end

  # --- never colour alone ------------------------------------------------------

  test "every board state has its own shape and its own word" do
    states = [
      :live,
      :waiting_start,
      :settling,
      :recovered,
      :out_of_sync,
      :no_signal,
      :clock_alarm,
      :finished,
      :unlinked
    ]

    rendered =
      for state <- states do
        html = render_component(&AlnaslWeb.CoreComponents.state/1, state: state)
        [_, shape] = Regex.run(~r/<svg[^>]*>(.*?)<\/svg>/s, html)
        {AlnaslWeb.CoreComponents.state_word(state), shape}
      end

    assert rendered |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == length(states)
    assert rendered |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == length(states)
  end

  # --- structure ---------------------------------------------------------------

  defp attr(node, name), do: node |> LazyHTML.attribute(name) |> List.first()

  defp named?(node) do
    String.trim(LazyHTML.text(node)) != "" or attr(node, "aria-label") not in [nil, ""] or
      attr(node, "title") not in [nil, ""]
  end

  defp check(html, path) do
    doc = LazyHTML.from_document(html)

    assert Enum.count(LazyHTML.query(doc, "h1")) == 1, "#{path}: not exactly one h1"
    assert Enum.count(LazyHTML.query(doc, "main#main")) == 1, "#{path}: no main"
    assert Enum.count(LazyHTML.query(doc, "a.skip[href='#main']")) == 1, "#{path}: no skip link"

    ids = doc |> LazyHTML.query("[id]") |> LazyHTML.attribute("id")

    assert ids -- Enum.uniq(ids) == [],
           "#{path}: ids used twice: #{inspect(ids -- Enum.uniq(ids))}"

    labelled = doc |> LazyHTML.query("label[for]") |> LazyHTML.attribute("for") |> MapSet.new()

    for field <- LazyHTML.query(doc, "input:not([type=hidden]), select, textarea") do
      id = attr(field, "id")

      assert (id && id in labelled) or attr(field, "aria-label") not in [nil, ""],
             "#{path}: a field without a label: #{LazyHTML.to_html(field) |> String.slice(0, 160)}"
    end

    for control <- LazyHTML.query(doc, "button, a") do
      assert named?(control),
             "#{path}: a button or link without a name: #{LazyHTML.to_html(control) |> String.slice(0, 200)}"
    end

    for picture <- LazyHTML.query(doc, "svg") do
      hidden? = attr(picture, "aria-hidden") == "true"
      named? = attr(picture, "role") == "img" and attr(picture, "aria-label") not in [nil, ""]
      assert hidden? or named?, "#{path}: a picture that is neither named nor hidden"
    end

    for table <- LazyHTML.query(doc, "table") do
      assert Enum.count(LazyHTML.query(table, "th")) > 0, "#{path}: a table without headers"
    end
  end

  test "every page, with a round under way, passes the structural checks", %{conn: conn} do
    start_supervised!(Outbox)
    board = fake_dgt("FAKE1", %{round: 1, board_no: 1})
    eventually(fn -> Boards.snapshot(board.id).connected? end)
    play_on("FAKE1", board.id, ~w(e4 e5 Nf3))

    set_pieces(
      "FAKE1",
      List.last(boards_after(~w(e4 e5 Nf3))) |> put_elem(40, {:w, :r}) |> put_elem(56, nil)
    )

    eventually(fn -> Boards.snapshot(board.id).status == :out_of_sync end)
    {:ok, _} = Boards.attach_pgn(1, 2, hd(elem(Alnasl.Pgn.load("1. e4 e5 1/2-1/2"), 0)))
    FakeIngest.mode(:down)
    Recorder.flush()

    for path <-
          ~w(/ /round/1/board/1 /round/1/board/2 /round/1/board/4 /boards /outbox /pgn /recordings /log /setup /help) do
      for locale <- ~w(en nl) do
        Settings.put("locale", locale)
        html = conn |> get(path) |> html_response(200)
        check(html, "#{path} (#{locale})")
        assert html =~ ~s(lang="#{locale}">)
      end
    end

    Settings.set_pin("2468")
    door = %{conn | remote_ip: {10, 0, 0, 9}} |> get(~p"/unlock") |> html_response(200)
    doc = LazyHTML.from_document(door)
    assert Enum.count(LazyHTML.query(doc, "label[for=unlock-pin]")) == 1
    assert Enum.count(LazyHTML.query(doc, "main")) == 1
  end

  test "no English is left in the Dutch catalogue, and nothing is untranslated" do
    po = File.read!("priv/gettext/nl/LC_MESSAGES/default.po")
    entries = Regex.scan(~r/^msgid "(.+)"\nmsgstr "(.*)"$/m, po)
    assert length(entries) > 400
    assert for([_, id, ""] <- entries, do: id) == []
    refute po =~ "#, fuzzy"
  end
end
