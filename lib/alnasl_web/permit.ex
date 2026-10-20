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

  A tournament placed in several halls lends the best role in any of them,
  but only for what happens to the tournament there. An event that changes
  the hall the page is about needs the role there too; one about the whole
  tournament (removing it, its Lichess key, its rounds) needs it in the
  tournament's home hall; one about board N needs it in the hall board N
  is played in - on Live, on the board's own page, and on PGN (attaching a
  game to board N, or playing it on a simulator as board N).

  On a box with no accounts everybody is the owner of everything, and this
  lets everything through, as before there were accounts.
  """

  use Gettext, backend: AlnaslWeb.Gettext

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Alnasl.{Boards, Bridges, Placements, Tournaments}
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
    RoundLive => %{"set_view" => :viewer, "share" => :viewer, "unshare" => :viewer},
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
      "wizard_change" => :viewer,
      "wizard_edit" => :viewer,
      "wizard_cancel" => :viewer,
      "save_wizard" => :owner,
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

  # Fair play is the hall owner's alone (`Alnasl.FairPlay.Access`), which is
  # not a level of the ladder: the page and `Alnasl.FairPlay` ask it themselves,
  # for every event, so the ladder is not asked for more than a seat.
  def needed(AlnaslWeb.FairPlayLive, _event), do: :viewer

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

      # A tournament played in several halls is the business of each: the
      # highest role in any of them counts (`Alnasl.Placements.role/2`).
      # That is for what happens in one of them. What happens in a
      # particular hall needs the role in that hall as well (`halls/5`).
      level ->
        rows = refs(view, event, params, assigns)

        named =
          case rows do
            [] -> Scope.can?(scope, level, here(scope))
            rows -> Enum.all?(rows, &Placements.can?(scope, level, &1))
          end

        named and
          Enum.all?(halls(view, event, params, assigns, scope, rows, level), fn hall_id ->
            Scope.can?(scope, level, hall_id)
          end)
    end
  end

  defp here(scope), do: Scope.hall_id(scope) || Alnasl.Halls.own_id()

  # Events that change the hall the page is about, whatever they name: an
  # arbiter of the Open in the annex is not one in the main hall because
  # the Open is played there too.
  @here_events %{
    SetupLive =>
      ~w(assign_tables add_code add_bridge bridge_command remove_bridge save_wizard wizard_mark),
    BoardsLive => ~w(link_in_order clear_remaps swap)
  }
  @here_everywhere ~w(seat_tables)

  # Events about the whole tournament, credentials included: its home hall
  # (`tournaments.hall_id`, the own hall for a row from before halls) says,
  # not the best role in any hall it borrowed tables in.
  @home_events %{
    SetupLive => ~w(remove_tournament save_lichess clear_lichess auto_start),
    RoundLive => ~w(next_round follow make_current)
  }

  # Events about one board of a tournament, named by its number: the hall
  # that board is played in says.
  @board_events %{RoundLive => ~w(result new_game send_this)}

  # The halls an event needs the role in besides the rows it names.
  defp halls(_view, _event, _params, _assigns, _scope, _rows, :viewer), do: []

  defp halls(view, event, params, assigns, scope, rows, _level) do
    here =
      if event in @here_everywhere or event in Map.get(@here_events, view, []),
        do: [here(scope)],
        else: []

    home =
      if event in Map.get(@home_events, view, []),
        do: for(%Tournaments.Tournament{} = t <- rows, do: Alnasl.Halls.of(t)),
        else: []

    here ++ home ++ code_halls(view, event, params) ++ board_halls(view, event, params, assigns)
  end

  # "Use this code for that tournament" re-points a tournament, which another
  # hall may own, to another code: the role in the tournament's home hall is
  # needed, whatever the hall of the code is.
  defp code_halls(SetupLive, "use_code", params) do
    with id when is_integer(id) <- int(params["id"]),
         remote when is_integer(remote) <- int(params["remote"]),
         %Alnasl.Tournaments.Link{} = link <- Tournaments.get_link(id),
         %{"tournament_id" => tid} <-
           Alnasl.OpenPairings.Duplicates.elsewhere(link)[to_string(remote)],
         %Tournaments.Tournament{} = t <- Tournaments.get(tid) do
      [Alnasl.Halls.of(t)]
    else
      _none -> []
    end
  end

  defp code_halls(_view, _event, _params), do: []

  defp board_halls(RoundLive, event, params, _assigns) do
    if event in @board_events[RoundLive] do
      with id when is_integer(id) <- int(params["t"] || params["tid"]),
           %Tournaments.Tournament{} = t <- Tournaments.get(id),
           n when is_integer(n) <- int(params["board"]) do
        [board_hall(t, n)]
      else
        # The tile's button without a tournament is about the box's own.
        _none ->
          case int(params["board"]) do
            n when is_integer(n) -> [board_hall(Tournaments.default(), n)]
            _none -> []
          end
      end
    else
      []
    end
  end

  # PGN: a game attached to board N, or played on a simulator as board N,
  # is board N's business - the page holds the tournament and the number,
  # the event only says which game.
  defp board_halls(PgnLive, event, params, %{tid: tid} = assigns)
       when event in ~w(ask_attach attach simulate simulate_all) do
    case Tournaments.get(tid) do
      %Tournaments.Tournament{} = t ->
        event |> PgnLive.board_numbers(params, assigns) |> Enum.map(&board_hall(t, &1))

      nil ->
        []
    end
  end

  # The board's own page: every change is to that one board.
  defp board_halls(GameLive, _event, _params, %{tournament: %Tournaments.Tournament{} = t, no: n})
       when is_integer(n),
       do: [board_hall(t, n)]

  defp board_halls(_view, _event, _params, _assigns), do: []

  # Board n is played where its placement puts it; a board beyond every
  # placement is the home hall's business.
  defp board_hall(tournament, n) do
    case Placements.place_of(tournament, n) do
      {hall_id, _table} -> hall_id
      nil -> Alnasl.Halls.of(tournament)
    end
  end

  @doc """
  The rows an event acts on: tournaments, boards, bridges and codes named
  in its parameters, and the tournament the page itself is about.
  Unknown ids name nothing (the page says "not found" by itself).

  Fair play names none: its ids are grants, uploads and rounds, not
  tournaments, and the page asks the owner (or the grant) itself.
  """
  def refs(AlnaslWeb.FairPlayLive, _event, _params, _assigns), do: []

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

    reached(view, event, named ++ page ++ implicit(view, event, params, assigns))
  end

  # "Also play it in this hall": offered to an arbiter of the hall whose own
  # code reaches the tournament, who may hold no role for it yet. Holding
  # the code is the authorisation; the role in the hall named is still
  # checked.
  defp reached(SetupLive, "placement_add", rows) do
    case Enum.find(rows, &match?(%Alnasl.Halls.Hall{}, &1)) do
      %Alnasl.Halls.Hall{id: hall_id} ->
        Enum.reject(rows, &(match?(%Tournaments.Tournament{}, &1) and reached?(&1, hall_id)))

      nil ->
        rows
    end
  end

  defp reached(_view, _event, rows), do: rows

  # Through a second code only on the same pairing program: a listing from
  # another server says what it likes about ids and versions, and holding a
  # code there proves nothing about the tournament here.
  defp reached?(%Tournaments.Tournament{} = t, hall_id) do
    Enum.any?(Tournaments.links(), fn link ->
      Alnasl.Halls.of(link) == hall_id and
        (t.link_id == link.id or
           Enum.any?(
             Alnasl.OpenPairings.Duplicates.shared(link),
             &(&1.tournament.id == t.id and
                 Alnasl.OpenPairings.Duplicates.same_server?(link.root, &1.through.root))
           ))
    end)
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

  # Two boards changing places.
  defp ref(BoardsLive, "swap", key, value) when key in ["a", "b"],
    do: with(id when is_integer(id) <- int(value), do: Boards.get(id))

  defp ref(RecordingsLive, _event, "board", value),
    do: with(id when is_integer(id) <- int(value), do: Boards.get(id))

  # The frame's "put this board in that tournament".
  defp ref(_view, "seat_put", "board", value),
    do: with(id when is_integer(id) <- int(value), do: Boards.get(id))

  defp ref(SetupLive, event, "id", value)
       when event in ~w(test_link use_code retry_link remove_link),
       do: with(id when is_integer(id) <- int(value), do: Tournaments.get_link(id))

  # The hall a tournament is placed in, or is to be: an arbiter there, as
  # well as for the tournament.
  defp ref(SetupLive, event, "hall", value)
       when event in ~w(placement_add placement_save placement_remove),
       do: with(id when is_integer(id) <- int(value), do: Alnasl.Halls.get(id))

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
