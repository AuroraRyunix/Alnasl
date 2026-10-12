defmodule AlnaslWeb.CoreComponents do
  @moduledoc """
  The pieces every page is built from: buttons, fields, panels, the state
  badge, the chess board, the clock.

  Hand-written, with the classes of `assets/css/app.css`. No component
  library and no icon font: the handful of icons the site needs are drawn
  here, and a state is always a shape and a word, never a colour alone.
  """

  use Phoenix.Component
  use Gettext, backend: AlnaslWeb.Gettext

  alias Alnasl.{Clock, Position}
  alias Phoenix.LiveView.JS

  # --- icons -------------------------------------------------------------------

  @icons %{
    # Shapes for states. Each is distinct in outline, not only in colour.
    "live" => ~s|<circle cx="12" cy="12" r="7" fill="currentColor"/>|,
    "waiting" =>
      ~s|<circle cx="12" cy="12" r="6.5" fill="none" stroke="currentColor" stroke-width="2.5"/>|,
    "settling" =>
      ~s|<circle cx="5" cy="12" r="2.4" fill="currentColor"/><circle cx="12" cy="12" r="2.4" fill="currentColor"/><circle cx="19" cy="12" r="2.4" fill="currentColor"/>|,
    "recovered" =>
      ~s|<path d="M12 3.5 21.5 20h-19z" fill="currentColor"/><path d="M12 10v4.5M12 17.2v.2" stroke="var(--warn-bg, #fff)" stroke-width="2.2" stroke-linecap="round"/>|,
    "out_of_sync" =>
      ~s|<rect x="3.5" y="3.5" width="17" height="17" rx="2" fill="currentColor"/><path d="m8.5 8.5 7 7m0-7-7 7" stroke="var(--bad-bg, #fff)" stroke-width="2.4" stroke-linecap="round"/>|,
    "clock_alarm" =>
      ~s|<path d="M12 2.5 21.5 12 12 21.5 2.5 12z" fill="currentColor"/><path d="M12 7.5V12l3 2" fill="none" stroke="var(--bad-bg, #fff)" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>|,
    "no_signal" =>
      ~s|<circle cx="12" cy="12" r="7.5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-dasharray="3.2 3"/><path d="m6 18 12-12" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>|,
    "finished" =>
      ~s|<path d="M5 3v18" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/><path d="M6.5 4.5h12l-3 4 3 4h-12z" fill="currentColor"/>|,
    "unlinked" =>
      ~s|<path d="M9.5 14.5 6.8 17.2a3 3 0 0 1-4.2-4.2l3-3M14.5 9.5l2.7-2.7a3 3 0 0 1 4.2 4.2l-3 3M8 4v2.5M4 8h2.5M16 20v-2.5M20 16h-2.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>|,
    # Navigation and actions.
    "round" =>
      ~s|<rect x="3" y="3" width="7.5" height="7.5" rx="1" fill="currentColor"/><rect x="13.5" y="3" width="7.5" height="7.5" rx="1" fill="none" stroke="currentColor" stroke-width="2"/><rect x="3" y="13.5" width="7.5" height="7.5" rx="1" fill="none" stroke="currentColor" stroke-width="2"/><rect x="13.5" y="13.5" width="7.5" height="7.5" rx="1" fill="currentColor"/>|,
    "boards" =>
      ~s|<rect x="3" y="4" width="18" height="13" rx="1.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M8 21h8M12 17v4" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><path d="M7 8h4v5H7z" fill="currentColor"/>|,
    "outbox" =>
      ~s|<path d="M12 15V4m0 0L7.5 8.5M12 4l4.5 4.5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/><path d="M4 14v4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>|,
    "pgn" =>
      ~s|<path d="M6 3h8l4 4v14H6z" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/><path d="M14 3v4h4M9 12h6M9 16h6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>|,
    "recordings" =>
      ~s|<circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="12" cy="12" r="3.5" fill="currentColor"/>|,
    "log" =>
      ~s|<path d="M4 6h16M4 12h16M4 18h10" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>|,
    "setup" =>
      ~s|<path d="M4 7h9M17 7h3M4 17h3M11 17h9" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/><circle cx="15" cy="7" r="2.5" fill="none" stroke="currentColor" stroke-width="2.2"/><circle cx="9" cy="17" r="2.5" fill="none" stroke="currentColor" stroke-width="2.2"/>|,
    "help" =>
      ~s|<circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M9.5 9.5a2.5 2.5 0 1 1 3.6 2.2c-.7.4-1.1.9-1.1 1.8" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="16.8" r="1.1" fill="currentColor"/>|,
    "ok" =>
      ~s|<path d="m5 12.5 4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>|,
    "warning" =>
      ~s|<path d="M12 3.5 21.5 20h-19z" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/><path d="M12 10v4.5" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/><circle cx="12" cy="17.2" r="1.1" fill="currentColor"/>|,
    "error" =>
      ~s|<circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="m8.8 8.8 6.4 6.4m0-6.4-6.4 6.4" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>|,
    "offline" =>
      ~s|<path d="M3 9a14 14 0 0 1 18 0M6.5 12.5a9 9 0 0 1 11 0M10 16a4 4 0 0 1 4 0" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><path d="m4 20 16-16" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>|,
    "back" =>
      ~s|<path d="M14.5 5.5 8 12l6.5 6.5" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>|,
    "send" =>
      ~s|<path d="M4 12 20 4l-5 16-3.5-6.5z" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/>|,
    "flip" =>
      ~s|<path d="M7 4v14m0 0-3.5-3.5M7 18l3.5-3.5M17 20V6m0 0-3.5 3.5M17 6l3.5 3.5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>|,
    "external" =>
      ~s|<path d="M14 4h6v6M20 4l-9 9M18 14v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>|,
    "theme" =>
      ~s|<circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 3.5a8.5 8.5 0 0 1 0 17z" fill="currentColor"/>|
  }

  @doc "The mark (`AlnaslWeb.Logo`): decorative, the name beside it says what it is."
  attr :class, :any, default: nil

  def logo(assigns) do
    assigns = assign(assigns, :inner, Phoenix.HTML.raw(AlnaslWeb.Logo.inner()))

    ~H"""
    <svg class={["logo", @class]} viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      {@inner}
    </svg>
    """
  end

  @doc "One of the site's own icons, by name. Decorative: the word beside it says what it means."
  attr :name, :string, required: true
  attr :class, :any, default: nil

  def icon(assigns) do
    assigns = assign(assigns, :paths, Map.get(@icons, assigns.name, @icons["waiting"]))

    ~H"""
    <svg class={@class} viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      {Phoenix.HTML.raw(@paths)}
    </svg>
    """
  end

  # --- state -------------------------------------------------------------------

  @doc "The tone (`ok`, `warn`, `bad` or nothing) a board state is shown in."
  def tone(:live), do: "ok"
  def tone(:finished), do: nil
  def tone(:recovered), do: "warn"
  def tone(:settling), do: nil
  def tone(:ambiguous), do: "warn"
  def tone(:waiting_start), do: nil
  def tone(:out_of_sync), do: "bad"
  def tone(:no_signal), do: "bad"
  def tone(:clock_alarm), do: "bad"
  def tone(_other), do: nil

  @doc "The word for a board state."
  def state_word(:live), do: gettext("Live")
  def state_word(:waiting_start), do: gettext("Waiting for start")
  def state_word(:settling), do: gettext("Settling")
  def state_word(:ambiguous), do: gettext("Settling")
  def state_word(:recovered), do: gettext("Reconstructed")
  def state_word(:out_of_sync), do: gettext("Out of sync")
  def state_word(:no_signal), do: gettext("No signal")
  def state_word(:clock_alarm), do: gettext("Clock wrong way")
  def state_word(:finished), do: gettext("Finished")
  def state_word(:unlinked), do: gettext("Not linked")
  def state_word(_other), do: gettext("Unknown")

  defp state_icon(:live), do: "live"
  defp state_icon(:waiting_start), do: "waiting"
  defp state_icon(:settling), do: "settling"
  defp state_icon(:ambiguous), do: "settling"
  defp state_icon(:recovered), do: "recovered"
  defp state_icon(:out_of_sync), do: "out_of_sync"
  defp state_icon(:no_signal), do: "no_signal"
  defp state_icon(:clock_alarm), do: "clock_alarm"
  defp state_icon(:finished), do: "finished"
  defp state_icon(:unlinked), do: "unlinked"
  defp state_icon(_other), do: "waiting"

  @doc "A board's state: shape, word, tone."
  attr :state, :atom, required: true
  attr :id, :string, default: nil

  def state(assigns) do
    ~H"""
    <span id={@id} class={["state", tone(@state)]} data-state={@state}>
      <.icon name={state_icon(@state)} />{state_word(@state)}
    </span>
    """
  end

  @doc "A badge with a tone and any words."
  attr :tone, :string, default: nil
  attr :icon, :string, default: nil
  attr :id, :string, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span id={@id} class={["state", @tone]}>
      <.icon :if={@icon} name={@icon} />{render_slot(@inner_block)}
    </span>
    """
  end

  # --- the board ---------------------------------------------------------------

  @doc """
  A chess board, drawn on the server as SVG.

  `position` is 64 characters (`Alnasl.Position.to_text/1`) or `nil` for a
  board nothing is known about. `last` marks the two squares of the last
  move; `diff` outlines squares (those where a raw board differs from the
  certain one). `label` is what a screen reader is told instead of 64 squares.
  """
  attr :position, :string, default: nil
  attr :last, :any, default: nil
  attr :diff, :list, default: []
  attr :coords, :boolean, default: false
  attr :label, :string, default: nil
  attr :id, :string, default: nil

  def board(assigns) do
    pieces =
      case assigns.position && Position.from_text(assigns.position) do
        {:ok, board} ->
          for i <- 0..63, piece = elem(board, i), do: {rem(i, 8), div(i, 8), symbol(piece)}

        _none ->
          []
      end

    marks =
      case assigns.last do
        {from, to} -> [from, to]
        _none -> []
      end

    assigns = assign(assigns, pieces: pieces, marks: marks)

    ~H"""
    <svg
      id={@id}
      class={["board", @position == nil && "blank"]}
      viewBox="0 0 8 8"
      role="img"
      aria-label={@label || gettext("Chess board")}
    >
      <rect
        :for={i <- 0..63}
        x={rem(i, 8)}
        y={div(i, 8)}
        width="1"
        height="1"
        class={if rem(rem(i, 8) + div(i, 8), 2) == 0, do: "l", else: "d"}
      />
      <rect :for={i <- @marks} x={rem(i, 8)} y={div(i, 8)} width="1" height="1" class="mark" />
      <g :if={@coords}>
        <text :for={f <- 0..7} x={f + 0.06} y="7.95">{<<?a + f>>}</text>
        <text :for={r <- 0..7} x="7.8" y={r + 0.28}>{8 - r}</text>
      </g>
      <use
        :for={{x, y, id} <- @pieces}
        href={"/pieces/cburnett.svg#" <> id}
        x={x}
        y={y}
        width="1"
        height="1"
      />
      <rect
        :for={i <- @diff}
        x={rem(i, 8) + 0.05}
        y={div(i, 8) + 0.05}
        width="0.9"
        height="0.9"
        class="diff"
      />
    </svg>
    """
  end

  defp symbol({colour, kind}), do: Atom.to_string(colour) <> String.upcase(Atom.to_string(kind))

  @figurines %{"K" => "♔", "Q" => "♕", "R" => "♖", "B" => "♗", "N" => "♘"}

  @doc "A move in figurine notation: the piece letter as a chess figure."
  attr :san, :string, required: true

  def figurine(assigns) do
    {figure, rest} =
      case assigns.san do
        <<letter::binary-size(1), rest::binary>> when is_map_key(@figurines, letter) ->
          {@figurines[letter], rest}

        san ->
          {nil, san}
      end

    # A promotion's piece letter is a figure too.
    rest = Regex.replace(~r/=([QRBN])/, rest, fn _all, letter -> "=" <> @figurines[letter] end)
    assigns = assign(assigns, figure: figure, rest: rest)

    ~H"""
    <span title={@san}><span :if={@figure} class="fig" aria-hidden="true">{@figure}</span><span aria-hidden="true">{@rest}</span><span class="sr-only">{@san}</span></span>
    """
  end

  @doc "A clock time, and whether it is the one running."
  attr :ms, :any, default: nil
  attr :running, :boolean, default: false

  def clock(assigns) do
    ~H"""
    <span class={["clock", @running && "running"]}>
      {Clock.format(@ms)}<span :if={@running} class="sr-only">{gettext("(running)")}</span>
    </span>
    """
  end

  # --- structure ---------------------------------------------------------------

  attr :id, :string, default: nil
  attr :title, :string, default: nil
  attr :flush, :boolean, default: false
  attr :class, :any, default: nil
  slot :actions
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section id={@id} class={["panel", @class]}>
      <header :if={@title}>
        <h2>{@title}</h2>
        {render_slot(@actions)}
      </header>
      <div class={["body", @flush && "flush"]}>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  @doc "A button, or a link that looks like one when given `navigate`, `patch` or `href`."
  attr :variant, :string, default: nil, values: [nil, "primary", "danger", "ghost"]
  attr :small, :boolean, default: false
  attr :icon, :string, default: nil
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled type form target rel)

  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :classes, ["btn", assigns.variant, assigns.small && "small", assigns.class])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@classes} {@rest}><.icon :if={@icon} name={@icon} />{render_slot(@inner_block)}</.link>
      """
    else
      ~H"""
      <button class={@classes} {@rest}><.icon :if={@icon} name={@icon} />{render_slot(@inner_block)}</button>
      """
    end
  end

  @doc """
  A form field with its label, hint and errors. Takes a form field
  (`field={@form[:name]}`) or `name` and `value`.
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox hidden number password select text textarea url)

  attr :field, Phoenix.HTML.FormField
  attr :errors, :list, default: []
  attr :checked, :boolean
  attr :prompt, :string, default: nil
  attr :options, :list
  attr :class, :any, default: nil

  attr :rest, :global,
    include:
      ~w(autocomplete disabled inputmode max maxlength min minlength pattern placeholder readonly required rows step spellcheck)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class={["field", @class]}>
      <label class="check" for={@id}>
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <input type="checkbox" id={@id} name={@name} value="true" checked={@checked} {@rest} />
        <span>
          {@label}<span :if={@hint} class="hint" style="display:block">{@hint}</span>
        </span>
      </label>
      <p :for={msg <- @errors} class="error">{msg}</p>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class={["field", @class]}>
      <label :if={@label} for={@id}>{@label}</label>
      <select id={@id} name={@name} {@rest}>
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <span :if={@hint} class="hint">{@hint}</span>
      <p :for={msg <- @errors} class="error">{msg}</p>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class={["field", @class]}>
      <label :if={@label} for={@id}>{@label}</label>
      <textarea id={@id} name={@name} {@rest}>{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <span :if={@hint} class="hint">{@hint}</span>
      <p :for={msg <- @errors} class="error">{msg}</p>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class={["field", @class]}>
      <label :if={@label} for={@id}>{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      />
      <span :if={@hint} class="hint">{@hint}</span>
      <p :for={msg <- @errors} class="error">{msg}</p>
    </div>
    """
  end

  # --- flash -------------------------------------------------------------------

  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}
  attr :kind, :atom, values: [:info, :error]

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide(to: "##{@id}")}
      role={if @kind == :error, do: "alert", else: "status"}
      class={["flash", @kind == :error && "error"]}
    >
      <.icon name={if @kind == :error, do: "error", else: "ok"} />
      <p>{msg}</p>
      <span class="sr-only">{gettext("Dismiss")}</span>
    </div>
    """
  end

  # --- errors ------------------------------------------------------------------

  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(AlnaslWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(AlnaslWeb.Gettext, "errors", msg, opts)
    end
  end

  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
