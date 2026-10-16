defmodule AlnaslWeb.SeatingComponents do
  @moduledoc """
  The pieces that say which boards play in which tournament, and let the
  arbiter put one right where it is: the line under the bar on every page
  (a board outside, the step the box took, the question that is open), and
  the buttons on the Boards page. The events are answered once, for every
  page, in `AlnaslWeb.Hall`.
  """

  use AlnaslWeb, :html

  alias Alnasl.Tournaments

  @doc """
  One of the frame's notices about seating, by `key` (`:auto`, `:outside`,
  `:ask`), from `AlnaslWeb.Status.build/1`. The frame decides which are up
  and how many are in sight (`AlnaslWeb.Layouts`). A notice names at most
  three tournaments; the rest are in Setup.
  """
  attr :key, :atom, required: true
  attr :seating, :map, required: true

  def notice(%{key: :auto} = assigns) do
    ~H"""
    <div id="auto-notice" class="banner news" role="status">
      <.icon name="ok" />
      <span>
        {ngettext(
          "The board now plays in %{name}: its table number is its board.",
          "All %{count} boards now play in %{name}: a board's table number is its board.",
          @seating.auto.count,
          name: Tournaments.title(@seating.auto.tournament) || "",
          count: @seating.auto.count
        )}
      </span>
      <span class="banner-actions">
        <button id="auto-undo" type="button" class="linkish" phx-click="seat_undo">
          {gettext("Undo")}
        </button>
        <button id="auto-ok" type="button" class="linkish" phx-click="seat_dismiss">
          {gettext("OK")}
        </button>
      </span>
    </div>
    """
  end

  def notice(%{key: :outside} = assigns) do
    ~H"""
    <div id="outside-banner" class="banner" role="status">
      <.icon name="warning" />
      <ul class="outside-list">
        <li :for={o <- @seating.outside} id={"outside-#{o.board.id}"}>
          <.outside_line entry={o} />
        </li>
      </ul>
    </div>
    """
  end

  def notice(%{key: :ask} = assigns) do
    ~H"""
    <div id="ask-banner" class="banner" role="status">
      <.icon name="warning" />
      <span>
        {gettext("Which tables play in %{names}?",
          names: few_names(Enum.map(@seating.ask, &(Tournaments.title(&1.tournament) || "")))
        )}
      </span>
      <.link id="ask-banner-link" navigate={~p"/setup#seat-ask"}>{gettext("Answer in Setup")}</.link>
    </div>
    """
  end

  @doc """
  At most three names, joined, and how many more there are: "A, B, C and
  2 more". A notice is a line, not a list of every tournament the links
  brought.
  """
  def few_names(names, max \\ 3, joiner \\ ", ") do
    {shown, rest} = Enum.split(names, max)
    text = Enum.join(shown, joiner)

    case length(rest) do
      0 -> text
      n -> gettext("%{names} and %{count} more", names: text, count: n)
    end
  end

  @doc "One board that plays in no linked tournament, in words, with the way to put it right."
  attr :entry, :map, required: true

  attr :scope, :string,
    default: "",
    doc: "put in front of the ids, so the same line can stand twice on a page"

  def outside_line(assigns) do
    ~H"""
    <span class="outside-text">
      {outside_text(@entry)}
    </span>
    <span class="outside-actions">
      <%= for t <- Enum.take(@entry.targets, 3) do %>
        <button
          id={"#{@scope}put-#{@entry.board.id}-#{t.tournament.id}"}
          type="button"
          class="linkish"
          phx-click="seat_put"
          phx-value-board={@entry.board.id}
          phx-value-t={t.tournament.id}
          phx-value-mode="adopt"
        >
          {put_label(@entry, t)}
        </button>
        <button
          :if={@entry.game}
          id={"#{@scope}put-fresh-#{@entry.board.id}-#{t.tournament.id}"}
          type="button"
          class="linkish"
          phx-click="seat_put"
          phx-value-board={@entry.board.id}
          phx-value-t={t.tournament.id}
          phx-value-mode="fresh"
        >
          {gettext("Put it there and start fresh")}
        </button>
      <% end %>
      <.link
        :if={length(@entry.targets) > 3}
        id={"#{@scope}put-more-#{@entry.board.id}"}
        navigate={~p"/setup#setup-tournaments"}
      >
        {gettext("The other %{count} in Setup", count: length(@entry.targets) - 3)}
      </.link>
    </span>
    """
  end

  @doc "The sentence about one board outside: its name and the tournaments it could play in."
  def outside_text(%{board: board, targets: targets, game: game}) do
    names = targets |> Enum.map(&(Tournaments.title(&1.tournament) || "")) |> few_names(3, " / ")

    base =
      gettext("%{name} is not playing in %{tournament}.", name: board.name, tournament: names)

    if game,
      do:
        base <>
          " " <>
          gettext("A game is under way on it (%{n} moves).",
            n: length(Alnasl.Games.plies(game))
          ),
      else: base
  end

  defp put_label(%{game: nil}, %{tournament: t}) do
    if one_target?(t),
      do: gettext("Put it there"),
      else: gettext("Put it in %{name}", name: Tournaments.title(t) || "")
  end

  defp put_label(%{game: _game}, %{round: round, board_no: no, tournament: t})
       when is_integer(no) do
    gettext("Put it there: these moves are board %{n} of round %{r}%{name}",
      n: no,
      r: round,
      name: pairing_names(t, round, no)
    )
  end

  defp put_label(_entry, _target), do: gettext("Put it there")

  defp one_target?(_t), do: length(Alnasl.Seating.linked()) == 1

  defp pairing_names(t, round, no) do
    case Tournaments.board(t.id, round, no) do
      %{white: w, black: b} when is_binary(w) and is_binary(b) -> " (#{w} - #{b})"
      _none -> ""
    end
  end

  @doc "The question a code leaves: which tables play in this tournament? One form each."
  attr :ask, :list, required: true

  def ask(assigns) do
    ~H"""
    <div :if={@ask != []} id="seat-ask" class="callout" role="status">
      <b>{gettext("Which tables play in %{names}?",
        names: Enum.map_join(@ask, ", ", &(Tournaments.title(&1.tournament) || ""))
      )}</b>
      <p class="note">
        {gettext(
          "The box's boards are not in these tournaments yet, so nothing they read is sent there. Say which table numbers play in which; the first table is the tournament's board 1."
        )}
      </p>
      <.form
        :for={a <- @ask}
        for={to_form(%{"id" => a.tournament.id, "from" => a.from, "to" => a.to}, as: :seat)}
        id={"seat-form-#{a.tournament.id}"}
        phx-submit="seat_tables"
        class="row"
        style="align-items:flex-end"
      >
        <input type="hidden" name="seat[id]" value={a.tournament.id} />
        <b>{Tournaments.title(a.tournament)}</b>
        <div class="field">
          <label for={"seat-from-#{a.tournament.id}"}>{gettext("Tables from")}</label>
          <input
            id={"seat-from-#{a.tournament.id}"}
            name="seat[from]"
            type="number"
            inputmode="numeric"
            min="1"
            max="9999"
            value={a.from}
            class="input table-no"
          />
        </div>
        <div class="field">
          <label for={"seat-to-#{a.tournament.id}"}>{gettext("to")}</label>
          <input
            id={"seat-to-#{a.tournament.id}"}
            name="seat[to]"
            type="number"
            inputmode="numeric"
            min="1"
            max="9999"
            value={a.to}
            class="input table-no"
          />
        </div>
        <.button id={"seat-submit-#{a.tournament.id}"} small variant="primary" type="submit">
          {gettext("These tables play here")}
        </.button>
        <.button
          id={"seat-decline-#{a.tournament.id}"}
          small
          type="button"
          phx-click="seat_decline"
          phx-value-t={a.tournament.id}
        >
          {gettext("None of this box's boards")}
        </.button>
      </.form>
    </div>
    """
  end
end
