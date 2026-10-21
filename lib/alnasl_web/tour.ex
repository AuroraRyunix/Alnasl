defmodule AlnaslWeb.Tour do
  @moduledoc """
  The guided tour: a dozen stops through the real pages, in the order a hall
  is set up and played in, each a few sentences pointing at the thing it is
  about. The pages do the explaining; the tour only says where to look.

  ## The steps

  `steps/1` is a pure function of who is asking (`%{role, fair_play?,
  hall_id}`), so a test can ask it what a viewer is shown without drawing a
  page. A step a role cannot use is not in the list, rather than shown and
  refused: a viewer is not walked to the bridges it may not add, and fair
  play is shown to the hall's owner and to nobody else
  (`Alnasl.FairPlay.Access`).

  Each step names its page (`path`), the element it points at (`anchor`,
  CSS selectors, the first one on show wins), what to point at instead when
  that is not there yet (`fallback`, with `empty` saying what will appear),
  and its manual section. The browser does the pointing
  (`AlnaslWeb.Components.Tour`).

  ## What is remembered

  Whether the tour was offered and what became of it: `nil` (never offered),
  "started", "dismissed" or "finished". Only `nil` gets the offer, so nobody
  is asked twice; "Take the tour" in the account menu is always there. An
  account keeps it on its row (`users.tour`); a box without accounts keeps it
  in its settings, once for the box, which is all a box without accounts can
  tell apart.

  Where the tour is (step 4 of 9) is the browser tab's own business
  (`sessionStorage`): it moves with the person from page to page and is gone
  with the tab, which is what a tour in progress should do.
  """

  use Gettext, backend: AlnaslWeb.Gettext

  alias Alnasl.{Accounts, Settings}
  alias Alnasl.Accounts.Scope

  @states ~w(started dismissed finished)
  @rank %{viewer: 1, arbiter: 2, owner: 3}
  @role_rank %{"viewer" => 1, "arbiter" => 2, "owner" => 3}

  @doc """
  The steps for `who`, in order: `%{key, path, anchor, fallback, title, body,
  empty, manual}`. `who` is `%{role: "owner" | "arbiter" | "viewer" | nil,
  fair_play?: boolean, hall_id: integer | nil}`.
  """
  def steps(%{} = who) do
    for step <- all(who.hall_id), allowed?(step.need, who), do: Map.delete(step, :need)
  end

  @doc "The keys of `steps/1`, in order: what a test compares."
  def keys(who), do: Enum.map(steps(who), & &1.key)

  @doc "Who the scope is, for `steps/1`: the role in the hall on show, and fair play's own answer."
  def who(%Scope{} = scope) do
    hall_id = Scope.hall_id(scope) || Alnasl.Halls.own_id()

    %{
      role: Scope.role(scope, hall_id),
      fair_play?: Alnasl.FairPlay.Access.owner?(scope, hall_id),
      hall_id: hall_id
    }
  end

  # Fair play's own rule (`Alnasl.FairPlay.Access`), and the owner's role
  # besides: a step is never shown to somebody the ladder would not let in.
  defp allowed?(:fair_play, who), do: who.fair_play? == true and who.role == "owner"

  defp allowed?(need, %{role: role}) when is_map_key(@role_rank, role),
    do: @role_rank[role] >= @rank[need]

  defp allowed?(_need, _who), do: false

  defp all(hall_id) do
    [
      %{
        key: "places",
        need: :viewer,
        path: "/",
        anchor: ["#nav", "#tab-bar"],
        fallback: [],
        title: gettext("The places"),
        body:
          gettext(
            "Every page is here, in the order a round asks for them: play, send, manage, look back. On a phone they are in the bar along the bottom, and More holds the rest."
          ),
        empty: nil,
        manual: "/help/getting-started#what-alnasl-does"
      },
      %{
        key: "wizard",
        need: :owner,
        path: "/setup/wizard",
        anchor: ["#wizard-steps"],
        fallback: ["#wizard-form", "#setup-wizard"],
        title: gettext("The setup wizard"),
        body:
          gettext(
            "Say what the hall looks like and the wizard lists the steps for exactly that hall, each with a button to where it is done. It ticks a step off when the thing is really there, not when somebody presses Next."
          ),
        empty:
          gettext(
            "Answer the questions first; the steps for your hall appear here once you have."
          ),
        manual: "/help/getting-started#setup-wizard"
      },
      %{
        key: "bridges",
        need: :owner,
        path: "/halls/#{hall_id}/bridges",
        anchor: ["#hall-bridges"],
        fallback: [],
        title: gettext("Bridges"),
        body:
          gettext(
            "Boards in another room, or anywhere on the server, come through an Arkab bridge. Make a join code here, give it to Arkab, and its boards arrive in this hall."
          ),
        empty: nil,
        manual: "/help/bridges#joining"
      },
      %{
        key: "connections",
        need: :arbiter,
        path: "/setup/connections",
        anchor: ["#setup-connections"],
        fallback: [],
        title: gettext("Connect OpenPairings"),
        body:
          gettext(
            "A connect code from OpenPairings (Settings, Live boards) brings a tournament here with its pairings, rounds and results page. Paste it here, or connect your OpenPairings account for all of them at once."
          ),
        empty: nil,
        manual: "/help/openpairings-and-openresults#linking-to-openpairings"
      },
      %{
        key: "tournaments",
        need: :arbiter,
        path: "/setup/tournaments",
        anchor: ["#tournaments > li"],
        fallback: ["#tournaments-empty", "#setup-tournaments"],
        title: gettext("Tournaments and tables"),
        body:
          gettext(
            "Each tournament that came with a connection has a line here. Open it to say which tables it plays on, and whether its rounds start by themselves."
          ),
        empty:
          gettext(
            "No tournament yet: each one a connection brings gets a line here, to open for its tables."
          ),
        manual: "/help/accounts-and-halls#placements"
      },
      %{
        key: "boards",
        need: :viewer,
        path: "/boards",
        anchor: ["#boards-table"],
        fallback: ["#boards-empty"],
        title: gettext("Boards"),
        body:
          gettext(
            "Every board the hall knows, plugged in here or arriving through a bridge, with its table number and what it sees."
          ),
        empty:
          gettext(
            "No boards yet. Plug a chain into the box or connect a bridge, and each board gets a line here."
          ),
        manual: "/help/boards-and-ports#the-boards-page"
      },
      %{
        key: "numbering",
        need: :arbiter,
        path: "/boards",
        anchor: ["#number-by-touch"],
        fallback: [],
        title: gettext("Table numbers"),
        body:
          gettext(
            "A board has to know which table it is. Walk the hall and touch each board in table order, or type the numbers in the list."
          ),
        empty: nil,
        manual: "/help/boards-and-ports#giving-numbers"
      },
      %{
        key: "ready",
        need: :viewer,
        path: "/boards",
        anchor: ["#round-checks"],
        fallback: [],
        title: gettext("Ready for the round?"),
        body:
          gettext(
            "Before the round: does every board answer, have its table, and show the starting position? What is not ready is listed, board by board."
          ),
        empty:
          gettext(
            "The check appears here as soon as there is a board to check: one line for everything that is not ready yet."
          ),
        manual: "/help/getting-started#before-the-round"
      },
      %{
        key: "live",
        need: :viewer,
        path: "/",
        anchor: ["[id^='tile-wrap-']"],
        fallback: ["#live-empty"],
        title: gettext("Live"),
        body:
          gettext(
            "The screen during play: a tile per board, with the position, the clocks and anything that needs you. Press a tile for the board's own page, where corrections and the result are."
          ),
        empty:
          gettext(
            "Once a board plays in a round, its tile appears here: the position, the clocks and any alarm."
          ),
        manual: "/help/following-games#the-round-page"
      },
      %{
        key: "results",
        need: :viewer,
        path: "/outbox",
        anchor: ["#link-panel"],
        fallback: [],
        title: gettext("Results"),
        body:
          gettext(
            "What went to the results site and OpenPairings, and what is waiting. Without internet nothing is lost: it waits here and goes out in order."
          ),
        empty: nil,
        manual: "/help/recording-and-troubleshooting#the-outbox"
      },
      %{
        key: "fair_play",
        need: :fair_play,
        path: "/fair-play",
        anchor: ["#fair-play-index"],
        fallback: [],
        title: gettext("Fair play"),
        body:
          gettext(
            "Screening numbers for your halls' games, for the owner only. A number is a reason to look closer, never a verdict."
          ),
        empty: nil,
        manual: "/help/fair-play#what-it-is"
      },
      %{
        key: "help",
        need: :viewer,
        path: "/help",
        anchor: ["#account-button"],
        fallback: [],
        title: gettext("That is the tour"),
        body:
          gettext(
            "The manual is here, chapter by chapter, and each page has a question mark beside its title that opens the right section. This tour waits in the account menu, under Take the tour."
          ),
        empty: nil,
        manual: "/help/getting-started#the-tour"
      }
    ]
  end

  # --- what is remembered -----------------------------------------------------

  @doc "What became of the tour for the scope: `nil`, \"started\", \"dismissed\" or \"finished\"."
  def state(%Scope{user: %{tour: tour}}), do: tour
  def state(%Scope{open?: true}), do: valid(Settings.get("tour"))
  def state(_scope), do: nil

  defp valid(state) when state in @states, do: state
  defp valid(_other), do: nil

  @doc "Notes what became of the tour; \"finished\" is not undone by a later skip."
  def put(%Scope{} = scope, state) when state in @states do
    case {state(scope), state} do
      {"finished", "dismissed"} -> scope
      {"finished", "started"} -> scope
      {_before, state} -> store(scope, state)
    end
  end

  defp store(%Scope{user: %Accounts.User{} = user} = scope, state) do
    case Accounts.set_tour(user, state) do
      {:ok, user} -> %{scope | user: user}
      {:error, _changeset} -> scope
    end
  end

  defp store(%Scope{open?: true} = scope, state) do
    Settings.put("tour", state)
    scope
  end

  defp store(scope, _state), do: scope

  @doc "Puts the tour on a fresh scope (`AlnaslWeb.Hall`): what became of it, not started here yet."
  def mount(%Scope{} = scope), do: %{scope | tour: %{state: state(scope), run: 0}}
  def mount(scope), do: scope

  @doc "Is the tour to be offered: never offered before, and not running on this page."
  def offer?(%Scope{tour: %{state: nil, run: 0}}), do: true
  def offer?(_scope), do: false

  # --- the events -------------------------------------------------------------

  @doc """
  The `handle_event` hook every page has (`AlnaslWeb.Hall`): "tour_start"
  (the offer's button, or the account menu's), "tour_dismiss" (Skip, Escape,
  the offer's Not now) and "tour_finish" (the last step's Done).
  """
  def event("tour_start", _params, socket) do
    scope = socket.assigns.current_scope |> put("started") |> carry(socket)
    run = scope.tour.run + 1

    {:halt,
     Phoenix.Component.assign(socket, :current_scope, %{
       scope
       | tour: %{state: state(scope), run: run}
     })}
  end

  def event("tour_dismiss", _params, socket), do: {:halt, answer(socket, "dismissed")}
  def event("tour_finish", _params, socket), do: {:halt, answer(socket, "finished")}
  def event(_event, _params, socket), do: {:cont, socket}

  defp answer(socket, word) do
    scope = socket.assigns.current_scope |> put(word) |> carry(socket)

    Phoenix.Component.assign(socket, :current_scope, %{
      scope
      | tour: %{scope.tour | state: state(scope)}
    })
  end

  # `put/2` hands back a scope with the user changed; the tour's own map is
  # the socket's, and is kept.
  defp carry(scope, socket) do
    %{scope | tour: socket.assigns.current_scope.tour || %{state: nil, run: 0}}
  end
end
