defmodule AlnaslWeb.Permit do
  @moduledoc """
  Who may press what. Every event a page receives passes here first
  (attached by `AlnaslWeb.Hall`), before the page sees it.

  An event needs a level (`needed/2`): `:viewer` (it only changes what this
  browser shows), `:arbiter` (everything that changes a game, a board, a
  round or a link - the default for an event not named here, so that a
  button added later is closed until someone says otherwise), `:owner`
  (bridges, people), or `:admin` (the box itself: its PIN, its network,
  its updates, the tracker, the outbox's switches).

  And it needs it *where it acts*: in the hall of every tournament, board,
  bridge or code the event names (`refs/4`), and in the hall the page is
  about when it names none. So an arbiter in one hall who sends another
  hall's board id with a hand-made event is refused like a viewer.

  On a box with no accounts everybody is the owner of everything, and this
  lets everything through, as before there were accounts.
  """

  use Gettext, backend: AlnaslWeb.Gettext

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Alnasl.{Boards, Bridges, Halls, Tournaments}
  alias Alnasl.Accounts.Scope

  alias AlnaslWeb.{
    BoardsLive,
    GameLive,
    LogLive,
    OutboxLive,
    PgnLive,
    RecordingsLive,
    RoundLive,
    SetupLive
  }

  @everywhere %{"live_ping" => :viewer, "phone_signin" => :viewer, "search" => :viewer}

  @levels %{
    RoundLive => %{},
    GameLive => %{
      "goto" => :viewer,
      "nav" => :viewer,
      "review" => :viewer,
      "pick" => :viewer,
      "choice_back" => :viewer,
      "choice_close" => :viewer
    },
    BoardsLive => %{
      "change_add" => :viewer,
      "pick_tournament" => :viewer,
      "find_toggle" => :viewer,
      "show_me" => :viewer,
      "stop_seeking" => :viewer,
      "round" => :viewer,
      "rescan" => :viewer
    },
    LogLive => %{"filter" => :viewer, "clear_filter" => :viewer},
    RecordingsLive => %{"refresh" => :viewer, "close_report" => :viewer},
    PgnLive => %{
      "validate" => :viewer,
      "paste" => :viewer,
      "upload" => :viewer,
      "clear" => :viewer,
      "pick_tournament" => :viewer,
      "round" => :viewer,
      "target" => :viewer,
      "compare" => :viewer,
      "cancel_attach" => :viewer
    },
    OutboxLive => %{"dest_toggle" => :admin, "prune" => :admin},
    SetupLive => %{
      "pick_lichess" => :viewer,
      "add_bridge" => :owner,
      "bridge_command" => :owner,
      "remove_bridge" => :owner,
      "save_box" => :admin,
      "save_pin" => :admin,
      "clear_pin" => :admin,
      "set_listen" => :admin,
      "save_update_mode" => :admin,
      "check_update" => :admin,
      "update_start" => :admin,
      "update_cancel" => :admin,
      "update_apply" => :admin,
      "set_autostart" => :admin,
      "save_tracker" => :admin,
      "preset_tracker" => :admin,
      "reset_tracker" => :admin
    }
  }

  # The notices of a newer version, answered by the frame of every page.
  @frame %{"update_later" => :admin, "update_never" => :admin}

  @doc "The level `event` needs on `view`."
  # The halls page checks per hall itself: one account can be a viewer in
  # one hall and the owner of the next, on the same page.
  def needed(AlnaslWeb.HallsLive, _event), do: :viewer

  def needed(view, event) do
    Map.get(@everywhere, event) ||
      Map.get(@frame, event) ||
      get_in(@levels, [view, event]) ||
      :arbiter
  end

  @doc "The `handle_event` hook: `{:cont, socket}` when allowed, `{:halt, socket}` with a word when not."
  def check(event, params, socket) do
    scope = socket.assigns[:current_scope]

    if allowed?(scope, socket.view, event, params, socket.assigns) do
      {:cont, socket}
    else
      {:halt,
       put_flash(
         socket,
         :error,
         gettext("Your role in this hall lets you follow the games, not change them.")
       )}
    end
  end

  @doc false
  def allowed?(%Scope{open?: true}, _view, _event, _params, _assigns), do: true
  def allowed?(nil, _view, _event, _params, _assigns), do: false

  def allowed?(%Scope{} = scope, view, event, params, assigns) do
    case needed(view, event) do
      :admin ->
        Scope.can?(scope, :admin)

      level ->
        halls =
          case refs(view, event, params, assigns) do
            [] -> [Scope.hall_id(scope)]
            rows -> Enum.map(rows, &Halls.of/1)
          end

        Enum.all?(halls, &Scope.can?(scope, level, &1))
    end
  end

  @doc """
  The rows an event acts on: tournaments, boards, bridges and codes named
  in its parameters, and the tournament the page itself is about.
  Unknown ids name nothing (the page says "not found" by itself).
  """
  def refs(view, event, params, assigns) do
    named =
      for {key, value} <- flatten(params),
          row = ref(view, event, key, value),
          do: row

    page =
      for key <- [:tournament, :tid],
          value = assigns[key],
          row = page_tournament(value),
          do: row

    named ++ page ++ implicit(view, event, params, assigns)
  end

  # What an event acts on without naming it: the box's own tournament or
  # hall, where the page falls back to it.
  @own_hall_events ~w(seat_undo seat_dismiss)

  defp implicit(_view, event, _params, _assigns) when event in @own_hall_events,
    do: [Tournaments.default()]

  # A tile's button without a tournament is about the box's own.
  defp implicit(RoundLive, _event, params, _assigns) do
    if Map.has_key?(params, "t") or Map.has_key?(params, "tid"),
      do: [],
      else: [Tournaments.default()]
  end

  # The box's own ports, and the walk along them, are the own hall's.
  defp implicit(BoardsLive, event, _params, _assigns) when event in ~w(add read_as_loop),
    do: [Tournaments.default()]

  defp implicit(AlnaslWeb.WalkLive, _event, _params, _assigns), do: [Tournaments.default()]

  defp implicit(SetupLive, "save_server", _params, _assigns), do: [Tournaments.default()]

  defp implicit(SetupLive, event, _params, %{lichess: %Tournaments.Tournament{} = t})
       when event in ~w(save_lichess clear_lichess),
       do: [t]

  defp implicit(_view, _event, _params, _assigns), do: []

  defp page_tournament(%Tournaments.Tournament{} = t), do: t
  defp page_tournament(id) when is_integer(id), do: Tournaments.get(id)
  defp page_tournament(_other), do: nil

  # Parameters nested one level (forms: `%{"tables" => %{"id" => ...}}`)
  # are looked at as well, under their own key.
  defp flatten(params) when is_map(params) do
    Enum.flat_map(params, fn
      {_form, %{} = inner} -> Enum.to_list(inner)
      pair -> [pair]
    end)
  end

  defp flatten(_params), do: []

  defp ref(_view, _event, key, value) when key in ["t", "tid", "tournament_id"],
    do: with(id when is_integer(id) <- int(value), do: Tournaments.get(id))

  defp ref(_view, _event, "board_id", value),
    do: with(id when is_integer(id) <- int(value), do: Boards.get(id))

  defp ref(BoardsLive, _event, "id", value),
    do: with(id when is_integer(id) <- int(value), do: Boards.get(id))

  defp ref(RecordingsLive, _event, "board", value),
    do: with(id when is_integer(id) <- int(value), do: Boards.get(id))

  # The frame's "put this board in that tournament".
  defp ref(_view, "seat_put", "board", value),
    do: with(id when is_integer(id) <- int(value), do: Boards.get(id))

  defp ref(SetupLive, event, "id", value)
       when event in ~w(test_link use_code retry_link remove_link),
       do: with(id when is_integer(id) <- int(value), do: Tournaments.get_link(id))

  defp ref(SetupLive, event, "id", value) when event in ~w(remove_bridge bridge_command),
    do: with(id when is_integer(id) <- int(value), do: Bridges.get(id))

  defp ref(_view, _event, "id", value) do
    # Elsewhere an "id" in a form of tables or seats is a tournament's.
    with id when is_integer(id) <- int(value), do: Tournaments.get(id)
  end

  defp ref(_view, _event, _key, _value), do: nil

  defp int(value) when is_integer(value), do: value

  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _other -> nil
    end
  end

  defp int(_value), do: nil
end
