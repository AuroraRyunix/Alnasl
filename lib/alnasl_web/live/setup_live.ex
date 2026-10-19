defmodule AlnaslWeb.SetupLive do
  @moduledoc """
  First run, and whenever something changes. Split into sections, each its
  own address (`/setup/wizard`, `/setup/tournaments`, ...): the edition
  and the role decide which exist (`sections/1`); a section the program
  cannot use is absent, not greyed. What the sections hold: which tournaments the box
  serves - a connect code from OpenPairings brings each with its pairings
  and its results page - which tables play in which, the results page of
  the box's own tournament, a Lichess round per tournament; the box's name
  and language; a PIN for browsers on other machines; how patient the
  tracker is.

  The first section is the Setup wizard (`AlnaslWeb.WizardComponents`,
  `Alnasl.Wizard`): what the hall looks like, then the steps for it, each
  ticked by what is really there. Until every step is, `/setup` opens on it
  and an address that leads nowhere leads there; after that, on
  Tournaments, which is where the work is once the hall is set up.

  "Test connection" really asks - the pairing program, or the results
  server with what is in the form (saved or not) - and says in words which
  step failed and why.

  A connect code is a secret like the relay key: once added it is never
  shown again, only where it leads and its first and last characters.

  The relay key is a secret: once saved, only its first and last characters
  are ever shown again. Leaving the field empty keeps the key that is stored.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{
    Autostart,
    Boards,
    Destination,
    Listen,
    Log,
    OpenPairings,
    OpenResults,
    ResultsSite,
    Seating,
    Settings,
    Tournaments,
    Tracker,
    Updates,
    Wizard
  }

  alias Alnasl.Destination.{LichessApi, LichessBroadcast}
  alias Alnasl.OpenPairings.Duplicates

  alias AlnaslWeb.{
    Access,
    DestinationWords,
    Hall,
    LinkWords,
    SeatingComponents,
    Status,
    WizardComponents,
    Words
  }

  @tracker_fields ~w(settle_ms castle_hold_ms promotion_hold_ms takeback_settle_ms transient_ms lifted_ms search_depth)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Tournaments.subscribe()
      # The wizard's ticks: a bridge that connects, a board that arrives.
      Alnasl.Bridges.subscribe()
      Boards.subscribe()
    end

    {:ok,
     socket
     |> assign(page_title: gettext("Setup"), checks: nil, testing?: false)
     |> assign(lichess_checks: nil, lichess_testing?: false)
     |> assign(link_tests: %{}, link_testing: nil, lichess_tid: Tournaments.default_id())
     |> assign(code_form: to_form(%{"code" => ""}, as: :link), code_key: 0)
     |> assign(update_step: nil, update_games: [], update_looked: nil)
     |> assign(section: :tournaments, open: MapSet.new(), search: "")
     |> assign(show_rest?: false, show_quiet?: false, adding?: false)
     |> assign(wizard_editing?: false, wizard_params: nil, wizard_due?: false)
     |> load()}
  end

  # Which section, and which tournament is opened (`?open=3`, for a link
  # that leads to one). A section this edition or role has not got is not
  # drawn, and its address leads to the first one.
  @impl true
  def handle_params(params, _uri, socket) do
    slug = params["section"] || landing(socket.assigns)

    case Enum.find(sections(socket.assigns), &(&1.slug == slug)) do
      nil ->
        {:noreply, push_navigate(socket, to: "/setup/" <> landing(socket.assigns))}

      %{key: key} ->
        open =
          case Integer.parse(to_string(params["open"])) do
            {id, ""} -> MapSet.put(socket.assigns.open, id)
            _none -> socket.assigns.open
          end

        {:noreply, assign(socket, section: key, open: open)}
    end
  end

  @doc """
  The sections of the page this edition and this account have, in order:
  `%{key, slug, label}`. A box has Access (the PIN, the hall's network, the
  phone) and Updates; the server has neither. The box itself (its name, the
  tracker, updates) is an admin's; Results and Lichess are the own hall's.
  """
  def sections(a) do
    [
      %{key: :wizard, slug: "wizard", label: gettext("Setup wizard")},
      %{key: :tournaments, slug: "tournaments", label: gettext("Tournaments")},
      %{key: :connections, slug: "connections", label: gettext("Connections")},
      a.own_hall? && %{key: :results, slug: "results", label: gettext("Results and Lichess")},
      %{
        key: :this_box,
        slug: "this-box",
        label: if(a.server?, do: gettext("This server"), else: gettext("This box"))
      },
      not a.server? && %{key: :access, slug: "access", label: gettext("Access")},
      (a.box_admin? and not a.server?) &&
        %{key: :updates, slug: "updates", label: gettext("Updates")},
      a.box_admin? && %{key: :advanced, slug: "advanced", label: gettext("Advanced")}
    ]
    |> Enum.filter(& &1)
  end

  @doc """
  Where `/setup` opens: the wizard while a step of it is not done (or it
  was never answered), Tournaments once the hall is set up.
  """
  def landing(%{wizard: %{complete?: true}}), do: "tournaments"
  def landing(_assigns), do: "wizard"

  # The hall the pages are about (the box's own on a box without accounts).
  defp here(socket),
    do: Alnasl.Accounts.Scope.hall_id(socket.assigns.current_scope) || Alnasl.Halls.own_id()

  defp load(socket) do
    s =
      Settings.get_many(
        ~w(box_name locale auto_suggest new_game_on_setup capture_cap_mb clock_heartbeat_s tracker)
      )

    own = Tournaments.default()
    scope = socket.assigns.current_scope
    tournaments = Alnasl.Halls.here(scope, Tournaments.list())
    links = Alnasl.Halls.here(scope, Tournaments.links())
    # The tournament whose Lichess round the card is about.
    lichess = Enum.find(tournaments, own, &(&1.id == socket.assigns.lichess_tid))
    boards = Enum.frequencies_by(Alnasl.Halls.here(scope, Boards.list()), & &1.tournament_id)

    tracker =
      Map.merge(
        Map.new(Tracker.defaults(), fn {k, v} -> {Atom.to_string(k), v} end),
        s["tracker"] || %{}
      )

    preset = Tracker.preset(:bullet)

    assign(socket,
      preset: preset,
      defaults: Tracker.defaults(),
      fast?: Enum.all?(preset, fn {key, value} -> tracker[Atom.to_string(key)] == value end),
      server_form:
        to_form(
          %{"server_url" => own.server_url, "tournament" => own.slug, "relay_key" => ""},
          as: :server
        ),
      box_form:
        to_form(
          %{
            "box_name" => s["box_name"],
            "locale" => s["locale"],
            "round" => own.round,
            "auto_suggest" => s["auto_suggest"],
            "new_game_on_setup" => s["new_game_on_setup"],
            "capture_cap_mb" => s["capture_cap_mb"],
            "clock_heartbeat_s" => s["clock_heartbeat_s"]
          },
          as: :box
        ),
      pin_form: to_form(%{"pin" => ""}, as: :door),
      lichess_form:
        to_form(
          %{
            "round" => lichess.lichess_round_id || "",
            "token" => "",
            "round_no" => Tournaments.lichess_round(lichess),
            "enabled" => Destination.enabled?(LichessBroadcast)
          },
          as: :lichess
        ),
      lichess_hint: Tournaments.lichess_token_hint(lichess),
      lichess_round_id: lichess.lichess_round_id,
      lichess: lichess,
      own: own,
      tournaments: tournaments,
      ranges: Map.new(tournaments, &{&1.id, Tournaments.tables(&1, here(socket))}),
      placements: Map.new(tournaments, &{&1.id, placement_rows(&1, scope)}),
      addable: Map.new(tournaments, &{&1.id, Alnasl.Placements.addable_halls(scope, &1)}),
      links: links,
      also_here: also_here(links, scope),
      connect_form:
        to_form(
          %{"address" => Alnasl.OpenPairings.Connect.default_address(here(socket)) || ""},
          as: :connect
        ),
      may_connect?: Alnasl.Accounts.Scope.can?(scope, :arbiter, here(socket)),
      board_counts: boards,
      hall_id: here(socket),
      # The box itself (its name, PIN, updates, tracker) is an admin's; the
      # box's own tournament and Lichess card are the own hall's.
      box_admin?: Alnasl.Accounts.Scope.can?(scope, :admin),
      own_hall?: here(socket) == Alnasl.Halls.own_id(),
      accounts?: Alnasl.Accounts.any?(),
      server?: Alnasl.Accounts.server?(),
      first_form: to_form(%{"email" => "", "password" => ""}, as: :user),
      tracker_form:
        to_form(
          tracker
          |> Map.take(@tracker_fields ++ ~w(takeback unseen_piece promotion_default))
          |> Map.update!("promotion_default", &to_string/1),
          as: :tracker
        ),
      key_hint: Tournaments.relay_key_hint(own),
      about: Alnasl.BoxInfo.info(),
      pin_set?: Settings.pin_set?(),
      pin_short?: Settings.pin_short?(),
      listen: Listen.chosen(),
      listen_forced: Listen.forced(),
      listening_lan?: Access.info().lan?,
      update_available: Updates.available(),
      update_mode: Updates.mode(),
      update_kind: Updates.install_kind(),
      update_result: Updates.last_result(),
      autostart?: Autostart.supported?(),
      autostart_on?: Autostart.supported?() and Autostart.enabled?()
    )
    |> assign_wizard()
  end

  # The wizard's plan, and the form of its questions: what was being typed,
  # else the answers, else the defaults.
  defp assign_wizard(socket) do
    a = socket.assigns
    plan = Wizard.plan(a.current_scope, a.hall_id, wizard_ctx(a))

    assign(socket,
      wizard: plan,
      wizard_form:
        to_form(a.wizard_params || plan.answers || Wizard.defaults(a.server?), as: :wizard),
      may_answer?: Alnasl.Accounts.Scope.can?(a.current_scope, :owner, a.hall_id)
    )
  end

  defp wizard_ctx(a), do: %{server?: a.server?, own_hall?: a.own_hall?, lan?: a.listening_lan?}

  # What is in the server form, as it would be saved.
  defp read_server(params) do
    {link_url, slug} = Settings.parse_tournament(params["tournament"])

    url =
      Settings.normalize_url(
        if(String.trim(params["server_url"] || "") == "",
          do: link_url || "",
          else: params["server_url"]
        )
      )

    key = String.trim(params["relay_key"] || "")
    {url, String.trim(slug), if(key == "", do: Tournaments.default().relay_key, else: key)}
  end

  # What is in the Lichess form, as it would be saved: `{round id | :error | "", token}`.
  defp read_lichess(params, tournament) do
    text = String.trim(params["round"] || "")

    round =
      case {text, LichessApi.parse_round(text)} do
        {"", _} -> ""
        {_text, {:ok, id}} -> id
        {_text, :error} -> :error
      end

    token = String.trim(params["token"] || "")
    {round, if(token == "", do: tournament.lichess_token, else: token)}
  end

  # --- events ------------------------------------------------------------------

  @impl true
  # What only a box in a hall can do: on the server the panels are not drawn,
  # and a hand-made event gets nothing either.
  def handle_event(event, _params, %{assigns: %{server?: true}} = socket)
      when event in ~w(save_pin clear_pin set_listen save_update_mode check_update update_start
                       update_cancel update_apply set_autostart),
      do: {:noreply, socket}

  # One form, two buttons: "Test connection" submits it with `intent=test`
  # and nothing is saved.
  def handle_event("save_server", %{"server" => params, "intent" => "test"}, socket) do
    {url, slug, key} = read_server(params)
    send(self(), {:run_test, url, slug, key})

    {:noreply,
     assign(socket, testing?: true, checks: nil, server_form: to_form(params, as: :server))}
  end

  def handle_event("save_server", %{"server" => params}, socket) do
    {url, slug, key} = read_server(params)

    cond do
      url == "" or slug == "" ->
        {:noreply,
         socket
         |> assign(server_form: to_form(params, as: :server))
         |> put_flash(:error, gettext("Give the results site's address and the tournament."))}

      true ->
        Tournaments.update!(Tournaments.default(), %{
          server_url: url,
          slug: slug,
          relay_key: key || ""
        })

        Log.add(:info, "setup.saved", %{})
        {:noreply, socket |> put_flash(:info, gettext("Saved.")) |> load()}
    end
  end

  # One form, two buttons, like the results server's: "Test" saves nothing.
  def handle_event("save_lichess", %{"lichess" => params, "intent" => "test"}, socket) do
    {round, token} = read_lichess(params, socket.assigns.lichess)
    send(self(), {:run_lichess_test, round, token})

    {:noreply,
     assign(socket,
       lichess_testing?: true,
       lichess_checks: nil,
       lichess_form: to_form(Map.put(params, "token", ""), as: :lichess)
     )}
  end

  def handle_event("save_lichess", %{"lichess" => params}, socket) do
    case read_lichess(params, socket.assigns.lichess) do
      {:error, _token} ->
        {:noreply,
         socket
         |> assign(lichess_form: to_form(Map.put(params, "token", ""), as: :lichess))
         |> put_flash(
           :error,
           gettext(
             "That is not a Lichess round. Paste the link to the round, or its id of eight characters."
           )
         )}

      {round, token} ->
        Tournaments.update!(socket.assigns.lichess, %{
          lichess_round_id: round,
          lichess_token: token || "",
          lichess_round: int(params["round_no"], socket.assigns.lichess.round || 1, 1, 999)
        })

        Destination.set_enabled(LichessBroadcast, params["enabled"] == "true")
        Log.add(:info, "setup.saved", %{})
        {:noreply, socket |> put_flash(:info, gettext("Saved.")) |> load()}
    end
  end

  def handle_event("clear_lichess", _params, socket) do
    Tournaments.update!(socket.assigns.lichess, %{lichess_round_id: "", lichess_token: ""})

    # The switch is the destination's, not one tournament's: it goes off
    # with the last Lichess round.
    unless LichessBroadcast.configured?(), do: Destination.set_enabled(LichessBroadcast, false)
    Log.add(:info, "setup.saved", %{})

    {:noreply,
     socket
     |> assign(lichess_checks: nil)
     |> put_flash(:info, gettext("The Lichess round and its token are forgotten."))
     |> load()}
  end

  def handle_event("save_box", %{"box" => params}, socket) do
    name = String.trim(params["box_name"] || "")

    # The server has a fixed name; only a box is renamed.
    names =
      if socket.assigns.server?,
        do: %{},
        else: %{"box_name" => if(name == "", do: "Alnasl", else: String.slice(name, 0, 40))}

    common = %{
      "locale" => if(params["locale"] in ["en", "nl"], do: params["locale"], else: "en"),
      "auto_suggest" => params["auto_suggest"] == "true",
      "new_game_on_setup" =>
        if(params["new_game_on_setup"] in ~w(always never),
          do: params["new_game_on_setup"],
          else: "unpaired"
        ),
      "capture_cap_mb" => int(params["capture_cap_mb"], 500, 10, 100_000),
      "clock_heartbeat_s" => int(params["clock_heartbeat_s"], 20, 5, 600)
    }

    Settings.put_many(Map.merge(common, names))

    Tournaments.set_round(Tournaments.default_id(), int(params["round"], 1, 1, 999))
    Log.add(:info, "setup.saved", %{})
    # The language may have changed: draw the page again from the top.
    {:noreply,
     socket |> put_flash(:info, gettext("Saved.")) |> push_navigate(to: ~p"/setup/this-box")}
  end

  # --- tournaments and connect codes -------------------------------------------

  def handle_event("add_code", %{"link" => %{"code" => text}}, socket) do
    # A browser keeps what was typed in a field that has the focus. The
    # field holds a secret, so it is not emptied: it is replaced.
    socket = assign(socket, code_key: socket.assigns.code_key + 1)

    case OpenPairings.add_code(text, here(socket)) do
      {:ok, link, tournaments} ->
        shared = Duplicates.shared(link)

        socket =
          cond do
            # Everything it reaches is here through another code already.
            tournaments == [] and shared != [] ->
              put_flash(socket, :error, LinkWords.elsewhere(shared))

            shared != [] ->
              put_flash(
                socket,
                :info,
                accepted_words(tournaments, Seating.after_code(tournaments)) <>
                  " " <> LinkWords.elsewhere(shared)
              )

            true ->
              put_flash(
                socket,
                :info,
                accepted_words(tournaments, Seating.after_code(tournaments))
              )
          end

        {:noreply,
         socket
         |> assign(code_form: to_form(%{"code" => ""}, as: :link))
         |> Hall.refresh()
         |> load()}

      {:pending, _link, reason} ->
        {:noreply,
         socket
         |> assign(code_form: to_form(%{"code" => ""}, as: :link))
         |> put_flash(
           :error,
           gettext(
             "The code is kept, but could not be checked: %{why} Alnasl asks again by itself.",
             why: LinkWords.error(reason)
           )
         )
         |> load()}

      {:error, reason} ->
        # The text is not put back in the field: it holds a secret.
        {:noreply,
         socket
         |> assign(code_form: to_form(%{"code" => ""}, as: :link))
         |> put_flash(:error, LinkWords.code_error(reason))}
    end
  end

  def handle_event("test_link", %{"id" => id}, socket) do
    id = String.to_integer(id)
    send(self(), {:run_link_test, id})

    {:noreply,
     assign(socket, link_testing: id, link_tests: Map.delete(socket.assigns.link_tests, id))}
  end

  # The tournament stays the same row; it is asked through this code now.
  def handle_event("use_code", %{"id" => id, "remote" => remote}, socket) do
    with %{} = link <- Tournaments.get_link(id),
         {:ok, tournament} <- OpenPairings.use_code(link, String.to_integer(remote)) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext(
           "%{name} is asked through this code from now on. Its boards and games are as they were.",
           name: Tournaments.title(tournament) || ""
         )
       )
       |> load()}
    else
      _none ->
        {:noreply, socket |> put_flash(:error, gettext("That could not be done.")) |> load()}
    end
  end

  def handle_event("retry_link", %{"id" => id}, socket) do
    case Tournaments.get_link(id) do
      nil ->
        {:noreply, load(socket)}

      link ->
        socket =
          case OpenPairings.retry(link) do
            {:ok, _link} -> put_flash(socket, :info, gettext("OpenPairings answers again."))
            {:error, reason} -> put_flash(socket, :error, LinkWords.error(reason))
          end

        {:noreply, load(socket)}
    end
  end

  def handle_event("remove_link", %{"id" => id}, socket) do
    if link = Tournaments.get_link(id), do: OpenPairings.remove_link(link)

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext(
         "The code and its tournaments are removed from Alnasl. Their boards are back in the hall's own tournament, not linked."
       )
     )
     |> load()}
  end

  # A tournament the pairing program no longer lists, taken off by itself.
  def handle_event("remove_tournament", %{"id" => id}, socket) do
    with %{} = tournament <- Tournaments.get(id), do: Tournaments.remove(tournament)

    {:noreply,
     socket |> put_flash(:info, gettext("The tournament is removed from Alnasl.")) |> load()}
  end

  def handle_event("assign_tables", %{"tables" => %{"id" => id} = params}, socket) do
    tournament = Tournaments.get(id)
    from = optional_int(params["from"])
    to = optional_int(params["to"]) || from

    # A team event's form says whether a match keeps its tables together;
    # said before the boards move, so that they move by it.
    tournament =
      case {tournament, params["keep_matches"]} do
        {%{} = t, keep} when keep in ["true", "false"] ->
          Tournaments.update!(t, %{keep_matches: keep == "true"})

        _other ->
          tournament
      end

    # The tables of the hall the page is about.
    result =
      cond do
        tournament == nil -> {:error, :range}
        from == nil -> Tournaments.assign_tables(tournament, nil, nil, here(socket))
        true -> Seating.assign_range(tournament, from, to, here(socket))
      end

    case result do
      {:ok, _tournament} when from == nil ->
        {:noreply, socket |> put_flash(:info, gettext("No range of tables any more.")) |> load()}

      {:ok, tournament, carried} ->
        {:noreply,
         socket
         |> put_flash(:info, Hall.range_words(tournament, from, to, carried, here(socket)))
         |> Hall.refresh()
         |> load()}

      {:error, :boards} ->
        {:noreply, put_flash(socket, :error, placement_error(:boards))}

      _error ->
        {:noreply,
         put_flash(socket, :error, gettext("Give the first and the last table: 5 and 8."))}
    end
  end

  # --- halls and tables of a tournament -----------------------------------------

  # The permit has checked the account is an arbiter for the tournament and
  # in the hall named.
  def handle_event("placement_add", params, socket) do
    params = Map.get(params, "add", params)

    with %{} = tournament <- Tournaments.get(params["t"]),
         %{} = hall <- Alnasl.Halls.get(params["hall"]),
         {:ok, placement, carried} <- Alnasl.Placements.add(tournament, hall.id) do
      {:noreply,
       socket
       |> put_flash(:info, placed_words(tournament, hall, placement, carried))
       |> Hall.refresh()
       |> load()}
    else
      {:error, :busy, board} ->
        {:noreply, put_flash(socket, :error, AlnaslWeb.TableWords.busy(board))}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, placement_error(reason)) |> load()}

      {:error, :tables, other} ->
        {:noreply, put_flash(socket, :error, tables_taken(other))}

      _none ->
        {:noreply, socket |> put_flash(:error, gettext("That could not be done.")) |> load()}
    end
  end

  def handle_event("placement_save", %{"place" => params}, socket) do
    from = optional_int(params["from"])
    to = if from, do: optional_int(params["to"]) || from
    first = optional_int(params["first"]) || 1

    with %{} = tournament <- Tournaments.get(params["t"]),
         %{} = hall <- Alnasl.Halls.get(params["hall"]),
         {:ok, placement, carried} <-
           Alnasl.Placements.put(tournament, hall.id, %{
             table_from: from,
             table_to: to,
             first_board: first
           }) do
      {:noreply,
       socket
       |> put_flash(:info, placed_words(tournament, hall, placement, carried))
       |> Hall.refresh()
       |> load()}
    else
      {:error, :tables, other} ->
        {:noreply, put_flash(socket, :error, tables_taken(other))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, placement_error(reason))}

      _none ->
        {:noreply, socket |> put_flash(:error, gettext("That could not be done.")) |> load()}
    end
  end

  def handle_event("placement_remove", %{"t" => tid, "hall" => hall_id}, socket) do
    with %{} = tournament <- Tournaments.get(tid),
         %{} = hall <- Alnasl.Halls.get(hall_id),
         %{} = placement <- Alnasl.Placements.in_hall(tournament, hall.id),
         :ok <- Alnasl.Placements.remove(placement) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext(
           "%{name} is no longer played in %{hall}. Its boards there are back in the hall's own tournament.",
           name: Tournaments.title(tournament) || "",
           hall: hall.name
         )
       )
       |> Hall.refresh()
       |> load()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, placement_error(reason))}

      _none ->
        {:noreply, socket |> put_flash(:error, gettext("That could not be done.")) |> load()}
    end
  end

  def handle_event("auto_start", %{"id" => id}, socket) do
    with %{} = tournament <- Tournaments.get(id) do
      Tournaments.update!(tournament, %{auto_start: not tournament.auto_start})
    end

    {:noreply, load(socket)}
  end

  # --- the wizard ----------------------------------------------------------------

  # Only what this browser shows: the questions as they are being answered.
  def handle_event("wizard_change", %{"wizard" => params}, socket),
    do: {:noreply, socket |> assign(wizard_params: params) |> assign_wizard()}

  def handle_event("wizard_edit", _params, socket),
    do: {:noreply, assign(socket, wizard_editing?: true)}

  def handle_event("wizard_cancel", _params, socket),
    do:
      {:noreply, socket |> assign(wizard_editing?: false, wizard_params: nil) |> assign_wizard()}

  def handle_event("save_wizard", %{"wizard" => params}, socket) do
    Wizard.save(socket.assigns.hall_id, params, wizard_ctx(socket.assigns))
    Log.add(:info, "setup.saved", %{})
    {:noreply, socket |> assign(wizard_editing?: false, wizard_params: nil) |> assign_wizard()}
  end

  def handle_event("wizard_mark", %{"key" => key, "done" => done}, socket) do
    Wizard.mark(socket.assigns.hall_id, key, done == "true")
    {:noreply, assign_wizard(socket)}
  end

  # The page's own state: nothing is stored, nothing changes anywhere else.
  def handle_event("goto_section", %{"section" => slug}, socket) do
    if Enum.any?(sections(socket.assigns), &(&1.slug == slug)),
      do: {:noreply, push_patch(socket, to: "/setup/" <> slug)},
      else: {:noreply, socket}
  end

  def handle_event("toggle_tournament", %{"id" => id}, socket) do
    case Integer.parse(to_string(id)) do
      {id, ""} ->
        open = socket.assigns.open

        {:noreply,
         assign(socket,
           open: if(id in open, do: MapSet.delete(open, id), else: MapSet.put(open, id))
         )}

      _bad ->
        {:noreply, socket}
    end
  end

  def handle_event("search_tournaments", params, socket) do
    {:noreply, assign(socket, search: to_string(get_in(params, ["q"]) || ""))}
  end

  def handle_event("toggle_rest", _params, socket),
    do: {:noreply, assign(socket, show_rest?: not socket.assigns.show_rest?)}

  def handle_event("toggle_quiet", _params, socket),
    do: {:noreply, assign(socket, show_quiet?: not socket.assigns.show_quiet?)}

  def handle_event("toggle_adding", _params, socket),
    do: {:noreply, assign(socket, adding?: not socket.assigns.adding?)}

  def handle_event("pick_lichess", %{"tournament_id" => id}, socket) do
    case Integer.parse(id) do
      {id, ""} -> {:noreply, socket |> assign(lichess_tid: id, lichess_checks: nil) |> load()}
      _bad -> {:noreply, socket}
    end
  end

  def handle_event("save_pin", %{"door" => %{"pin" => pin}}, socket) do
    pin = String.trim(pin)

    cond do
      pin == "" ->
        {:noreply, put_flash(socket, :error, gettext("Type a PIN, or use \"Remove the PIN\"."))}

      String.length(pin) < Alnasl.DoorGuard.min_length() ->
        {:noreply, put_flash(socket, :error, gettext("A PIN needs at least 6 characters."))}

      true ->
        Settings.set_pin(pin)
        Log.add(:info, "setup.saved", %{})

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("The PIN is set. Browsers on other machines will be asked for it.")
         )
         |> load()}
    end
  end

  def handle_event("clear_pin", _params, socket) do
    Settings.set_pin(nil)
    Log.add(:info, "setup.saved", %{})
    {:noreply, socket |> put_flash(:info, gettext("The PIN is removed.")) |> load()}
  end

  # The hall's network is opened only behind a PIN: the switch is on a page
  # that anybody who reaches the box could otherwise use.
  def handle_event("set_listen", %{"choice" => choice}, socket) when choice in ["lan", "local"] do
    cond do
      socket.assigns.listen_forced ->
        {:noreply, socket}

      choice == "lan" and not Settings.pin_set?() ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Set a PIN first. Without one, anybody on the hall's network could use this site."
           )
         )}

      true ->
        Listen.put(choice)
        Log.add(:info, "setup.saved", %{})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Saved. It takes effect the next time Alnasl starts."))
         |> load()}
    end
  end

  # --- updates -------------------------------------------------------------------

  def handle_event("save_update_mode", %{"mode" => mode}, socket) when mode in ["ask", "never"] do
    Updates.put_mode(mode)
    Log.add(:info, "setup.saved", %{})
    {:noreply, socket |> put_flash(:info, gettext("Saved.")) |> load()}
  end

  def handle_event("check_update", _params, socket) do
    looked =
      case Updates.Checker.check_now() do
        {:ok, _info} -> :found
        :current -> :current
        :error -> :error
      end

    {:noreply, socket |> assign(update_looked: looked) |> load()}
  end

  # The first press costs nothing: it says what the second one will do.
  def handle_event("update_start", _params, socket) do
    case Updates.games_in_progress() do
      [] -> {:noreply, assign(socket, update_step: :confirm, update_games: [])}
      games -> {:noreply, assign(socket, update_step: :games, update_games: games)}
    end
  end

  def handle_event("update_cancel", _params, socket),
    do: {:noreply, assign(socket, update_step: nil, update_games: [])}

  def handle_event("update_apply", params, socket) do
    case Updates.apply(force: params["force"] == "yes") do
      :ok ->
        {:noreply, assign(socket, update_step: :going, update_games: [])}

      # A game began between the question and the answer.
      {:error, {:games, games}} ->
        {:noreply, assign(socket, update_step: :games, update_games: games)}

      {:error, _other} ->
        {:noreply,
         socket
         |> assign(update_step: nil)
         |> put_flash(:error, gettext("The update could not be started. Nothing was changed."))
         |> load()}
    end
  end

  def handle_event("set_autostart", %{"on" => on}, socket) do
    case Autostart.set(on == "true") do
      :ok ->
        {:noreply, socket |> put_flash(:info, gettext("Saved.")) |> load()}

      {:error, _words} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Windows did not accept that. Nothing was changed."))
         |> load()}
    end
  end

  def handle_event("save_tracker", %{"tracker" => params}, socket) do
    values =
      for field <- @tracker_fields, into: %{} do
        default = Map.fetch!(Tracker.defaults(), String.to_existing_atom(field))

        {field,
         int(
           params[field],
           default,
           if(field == "search_depth", do: 2, else: 0),
           if(field == "search_depth", do: 12, else: 600_000)
         )}
      end
      |> Map.put("takeback", params["takeback"] == "true")
      |> Map.put("unseen_piece", params["unseen_piece"] == "true")
      |> Map.put(
        "promotion_default",
        if(params["promotion_default"] in ~w(q r b n), do: params["promotion_default"], else: "q")
      )

    Settings.put("tracker", values)
    Log.add(:info, "setup.saved", %{})

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext("Saved. Every board uses the new settings from its next reading.")
     )
     |> load()}
  end

  # "Bullet / fast play": what `Alnasl.Tracker.preset(:bullet)` changes, on
  # top of whatever else was set (how far the box reconstructs is left as
  # it is).
  def handle_event("preset_tracker", %{"preset" => "bullet"}, socket) do
    preset = Map.new(Tracker.preset(:bullet), fn {key, value} -> {Atom.to_string(key), value} end)
    Settings.put("tracker", Map.merge(Settings.get("tracker") || %{}, preset))
    Log.add(:info, "setup.saved", %{})

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext("Set for fast play. Every board uses it from its next reading.")
     )
     |> load()}
  end

  def handle_event("reset_tracker", _params, socket) do
    Settings.put("tracker", %{})

    {:noreply,
     socket |> put_flash(:info, gettext("The tracker is back to its defaults.")) |> load()}
  end

  # What a code reaches that the box has through another hall's code, and
  # is not played in this code's hall: `%{{link, id there} => %{hall, may?}}`.
  defp also_here(links, scope) do
    for link <- links,
        hall = Alnasl.Halls.of(link),
        found <- Duplicates.shared(link),
        not Alnasl.Placements.in_hall?(found.tournament, hall),
        into: %{} do
      {{link.id, found.remote_id},
       %{hall: hall, may?: Alnasl.Accounts.Scope.can?(scope, :arbiter, hall)}}
    end
  end

  # The halls a tournament is played in, as rows of the card: the hall, the
  # placement, the boards it holds, and whether the account may change it.
  defp placement_rows(tournament, scope) do
    all = Alnasl.Placements.list(tournament)

    for p <- all do
      %{
        placement: p,
        hall: Alnasl.Halls.get(p.hall_id),
        boards: Alnasl.Placements.boards(p, all),
        may?: Alnasl.Accounts.Scope.can?(scope, :arbiter, p.hall_id),
        last?: length(all) == 1
      }
    end
  end

  @doc false
  def boards_words({first, :infinity}), do: gettext("boards %{first} and up", first: first)
  def boards_words({same, same}), do: gettext("board %{first}", first: same)

  def boards_words({first, last}),
    do: gettext("boards %{first} to %{last}", first: first, last: last)

  @doc false
  def tables_words(%{table_from: nil}), do: gettext("every free table")

  def tables_words(%{table_from: from, table_to: to}) when to in [nil, from],
    do: gettext("table %{from}", from: from)

  def tables_words(%{table_from: from, table_to: to}),
    do: gettext("tables %{from} to %{to}", from: from, to: to)

  defp placed_words(tournament, hall, placement, carried) do
    all = Alnasl.Placements.list(tournament)
    this = Enum.find(all, &(&1.hall_id == placement.hall_id)) || placement

    gettext("%{name} in %{hall}: %{tables}, %{boards}.",
      name: Tournaments.title(tournament) || gettext("The hall's own tournament"),
      hall: hall.name,
      tables: tables_words(this),
      boards: boards_words(Alnasl.Placements.boards(this, all))
    ) <> Enum.map_join(carried, &Hall.carried_words/1)
  end

  defp placement_error(:boards),
    do:
      gettext(
        "Those boards are played in another hall already. Start this hall at a board after them."
      )

  defp placement_error(:last),
    do:
      gettext("This is the only hall the tournament is played in. It has to be played somewhere.")

  defp placement_error(:already), do: gettext("The tournament is played in that hall already.")
  defp placement_error(:range), do: gettext("Give the first and the last table: 5 and 8.")
  defp placement_error(_other), do: gettext("That could not be done.")

  defp tables_taken(other),
    do:
      gettext("Some of those tables are %{name}'s in that hall. Give other tables.",
        name: (other && Tournaments.title(other)) || gettext("another tournament")
      )

  defp optional_int(text) do
    case Integer.parse(String.trim(text || "")) do
      {n, ""} when n > 0 and n < 10_000 -> n
      _none -> nil
    end
  end

  defp int(text, default, low, high) do
    case Integer.parse(to_string(text)) do
      {n, _} -> n |> max(low) |> min(high)
      :error -> default
    end
  end

  @impl true
  def handle_info({:run_test, url, slug, key}, socket) do
    checks =
      if url == "",
        do: [server: {:error, {:unreachable, :nxdomain}}, key: :skipped],
        else: OpenResults.test(url, slug, key)

    {:noreply, assign(socket, checks: checks, testing?: false)}
  end

  def handle_info({:run_lichess_test, round, token}, socket) do
    checks =
      case round do
        :error -> [account: :skipped, scope: :skipped, round: {:error, :round_not_found}]
        round -> LichessApi.test(LichessApi.base(), round, token)
      end

    {:noreply, assign(socket, lichess_checks: checks, lichess_testing?: false)}
  end

  def handle_info({:run_link_test, id}, socket) do
    result =
      case Tournaments.get_link(id) do
        nil -> nil
        link -> OpenPairings.test(link)
      end

    {:noreply,
     assign(socket,
       link_testing: nil,
       link_tests: Map.put(socket.assigns.link_tests, id, result)
     )}
  end

  # A tournament appeared, a round was started, a link went quiet.
  def handle_info({:tournament, _id}, socket), do: {:noreply, load(socket)}

  # The checker heard of a release, or the setting changed in another window.
  def handle_info(:update_changed, socket), do: {:noreply, load(socket)}

  # A board says something many times a minute; the wizard needs to know
  # that it exists, not what it said. So once a second at most, and only
  # while the wizard is on screen.
  def handle_info({tag, _what}, %{assigns: %{section: :wizard}} = socket)
      when tag in [:board, :bridges] do
    if socket.assigns.wizard_due? do
      {:noreply, socket}
    else
      Process.send_after(self(), :wizard_refresh, 1_000)
      {:noreply, assign(socket, wizard_due?: true)}
    end
  end

  def handle_info(:wizard_refresh, socket),
    do: {:noreply, socket |> assign(wizard_due?: false) |> assign_wizard()}

  def handle_info(_other, socket), do: {:noreply, socket}

  # What the code brought, and the next step the box took (or asks for).
  defp accepted_words([], _step),
    do:
      gettext(
        "The code is accepted. It reaches no tournament just now; one that is added to it later appears here by itself."
      )

  defp accepted_words(found, {:joined, tournament, boards}) do
    gettext("The code is accepted: %{count} tournament(s).", count: length(found)) <>
      " " <>
      ngettext(
        "The board now plays in %{name}: its table number is its board.",
        "All %{count} boards now play in %{name}: a board's table number is its board.",
        length(boards),
        name: Tournaments.title(tournament) || "",
        count: length(boards)
      )
  end

  defp accepted_words(found, {:ask, _tournaments}),
    do:
      gettext("The code is accepted: %{count} tournament(s).", count: length(found)) <>
        " " <> gettext("Say below which tables play in which.")

  defp accepted_words(found, :nothing),
    do:
      gettext("The code is accepted: %{count} tournament(s).", count: length(found)) <>
        " " <> gettext("Boards you connect later can be put in them on the Boards page.")

  # "board 3, board 7 and board 12", by the number the arbiter knows them by.
  defp board_list(games) do
    names =
      Enum.map(games, fn game ->
        cond do
          game.board_no -> gettext("board %{n}", n: game.board_no)
          game.table_no -> gettext("table %{n}", n: game.table_no)
          true -> gettext("a board without a number")
        end
      end)

    case Enum.split(names, -1) do
      {[], [only]} -> only
      {first, [last]} -> gettext("%{list} and %{last}", list: Enum.join(first, ", "), last: last)
    end
  end

  defp when_(nil), do: gettext("never")
  defp when_(%DateTime{} = at), do: Words.time(at)

  # What the box holds of a linked tournament, counted.
  defp received(tournament) do
    document = Tournaments.document(tournament) || %{}
    rounds = List.wrap(document["rounds"])
    current = Enum.find(rounds, &(&1["number"] == tournament.remote_round)) || %{}

    %{
      players: length(List.wrap(document["players"])),
      rounds: length(rounds),
      boards: Enum.count(List.wrap(current["boards"]), &(&1["kind"] == "game")),
      time_control: get_in(document, ["tournament", "time_control", "text"])
    }
  end

  # --- what the Tournaments section draws ---------------------------------------

  # From this many tournaments on, the list has a search field.
  @search_from 9

  # A tournament that has not started or is over is not on the boards: it is
  # behind a toggle, unless it is open or found by a search.
  defp quiet?(%{state: state}), do: state in ["setup", "finished"]

  defp on_boards?(t, counts), do: Map.get(counts, t.id, 0) > 0

  defp matches?(t, query) do
    [Tournaments.title(t), t.name, t.label, t.slug]
    |> Enum.map_join(" ", &to_string/1)
    |> String.downcase()
    |> String.contains?(query)
  end

  # `%{here: [...], rest: [...], quiet: n, searching?: bool}`: the tournaments
  # with boards on this box first, the others behind one line, the quiet ones
  # counted. When none has boards, the others are the list: a fold with
  # nothing above it hides the only thing there is.
  defp tournament_groups(a) do
    query = a.search |> String.trim() |> String.downcase()

    if query != "" do
      %{
        here: Enum.filter(a.tournaments, &matches?(&1, query)),
        rest: [],
        quiet: 0,
        searching?: true
      }
    else
      {shown, quiet} =
        Enum.split_with(a.tournaments, &(a.show_quiet? or not quiet?(&1) or &1.id in a.open))

      {here, rest} = Enum.split_with(shown, &(on_boards?(&1, a.board_counts) or &1.id in a.open))
      {here, rest} = if here == [], do: {rest, []}, else: {here, rest}
      %{here: here, rest: rest, quiet: length(quiet), searching?: false}
    end
  end

  defp status_word(%{gone: true}), do: gettext("No longer listed")
  defp status_word(%{state: "running"}), do: gettext("Running")
  defp status_word(%{state: "setup"}), do: gettext("Not started")
  defp status_word(%{state: "finished"}), do: gettext("Finished")
  defp status_word(_t), do: nil

  defp dot_tone(%{gone: true}), do: "warn"
  defp dot_tone(%{state: "running"}), do: "ok"
  defp dot_tone(_t), do: nil

  defp name_of(t), do: Tournaments.title(t) || gettext("The hall's own tournament")

  # One tournament: a line that says the most, and the rest when it is opened.
  defp tournament_row(assigns) do
    ~H"""
    <li id={"tournament-#{@t.id}"} class={["trow", @open? && "open"]}>
      <div class="trow-head">
        <button
          type="button"
          id={"tournament-toggle-#{@t.id}"}
          class="trow-toggle"
          phx-click="toggle_tournament"
          phx-value-id={@t.id}
          aria-expanded={to_string(@open?)}
          aria-controls={"tournament-body-#{@t.id}"}
        >
          <span class={["tdot", dot_tone(@t)]} aria-hidden="true"></span>
          <b class="trow-name">{name_of(@t)}</b>
          <span :if={status_word(@t)} id={"tournament-status-#{@t.id}"} class="sr-only">
            {status_word(@t)}
          </span>

          <span id={"tournament-round-#{@t.id}"} class="trow-meta">
            {gettext("round %{n}", n: @t.round)}
          </span>

          <span id={"tournament-count-#{@t.id}"} class="trow-meta">
            {ngettext("%{count} board", "%{count} boards", Map.get(@board_counts, @t.id, 0))}
          </span>

          <span id={"tournament-chip-#{@t.id}"} class="chip">
            <% {table_from, table_to} = @ranges[@t.id] || {nil, nil} %> {tables_words(%{
              table_from: table_from,
              table_to: table_to
            })}
          </span>
          <.icon name="chevron" class="trow-caret" />
        </button>

        <.badge :if={@t.kind == "local"} id={"tournament-kind-#{@t.id}"} icon="waiting">
          {gettext("No pairing program")}
        </.badge>

        <.badge :if={@t.gone} id={"tournament-gone-#{@t.id}"} tone="warn" icon="warning">
          {gettext("No longer listed")}
        </.badge>

        <.badge
          :if={@t.kind == "linked" and elem(Status.results_line(@t), 0) == "warn"}
          id={"tournament-nokey-badge-#{@t.id}"}
          tone="warn"
          icon="warning"
        >
          {gettext("No relay key yet")}
        </.badge>
      </div>

      <div :if={@open?} id={"tournament-body-#{@t.id}"} class="trow-body">
        <.tournament_body
          t={@t}
          ranges={@ranges}
          placements={@placements}
          addable={@addable}
          board_counts={@board_counts}
        />
      </div>
    </li>
    """
  end

  defp tournament_body(assigns) do
    ~H"""
    <% t = @t %>
    <p
      :if={t.label not in [nil, ""] and t.name not in [nil, "", t.label]}
      id={"tournament-name-#{t.id}"}
      class="note"
    >
      {t.name}
    </p>

    <%= if t.kind == "linked" do %>
      <% got = received(t) %>
      <p id={"tournament-line-#{t.id}"} class="dest-line">
        <%= if t.document do %>
          {gettext(
            "Received %{t}: %{players} player(s), %{rounds} round(s) paired, %{boards} board(s) in round %{round}.",
            t: when_(t.document_at),
            players: got.players,
            rounds: got.rounds,
            boards: got.boards,
            round: t.remote_round || "-"
          )} <span :if={got.time_control}>{got.time_control}.</span>
          <span :if={Tournaments.team_event?(t)} id={"tournament-teams-#{t.id}"}>
            {gettext("A team event, %{n} boards a match.",
              n: Tournaments.boards_per_match(t) || "?"
            )}
          </span>
        <% else %>
          {gettext("Nothing received yet.")}
        <% end %>

        <span class="note">
          {gettext("The boards follow round %{n}.", n: t.round)}
          <span :if={t.version}>
            {gettext("Version %{v}.", v: String.slice(t.version, 0, 8))}
          </span>
        </span>
      </p>
      <% {results_tone, results_text} = Status.results_line(t) %>
      <p
        :if={results_tone != "warn"}
        id={"tournament-results-#{t.id}"}
        class="note"
      >
        {results_text}
      </p>

      <div
        :if={results_tone == "warn"}
        id={"tournament-nokey-#{t.id}"}
        class="callout warn"
        role="status"
      >
        <b>
          {gettext("%{url}, %{slug}: no relay key yet", url: t.server_url, slug: t.slug)}
        </b>

        <p>{results_text}</p>
      </div>
    <% else %>
      <p id={"tournament-line-#{t.id}"} class="dest-line">
        {gettext(
          "For boards without a pairing program: names by hand or from a PGN. The boards follow round %{n}.",
          n: t.round
        )}
      </p>

      <p
        :if={ResultsSite.why_not(t)}
        id={"tournament-site-none-#{t.id}"}
        class="note"
      >
        {no_site_reason(ResultsSite.why_not(t))}
      </p>
    <% end %>

    <p :if={ResultsSite.page?(t)} id={"tournament-site-#{t.id}"}>
      <.site_link id={"tournament-site-link-#{t.id}"} href={ResultsSite.tournament_url(t)}>
        {gettext("Open the results page: %{address}", address: ResultsSite.display(t))}
      </.site_link>
    </p>
    <% {table_from, table_to} = @ranges[t.id] || {nil, nil} %>
    <.form
      for={to_form(%{"id" => t.id, "from" => table_from, "to" => table_to}, as: :tables)}
      id={"tables-form-#{t.id}"}
      phx-submit="assign_tables"
      class="row align-end"
    >
      <input type="hidden" name="tables[id]" value={t.id} />
      <div class="field">
        <label for={"tables-from-#{t.id}"}>{gettext("Tables from")}</label>
        <input
          id={"tables-from-#{t.id}"}
          name="tables[from]"
          type="number"
          inputmode="numeric"
          min="1"
          max="9999"
          value={table_from}
          class="input table-no"
        />
      </div>

      <div class="field">
        <label for={"tables-to-#{t.id}"}>{gettext("to")}</label>
        <input
          id={"tables-to-#{t.id}"}
          name="tables[to]"
          type="number"
          inputmode="numeric"
          min="1"
          max="9999"
          value={table_to}
          class="input table-no"
        />
      </div>

      <div :if={Tournaments.team_event?(t)} class="field">
        <input type="hidden" name="tables[keep_matches]" value="false" />
        <label for={"tables-keep-#{t.id}"} class="row tight">
          <input
            id={"tables-keep-#{t.id}"}
            name="tables[keep_matches]"
            type="checkbox"
            value="true"
            checked={t.keep_matches}
          /> {gettext("Keep each match together")}
        </label>
      </div>

      <.button id={"assign-tables-#{t.id}"} small type="submit">
        {gettext("These tables play here")}
      </.button>

      <span id={"tournament-boards-#{t.id}"} class="note">
        {gettext("%{count} board(s) now", count: Map.get(@board_counts, t.id, 0))}
      </span>
    </.form>

    <details
      id={"placements-#{t.id}"}
      class="placements"
      open={length(@placements[t.id]) > 1}
    >
      <summary>
        {gettext("Halls and tables")}
        <span class="note">
          {ngettext(
            "played in %{count} hall",
            "played in %{count} halls",
            length(@placements[t.id])
          )}
        </span>
      </summary>

      <ul id={"placement-rows-#{t.id}"} class="placement-rows">
        <li
          :for={row <- @placements[t.id]}
          id={"placement-#{t.id}-#{row.placement.hall_id}"}
          class="placement-row"
        >
          <%= if row.may? do %>
            <.form
              for={
                to_form(
                  %{
                    "t" => t.id,
                    "hall" => row.placement.hall_id,
                    "from" => row.placement.table_from,
                    "to" => row.placement.table_to,
                    "first" => row.placement.first_board
                  },
                  as: :place
                )
              }
              id={"placement-form-#{t.id}-#{row.placement.hall_id}"}
              phx-submit="placement_save"
              class="row align-end"
            >
              <b class="placement-hall">{(row.hall && row.hall.name) || "?"}</b>
              <input type="hidden" name="place[t]" value={t.id} />
              <input type="hidden" name="place[hall]" value={row.placement.hall_id} />
              <div class="field">
                <label for={"place-from-#{t.id}-#{row.placement.hall_id}"}>
                  {gettext("Tables from")}
                </label>

                <input
                  id={"place-from-#{t.id}-#{row.placement.hall_id}"}
                  name="place[from]"
                  type="number"
                  inputmode="numeric"
                  min="1"
                  max="9999"
                  value={row.placement.table_from}
                  class="input table-no"
                />
              </div>

              <div class="field">
                <label for={"place-to-#{t.id}-#{row.placement.hall_id}"}>
                  {gettext("to")}
                </label>

                <input
                  id={"place-to-#{t.id}-#{row.placement.hall_id}"}
                  name="place[to]"
                  type="number"
                  inputmode="numeric"
                  min="1"
                  max="9999"
                  value={row.placement.table_to}
                  class="input table-no"
                />
              </div>

              <div class="field">
                <label for={"place-first-#{t.id}-#{row.placement.hall_id}"}>
                  {gettext("First board")}
                </label>

                <input
                  id={"place-first-#{t.id}-#{row.placement.hall_id}"}
                  name="place[first]"
                  type="number"
                  inputmode="numeric"
                  min="1"
                  max="9999"
                  value={row.placement.first_board}
                  class="input table-no"
                />
              </div>

              <span id={"placement-boards-#{t.id}-#{row.placement.hall_id}"} class="note">
                {boards_words(row.boards)}
              </span>

              <.button
                id={"placement-save-#{t.id}-#{row.placement.hall_id}"}
                small
                type="submit"
              >
                {gettext("Save")}
              </.button>

              <.button
                :if={not row.last?}
                id={"placement-remove-#{t.id}-#{row.placement.hall_id}"}
                small
                type="button"
                variant="danger"
                phx-click="placement_remove"
                phx-value-t={t.id}
                phx-value-hall={row.placement.hall_id}
                data-confirm={
                  gettext(
                    "Stop playing this tournament in this hall? Its boards there go back to the hall's own tournament, not linked; its games stay."
                  )
                }
              >
                {gettext("Remove")}
              </.button>
            </.form>
          <% else %>
            <p class="row">
              <b class="placement-hall">{(row.hall && row.hall.name) || "?"}</b>
              <span>{tables_words(row.placement)}, {boards_words(row.boards)}</span>
            </p>
          <% end %>
        </li>
      </ul>

      <.form
        :if={@addable[t.id] != []}
        for={to_form(%{"t" => t.id}, as: :add)}
        id={"placement-add-#{t.id}"}
        phx-submit="placement_add"
        class="row align-end"
      >
        <input type="hidden" name="add[t]" value={t.id} />
        <div class="field">
          <label for={"placement-add-hall-#{t.id}"}>{gettext("Add a hall")}</label>
          <select id={"placement-add-hall-#{t.id}"} name="add[hall]" class="input">
            <option :for={hall <- @addable[t.id]} value={hall.id}>{hall.name}</option>
          </select>
        </div>

        <.button id={"placement-add-button-#{t.id}"} small type="submit">
          {gettext("Add a hall")}
        </.button>
      </.form>

      <p class="note">
        {gettext(
          "A hall added takes the next free tables there and the boards after the last one placed: boards 1-8 here and 9-16 next door. Change either before the round."
        )}
      </p>
    </details>

    <div class="row">
      <.button
        :if={t.kind == "linked"}
        id={"auto-start-#{t.id}"}
        small
        phx-click="auto_start"
        phx-value-id={t.id}
        aria-pressed={to_string(t.auto_start)}
      >
        {if t.auto_start,
          do: gettext("Rounds start by themselves: on"),
          else: gettext("Rounds start by themselves: off")}
      </.button>

      <.button
        :if={t.gone}
        id={"remove-tournament-#{t.id}"}
        small
        variant="danger"
        phx-click="remove_tournament"
        phx-value-id={t.id}
        data-confirm={
          gettext(
            "Remove this tournament from Alnasl? Its boards go back to the hall's own tournament, not linked; its games are forgotten here (the PGN files already written stay on the disk)."
          )
        }
      >{gettext("Remove")}</.button>
    </div>
    """
  end

  # --- page --------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        groups: tournament_groups(assigns),
        sections: sections(assigns),
        search_from: @search_from,
        quiet_total: Enum.count(assigns.tournaments, &quiet?/1)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:setup}
      help={:setup}
      link={@link}
      hall={@hall}
      update={@update}
      box={@box}
      locale={@locale}
      scope={@current_scope}
      path={@current_path}
      title={gettext("Setup")}
    >
      <div class="setup">
        <nav id="setup-nav" class="setup-nav" aria-label={gettext("Sections of Setup")}>
          <.link
            :for={s <- @sections}
            id={"setup-nav-#{s.slug}"}
            patch={~p"/setup/#{s.slug}"}
            class={["setup-nav-link", s.key == @section && "current"]}
            aria-current={s.key == @section && "page"}
          >
            {s.label}
          </.link>
        </nav>

        <form id="setup-select-form" class="setup-select" phx-change="goto_section">
          <label for="setup-select" class="sr-only">{gettext("Section")}</label>
          <select id="setup-select" name="section" class="input">
            <option :for={s <- @sections} value={s.slug} selected={s.key == @section}>
              {s.label}
            </option>
          </select>
        </form>

        <div class="setup-body">
          <WizardComponents.wizard
            :if={@section == :wizard}
            plan={@wizard}
            form={@wizard_form}
            editing?={@wizard_editing?}
            server?={@server?}
            own_hall?={@own_hall?}
            scope={@current_scope}
            hall_id={@hall_id}
            may_answer?={@may_answer?}
          />
          <.panel :if={@section == :tournaments} id="setup-tournaments" title={gettext("Tournaments")}>
            <p class="note">
              {gettext(
                "The tournaments Alnasl serves. The ones with boards in this hall come first; a connect code or an OpenPairings account brings more."
              )} <.link patch={~p"/setup/connections"}>{gettext("Connections")}</.link>
              <.link navigate={AlnaslWeb.Components.ManualLink.path(:setup)}>{gettext(
                "How, step by step"
              )}</.link>
            </p>
            <SeatingComponents.ask ask={@hall.seating.ask} />
            <form
              :if={length(@tournaments) >= @search_from}
              id="tournament-search-form"
              class="tsearch"
              phx-change="search_tournaments"
              phx-submit="search_tournaments"
            >
              <label for="tournament-search" class="sr-only">{gettext("Find a tournament")}</label>
              <input
                id="tournament-search"
                name="q"
                type="search"
                class="input"
                value={@search}
                placeholder={gettext("Find a tournament")}
                phx-debounce="200"
                autocomplete="off"
              />
            </form>

            <ul id="tournaments" class="trows">
              <.tournament_row
                :for={t <- @groups.here}
                t={t}
                open?={t.id in @open}
                ranges={@ranges}
                placements={@placements}
                addable={@addable}
                board_counts={@board_counts}
              />
            </ul>

            <div :if={@groups.here == [] and @groups.searching?} id="tournaments-empty" class="empty">
              <b>{gettext("No tournament has that in its name")}</b>
              <p>
                {gettext("Try a shorter part of the name, or empty the search field to see them all.")}
              </p>
            </div>

            <div
              :if={@groups.here == [] and not @groups.searching? and @groups.rest == []}
              id="tournaments-empty"
              class="empty"
            >
              <b>{gettext("No tournaments yet")}</b>
              <p>
                {gettext(
                  "A tournament arrives with a connection: a connect code from OpenPairings, or your OpenPairings account. Its rounds, pairings and results page come with it."
                )}
              </p>

              <.button id="tournaments-empty-add" navigate={~p"/setup/connections"} variant="primary">
                {gettext("Add a connection")}
              </.button>
            </div>

            <p
              :if={@groups.here == [] and not @groups.searching? and @groups.rest != []}
              id="tournaments-empty"
              class="note"
            >
              {gettext("No tournament has boards in this hall yet; the others are below.")}
            </p>

            <div :if={@groups.rest != []} id="tournaments-rest-wrap" class="tfold">
              <button
                type="button"
                id="toggle-rest"
                class="tfold-toggle"
                phx-click="toggle_rest"
                aria-expanded={to_string(@show_rest?)}
                aria-controls="tournaments-rest"
              >
                <.icon name="chevron" class={["tfold-caret", @show_rest? && "up"]} /> {ngettext(
                  "%{count} more tournament, not on the boards here",
                  "%{count} more tournaments, not on the boards here",
                  length(@groups.rest)
                )}
              </button>

              <ul :if={@show_rest?} id="tournaments-rest" class="trows">
                <.tournament_row
                  :for={t <- @groups.rest}
                  t={t}
                  open?={t.id in @open}
                  ranges={@ranges}
                  placements={@placements}
                  addable={@addable}
                  board_counts={@board_counts}
                />
              </ul>
            </div>

            <div :if={@quiet_total > 0 and not @groups.searching?} class="tfold">
              <button
                type="button"
                id="toggle-quiet"
                class="tfold-toggle"
                phx-click="toggle_quiet"
                aria-expanded={to_string(@show_quiet?)}
              >
                <.icon name="chevron" class={["tfold-caret", @show_quiet? && "up"]} /> {if @show_quiet?,
                  do: gettext("Hide the tournaments not started or finished"),
                  else:
                    ngettext(
                      "Show %{count} tournament not started or finished",
                      "Show %{count} tournaments not started or finished",
                      @quiet_total
                    )}
              </button>
            </div>

            <p class="note">
              {gettext(
                "Tables 5 to 8 given to a tournament: table 5 is its board 1. A board that gets one of those table numbers later joins by itself. One board can also be put in a tournament on the Boards page."
              )}
            </p>

            <p
              :if={Enum.any?(@tournaments, &Tournaments.team_event?/1)}
              id="tables-matches-note"
              class="note"
            >
              {gettext(
                "In a team event, \"Keep each match together\" counts the tables match by match: with four boards a match, the fifth table is board 1 of match 2, so a match sits side by side."
              )}
            </p>
          </.panel>

          <.panel :if={@section == :connections} id="setup-connections" title={gettext("Connections")}>
            <p class="note">
              {gettext(
                "A connect code from OpenPairings (Settings, Live boards) brings a tournament - or a whole group of them - to Alnasl: pairings, colours, rate of play, and the results page with its relay key. A round paired there starts here by itself. One hall can hold several codes."
              )}
              <.link navigate={AlnaslWeb.Components.ManualLink.path(:setup)}>{gettext(
                "How, step by step"
              )}</.link>
            </p>
            <SeatingComponents.ask ask={@hall.seating.ask} />
            <ul id="links" class="conns">
              <li :for={link <- @links} id={"link-#{link.id}"} class="conn">
                <% {tone, icon, word} = LinkWords.state(link) %>
                <div class="conn-line">
                  <b class="conn-name">{LinkWords.about(link)}</b>
                  <.badge id={"link-state-#{link.id}"} tone={tone} icon={icon}>{word}</.badge>

                  <details id={"link-menu-#{link.id}"} class="menu">
                    <summary class="btn small" aria-label={gettext("Actions for this connection")}>
                      {gettext("Actions")} <.icon name="chevron" />
                    </summary>

                    <div class="link-menu-list">
                      <.button
                        id={"test-link-#{link.id}"}
                        small
                        variant="ghost"
                        phx-click={
                          JS.push("test_link", value: %{id: to_string(link.id)})
                          |> JS.remove_attribute("open", to: "#link-menu-#{link.id}")
                        }
                        phx-disable-with={gettext("Testing...")}
                      >{gettext("Test connection")}</.button>
                      <.button
                        :if={link.state in ["unauthorized", "unsupported"]}
                        id={"retry-link-#{link.id}"}
                        small
                        variant="ghost"
                        phx-click={
                          JS.push("retry_link", value: %{id: to_string(link.id)})
                          |> JS.remove_attribute("open", to: "#link-menu-#{link.id}")
                        }
                      >{gettext("Try this code again")}</.button>
                      <.button
                        id={"remove-link-#{link.id}"}
                        small
                        variant="danger"
                        phx-click={
                          JS.push("remove_link", value: %{id: to_string(link.id)})
                          |> JS.remove_attribute("open", to: "#link-menu-#{link.id}")
                        }
                        data-confirm={
                          gettext(
                            "Remove this code and its tournaments from Alnasl? Their boards go back to the hall's own tournament, not linked; their games are forgotten here (the PGN files already written stay on the disk). OpenPairings keeps what was reported to it."
                          )
                        }
                      >{gettext("Remove")}</.button>
                    </div>
                  </details>
                </div>

                <p id={"link-line-#{link.id}"} class="dest-line note">
                  {gettext("Last contact: %{t}.", t: when_(link.last_ok_at))}
                  <span :if={link.server_version}>
                    {link.server_name || "OpenPairings"} {link.server_version}.
                  </span>
                  <span>{gettext("Code %{hint}.", hint: Tournaments.secret_hint(link))}</span>
                </p>

                <p :if={LinkWords.why(link)} id={"link-why-#{link.id}"} class="note">
                  {LinkWords.why(link)}
                </p>

                <div
                  :for={found <- Duplicates.shared(link)}
                  id={"link-elsewhere-#{link.id}-#{found.remote_id}"}
                  class="callout"
                  role="status"
                >
                  <p>{LinkWords.elsewhere([found])}</p>

                  <p class="note">
                    {gettext(
                      "Nothing of it is made twice. If this code is meant to replace the other one - that one was withdrawn and this one made new - use this one: the tournament keeps its boards and its games."
                    )}
                  </p>

                  <.button
                    id={"use-code-#{link.id}-#{found.remote_id}"}
                    small
                    phx-click="use_code"
                    phx-value-id={link.id}
                    phx-value-remote={found.remote_id}
                  >{gettext("Use this code for %{name}", name: found.name)}</.button>
                  <%!-- Reached from another hall's code: the same tournament,
                  played here as well, is one more hall, not one more row. --%> <% also =
                    @also_here[{link.id, found.remote_id}] %>
                  <p
                    :if={also != nil}
                    id={"link-elsewhere-hall-#{link.id}-#{found.remote_id}"}
                    class="note"
                  >
                    {gettext(
                      "It is played in another hall. If some of its boards are in this one, play it here as well: it stays one tournament."
                    )}
                  </p>

                  <.button
                    :if={also != nil and also.may?}
                    id={"link-also-here-#{link.id}-#{found.remote_id}"}
                    small
                    phx-click="placement_add"
                    phx-value-t={found.tournament.id}
                    phx-value-hall={also.hall}
                  >{gettext("Also play it in this hall")}</.button>
                </div>

                <p
                  :if={@link_testing == link.id}
                  id={"link-test-running-#{link.id}"}
                  class="note"
                  role="status"
                >
                  {gettext("Asking OpenPairings...")}
                </p>

                <ul
                  :if={@link_tests[link.id]}
                  id={"link-test-#{link.id}"}
                  class="stack bare-list mt-4"
                  role="status"
                >
                  <li
                    :for={{step, result} <- @link_tests[link.id]}
                    id={"link-check-#{link.id}-#{step}"}
                    class="row top nowrap"
                  >
                    <% {tone, sentence} = LinkWords.test_step(step, result) %>
                    <.badge
                      tone={tone}
                      icon={
                        if tone == "ok", do: "ok", else: if(tone == nil, do: "waiting", else: "error")
                      }
                    >
                      {LinkWords.step_name(step)}
                    </.badge>

                    <span>
                      {sentence}
                      <span
                        :for={
                          {found, index} <-
                            Enum.with_index(
                              case result do
                                {:ok, list} when is_list(list) -> list
                                _other -> []
                              end
                            )
                        }
                        id={"link-found-#{link.id}-#{index}"}
                        class="note own-line"
                      >
                        {elem(LinkWords.summary(found), 1)}
                      </span>
                    </span>
                  </li>
                </ul>
              </li>
            </ul>

            <div :if={@links == []} id="links-empty" class="empty">
              <b>{gettext("No connections yet")}</b>
              <p>
                {gettext(
                  "A connection brings tournaments from OpenPairings: paste a connect code (OpenPairings, Settings, Live boards), or connect an OpenPairings account below."
                )}
              </p>
            </div>

            <div class="row">
              <.button
                id="add-connection"
                type="button"
                variant="primary"
                phx-click="toggle_adding"
                aria-expanded={to_string(@adding? or @links == [])}
                aria-controls="add-connection-panel"
              >
                {gettext("+ Add")}
              </.button>
            </div>

            <div
              id="add-connection-panel"
              class={["add-panel", not (@adding? or @links == []) && "is-collapsed"]}
            >
              <div id={"code-wrap-#{@code_key}"}>
                <.form for={@code_form} id="code-form" phx-submit="add_code" class="stack">
                  <.input
                    field={@code_form[:code]}
                    id="code-input"
                    type="password"
                    label={gettext("Connect code")}
                    placeholder="https://.../api/boards/v1#oplt_..."
                    hint={
                      gettext(
                        "Paste the whole line. From the QR code: scan it with the phone's own camera, copy the link it shows instead of opening it, and paste it here. The code is a secret and is not shown again."
                      )
                    }
                    autocomplete="off"
                    spellcheck="false"
                  />
                  <div class="row">
                    <.button id="add-code" variant="primary" type="submit">{gettext("Add")}</.button>
                  </div>
                </.form>
              </div>

              <div :if={@may_connect?} id="op-connect" class="callout mt-5">
                <p class="note mt-0">
                  {gettext(
                    "Or, without a code: connect your OpenPairings account. You sign in there and allow Alnasl once; it then sees every tournament you may edit that is current, including the ones you make later."
                  )}
                </p>

                <.form
                  for={@connect_form}
                  id="op-connect-form"
                  action={~p"/setup/openpairings/connect"}
                  method="post"
                  class="stack"
                >
                  <.input
                    field={@connect_form[:address]}
                    id="op-connect-address"
                    type="text"
                    inputmode="url"
                    label={gettext("OpenPairings address")}
                    placeholder="https://pairings.example.org"
                    autocomplete="url"
                    spellcheck="false"
                  />
                  <div class="row">
                    <.button id="op-connect-button" type="submit">
                      {gettext("Connect an OpenPairings account")}
                    </.button>
                  </div>
                </.form>
              </div>
            </div>
          </.panel>

          <div :if={@section == :results} class="stack">
            <.panel
              :if={@own_hall?}
              id="setup-server"
              title={gettext("Results page of the hall's own tournament")}
            >
              <p class="note">
                {gettext(
                  "Only for a tournament without a connect code: a tournament of OpenPairings brings its results page and relay key with it. Who plays is then said by hand on each board's page, or read from a PGN - Alnasl does not read pairings from the results site."
                )}
              </p>

              <.form for={@server_form} id="server-form" phx-submit="save_server" class="stack">
                <.input
                  field={@server_form[:server_url]}
                  id="server-url"
                  label={gettext("Address of the results site")}
                  placeholder="https://results.example.org"
                  autocomplete="off"
                  spellcheck="false"
                />
                <.input
                  field={@server_form[:tournament]}
                  id="server-tournament"
                  label={gettext("Tournament")}
                  hint={
                    gettext(
                      "Its short name in the link (the part after /t/), or paste the whole link to its page."
                    )
                  }
                  autocomplete="off"
                  spellcheck="false"
                />
                <.input
                  field={@server_form[:relay_key]}
                  id="server-key"
                  type="password"
                  label={gettext("Relay key")}
                  hint={
                    if @key_hint,
                      do:
                        gettext("A key is stored (%{hint}). Leave this empty to keep it.",
                          hint: @key_hint
                        ),
                      else:
                        gettext(
                          "Made for this tournament by an admin of the results site. It starts with orrk_."
                        )
                  }
                  autocomplete="off"
                />
                <div class="row">
                  <.button id="save-server" variant="primary" type="submit">{gettext("Save")}</.button>
                  <.button
                    id="test-connection"
                    type="submit"
                    name="intent"
                    value="test"
                    phx-disable-with={gettext("Testing...")}
                  >
                    {gettext("Test connection")}
                  </.button>
                </div>
              </.form>

              <p :if={ResultsSite.page?(@own)} id="server-site" class="mt-5">
                <.site_link id="server-site-link" href={ResultsSite.tournament_url(@own)}>
                  {gettext("Open the results page: %{address}", address: ResultsSite.display(@own))}
                </.site_link>
              </p>

              <p
                :if={@testing?}
                id="test-running"
                class="note mt-5"
                role="status"
              >
                {gettext("Asking the results site...")}
              </p>

              <ul
                :if={@checks}
                id="test-result"
                class="stack bare-list mt-5"
                role="status"
              >
                <li
                  :for={{step, result} <- @checks}
                  id={"check-#{step}"}
                  class="row top nowrap"
                >
                  <% {tone, sentence} = Words.test_step(step, result) %>
                  <.badge
                    tone={tone}
                    icon={
                      if tone == "ok", do: "ok", else: if(tone == nil, do: "waiting", else: "error")
                    }
                  >
                    {Words.step_name(step)}
                  </.badge>
                  <span>{sentence}</span>
                </li>
              </ul>
            </.panel>

            <.panel :if={@own_hall?} id="setup-lichess" title={gettext("Lichess broadcast")}>
              <p class="note">
                {gettext(
                  "Optional. Alnasl pushes each game of one round to a Lichess broadcast round as it changes - besides the results site, and without waiting for it. On Lichess, make the broadcast and its round first; leave the round's source empty."
                )}
                <.link navigate={AlnaslWeb.Components.ManualLink.path(:lichess)}>{gettext(
                  "How, step by step"
                )}</.link>
              </p>

              <form
                :if={length(@tournaments) > 1}
                id="lichess-tournament-form"
                phx-change="pick_lichess"
                class="row mb-4"
              >
                <label for="lichess-tournament" class="note">{gettext("Tournament")}</label>
                <select id="lichess-tournament" name="tournament_id" class="input fit">
                  <option :for={t <- @tournaments} value={t.id} selected={t.id == @lichess.id}>
                    {Tournaments.title(t) || gettext("The hall's own tournament")}
                  </option>
                </select>
              </form>

              <.form for={@lichess_form} id="lichess-form" phx-submit="save_lichess" class="stack">
                <.input
                  field={@lichess_form[:round]}
                  id="lichess-round"
                  label={gettext("The round on Lichess")}
                  hint={
                    gettext(
                      "Paste the link to the round (lichess.org/broadcast/.../ID), or the ID itself."
                    )
                  }
                  autocomplete="off"
                  spellcheck="false"
                />
                <.input
                  field={@lichess_form[:token]}
                  id="lichess-token"
                  type="password"
                  label={gettext("Lichess token")}
                  hint={
                    if @lichess_hint,
                      do:
                        gettext("A token is stored (%{hint}). Leave this empty to keep it.",
                          hint: @lichess_hint
                        ),
                      else:
                        gettext(
                          "A personal access token of the broadcast's owner, with the permission to create and update studies and broadcasts (study:write). It starts with lip_."
                        )
                  }
                  autocomplete="off"
                />
                <.input
                  field={@lichess_form[:round_no]}
                  id="lichess-round-no"
                  type="number"
                  min="1"
                  max="999"
                  label={gettext("Which round of the tournament it is")}
                />
                <.input
                  field={@lichess_form[:enabled]}
                  id="lichess-enabled"
                  type="checkbox"
                  label={gettext("Send the games of that round to Lichess")}
                />
                <div class="row">
                  <.button id="save-lichess" variant="primary" type="submit">{gettext("Save")}</.button>
                  <.button
                    id="test-lichess"
                    type="submit"
                    name="intent"
                    value="test"
                    phx-disable-with={gettext("Testing...")}
                  >
                    {gettext("Test")}
                  </.button>

                  <.button
                    :if={@lichess_hint || @lichess_round_id not in [nil, ""]}
                    id="clear-lichess"
                    type="button"
                    variant="danger"
                    phx-click="clear_lichess"
                    data-confirm={gettext("Forget the Lichess round and its token?")}
                  >
                    {gettext("Forget")}
                  </.button>
                </div>
              </.form>

              <p
                :if={@lichess_testing?}
                id="lichess-test-running"
                class="note mt-5"
                role="status"
              >
                {gettext("Asking Lichess...")}
              </p>

              <ul
                :if={@lichess_checks}
                id="lichess-test-result"
                class="stack bare-list mt-5"
                role="status"
              >
                <li
                  :for={{step, result} <- @lichess_checks}
                  id={"lichess-check-#{step}"}
                  class="row top nowrap"
                >
                  <% {tone, sentence} = DestinationWords.test_step(step, result) %>
                  <.badge
                    tone={tone}
                    icon={
                      if tone == "ok", do: "ok", else: if(tone == nil, do: "waiting", else: "error")
                    }
                  >
                    {DestinationWords.step_name(step)}
                  </.badge>
                  <span>{sentence}</span>
                </li>
              </ul>

              <p class="note mt-5">
                {gettext(
                  "The test asks Lichess who the token belongs to and whether the round exists. It sends no game and changes nothing there."
                )}
              </p>
            </.panel>
          </div>

          <div :if={@section == :this_box} class="stack">
            <.panel id="setup-about" title={gettext("This copy of Alnasl")}>
              <dl class="kv">
                <dt>{gettext("Version")}</dt>

                <dd id="about-version">{@about.version}</dd>

                <dt>{gettext("Edition")}</dt>

                <dd id="about-edition">
                  <%= if @server? do %>
                    {gettext("Server: the boards come from Arkab bridges in the halls.")}
                    <.link id="about-edition-wizard" patch={~p"/setup/wizard"}>
                      {gettext("Setup wizard")}
                    </.link>
                  <% else %>
                    {gettext("Box (in a hall)")}
                  <% end %>
                </dd>

                <dt>{gettext("Started as")}</dt>

                <dd id="about-kind">{Words.install_kind(@about.kind)}</dd>

                <dt>{gettext("Data folder")}</dt>

                <dd id="about-data" class="mono">{@about.data_dir}</dd>

                <dt>{gettext("Knows")}</dt>

                <dd id="about-counts">
                  {ngettext("%{count} board", "%{count} boards", @about.boards, count: @about.boards)}, {ngettext(
                    "%{count} tournament",
                    "%{count} tournaments",
                    @about.tournaments,
                    count: @about.tournaments
                  )}
                </dd>
              </dl>

              <p id="about-note" class="note">
                {gettext(
                  "The boards, their table numbers and the tournaments are kept in the data folder, and stay through updates and reinstalls. A second copy of Alnasl started another way on the same computer (from source, installed, portable) has a data folder of its own, so it has its own boards, numbers and tournaments."
                )}
              </p>
            </.panel>

            <.panel
              :if={@box_admin?}
              id="setup-box"
              title={if(@server?, do: gettext("This server"), else: gettext("This box"))}
            >
              <.form for={@box_form} id="box-form" phx-submit="save_box" class="stack">
                <div class="form-grid">
                  <.input
                    :if={not @server?}
                    field={@box_form[:box_name]}
                    id="box-name"
                    label={gettext("Name")}
                    hint={gettext("Shown at the top left: tells two boxes apart.")}
                    maxlength="40"
                  />
                  <.input
                    field={@box_form[:locale]}
                    id="box-locale"
                    type="select"
                    label={gettext("Default language")}
                    options={[{"English", "en"}, {"Nederlands", "nl"}]}
                    hint={gettext("Used until somebody picks a language of their own.")}
                  />
                  <.input
                    field={@box_form[:round]}
                    id="box-round"
                    type="number"
                    min="1"
                    max="999"
                    label={gettext("Round in play (the hall's own tournament)")}
                  />
                  <.input
                    field={@box_form[:clock_heartbeat_s]}
                    id="box-heartbeat"
                    type="number"
                    min="5"
                    max="600"
                    label={gettext("Send the clocks every (seconds)")}
                  />
                  <.input
                    field={@box_form[:capture_cap_mb]}
                    id="box-cap"
                    type="number"
                    min="10"
                    label={gettext("Keep at most this much raw capture (MB)")}
                  />
                </div>

                <.input
                  field={@box_form[:auto_suggest]}
                  id="box-auto"
                  type="checkbox"
                  label={
                    gettext("Offer mate and stalemate to the results site without waiting for me")
                  }
                  hint={
                    gettext(
                      "Off: every result waits for the arbiter. On: a game that ends in mate or stalemate on the board is sent as finished at once - still provisional on the site."
                    )
                  }
                />
                <.input
                  field={@box_form[:new_game_on_setup]}
                  id="box-new-game"
                  type="select"
                  label={gettext("Start a new game when the pieces are set up again")}
                  options={[
                    {gettext("On boards no pairing names (the default)"), "unpaired"},
                    {gettext("Always"), "always"},
                    {gettext("Never: only \"New game\" on the board's page"), "never"}
                  ]}
                  hint={
                    gettext(
                      "For game after game on one board: when the starting position is back on a board whose game is over - or is more than two moves old - Alnasl closes that game and begins the next. In a paired round a board has one game, so by default this is left to the arbiter there."
                    )
                  }
                />
                <div class="row">
                  <.button id="save-box" variant="primary" type="submit">{gettext("Save")}</.button>
                </div>
              </.form>
            </.panel>

            <.panel :if={@server?} id="setup-phone" title={gettext("Open this site on your phone")}>
              <Access.phone
                id="setup-phone-access"
                signin={@phone_signin}
                accounts?={not @current_scope.open?}
              />
            </.panel>

            <.panel :if={@server?} id="setup-accounts" title={gettext("Accounts")}>
              <:actions><AlnaslWeb.Components.ManualLink.manual_link topic={:accounts} /></:actions>

              <%= cond do %>
                <% @accounts? or @server? -> %>
                  <p class="note">
                    {gettext(
                      "Every page asks who you are. People, roles and invitations are on the page of each hall."
                    )}
                  </p>

                  <div class="row">
                    <.button id="setup-halls" navigate={~p"/halls"} icon="boards">
                      {gettext("Halls")}
                    </.button>

                    <.button id="setup-account" href={~p"/account"} variant="ghost">
                      {gettext("Your account")}
                    </.button>

                    <.button
                      id="setup-bridges-link"
                      navigate={~p"/halls/#{@hall_id}/bridges"}
                      variant="ghost"
                    >
                      {gettext("Bridges of this hall")}
                    </.button>
                  </div>
                <% true -> %>
                  <p class="note">
                    {gettext(
                      "This box has no accounts: everybody on the hall's network may do everything (behind the PIN, if there is one). The first account makes you the box's owner and admin - and from then on every page asks who is there, the box's own screen included."
                    )}
                  </p>

                  <.form
                    for={@first_form}
                    id="first-account-form"
                    action={~p"/accounts/first"}
                    method="post"
                    class="stack"
                  >
                    <.input
                      field={@first_form[:email]}
                      type="text"
                      label={gettext("Email address")}
                      autocomplete="username"
                      required
                    />
                    <.input
                      field={@first_form[:password]}
                      type="password"
                      label={
                        gettext("Password (at least %{n} characters)",
                          n: Alnasl.Accounts.User.min_password()
                        )
                      }
                      autocomplete="new-password"
                      required
                    />
                    <.button id="first-account-submit" variant="primary" type="submit">
                      {gettext("Make the first account")}
                    </.button>
                  </.form>
              <% end %>
            </.panel>
          </div>

          <div :if={@section == :access} class="stack">
            <.panel
              :if={@box_admin? and not @accounts? and not @server?}
              id="setup-pin"
              title={gettext("Access from other machines")}
            >
              <p class="note">
                {gettext(
                  "The box itself is always let in. A browser on another machine in the hall is let in freely, unless a PIN is set here. Other machines can only reach the box at all when that is switched on below."
                )}
              </p>

              <div id="listen" class="callout">
                <p id="listen-now">
                  <%= if @listening_lan? do %>
                    <.badge tone="ok" icon="ok">
                      {gettext("Reachable from the hall's network")}
                    </.badge>
                  <% else %>
                    <.badge icon="waiting">{gettext("This box only")}</.badge>
                  <% end %>

                  <span :if={@listen_forced} id="listen-forced" class="note">
                    {gettext(
                      "Decided where the program is started (ALNASL_LISTEN), so there is no switch here."
                    )}
                  </span>

                  <span
                    :if={!@listen_forced && @listen == "lan" != @listening_lan?}
                    id="listen-pending"
                    class="note"
                  >
                    {gettext("Changed. It takes effect the next time Alnasl starts.")}
                  </span>
                </p>

                <div :if={!@listen_forced} class="row">
                  <.button
                    :if={@listen == "local"}
                    id="listen-lan"
                    type="button"
                    phx-click="set_listen"
                    phx-value-choice="lan"
                    disabled={!@pin_set?}
                  >
                    {gettext("Let other machines in the hall open this site")}
                  </.button>

                  <.button
                    :if={@listen == "lan"}
                    id="listen-local"
                    type="button"
                    phx-click="set_listen"
                    phx-value-choice="local"
                  >
                    {gettext("This box only")}
                  </.button>

                  <span :if={@listen == "local" && !@pin_set?} id="listen-needs-pin" class="note">
                    {gettext("Set a PIN first.")}
                  </span>
                </div>

                <p class="note">
                  {gettext(
                    "The first time, Windows asks whether the program may be reached from the network. Say yes for private networks."
                  )}
                </p>
              </div>

              <p id="pin-state">
                <.badge :if={@pin_set?} tone="ok" icon="ok">{gettext("A PIN is set")}</.badge>

                <.badge :if={!@pin_set?} icon="waiting">{gettext("No PIN")}</.badge>
              </p>

              <p :if={@pin_short?} id="pin-short" class="note">
                {gettext(
                  "This PIN may be shorter than 6 characters, which is quickly guessed. Set a new one."
                )}
              </p>

              <.form
                for={@pin_form}
                id="pin-form"
                phx-submit="save_pin"
                class="row align-end"
              >
                <.input
                  field={@pin_form[:pin]}
                  id="pin-input"
                  type="password"
                  label={gettext("New PIN")}
                  autocomplete="new-password"
                /> <.button id="save-pin" type="submit">{gettext("Set the PIN")}</.button>
                <.button
                  :if={@pin_set?}
                  id="clear-pin"
                  type="button"
                  variant="danger"
                  phx-click="clear_pin"
                  data-confirm={
                    gettext("Remove the PIN? Any browser that can reach the box will be let in.")
                  }
                >
                  {gettext("Remove the PIN")}
                </.button>
              </.form>
            </.panel>

            <.panel id="setup-phone" title={gettext("Open this site on your phone")}>
              <Access.phone
                id="setup-phone-access"
                signin={@phone_signin}
                accounts?={not @current_scope.open?}
              />
            </.panel>

            <.panel id="setup-accounts" title={gettext("Accounts")}>
              <:actions><AlnaslWeb.Components.ManualLink.manual_link topic={:accounts} /></:actions>

              <%= cond do %>
                <% @accounts? or @server? -> %>
                  <p class="note">
                    {gettext(
                      "Every page asks who you are. People, roles and invitations are on the page of each hall."
                    )}
                  </p>

                  <div class="row">
                    <.button id="setup-halls" navigate={~p"/halls"} icon="boards">
                      {gettext("Halls")}
                    </.button>

                    <.button id="setup-account" href={~p"/account"} variant="ghost">
                      {gettext("Your account")}
                    </.button>

                    <.button
                      id="setup-bridges-link"
                      navigate={~p"/halls/#{@hall_id}/bridges"}
                      variant="ghost"
                    >
                      {gettext("Bridges of this hall")}
                    </.button>
                  </div>
                <% true -> %>
                  <p class="note">
                    {gettext(
                      "This box has no accounts: everybody on the hall's network may do everything (behind the PIN, if there is one). The first account makes you the box's owner and admin - and from then on every page asks who is there, the box's own screen included."
                    )}
                  </p>

                  <.form
                    for={@first_form}
                    id="first-account-form"
                    action={~p"/accounts/first"}
                    method="post"
                    class="stack"
                  >
                    <.input
                      field={@first_form[:email]}
                      type="text"
                      label={gettext("Email address")}
                      autocomplete="username"
                      required
                    />
                    <.input
                      field={@first_form[:password]}
                      type="password"
                      label={
                        gettext("Password (at least %{n} characters)",
                          n: Alnasl.Accounts.User.min_password()
                        )
                      }
                      autocomplete="new-password"
                      required
                    />
                    <.button id="first-account-submit" variant="primary" type="submit">
                      {gettext("Make the first account")}
                    </.button>
                  </.form>
              <% end %>
            </.panel>
          </div>

          <div :if={@section == :updates} class="stack">
            <.panel :if={@box_admin? and not @server?} id="setup-updates" title={gettext("Updates")}>
              <p id="update-version">
                {gettext("This is Alnasl %{version}.", version: Updates.current_version())}
                <a href={Updates.releases_page()} target="_blank" rel="noopener">
                  {gettext("All versions and what changed")}
                </a>
              </p>

              <form id="update-mode-form" phx-change="save_update_mode" class="stack">
                <fieldset class="field">
                  <legend>{gettext("Look for a new version")}</legend>

                  <label class="check" for="update-mode-ask">
                    <input
                      type="radio"
                      id="update-mode-ask"
                      name="mode"
                      value="ask"
                      checked={@update_mode == "ask"}
                    />
                    <span>
                      {gettext("Yes, and tell me when there is one")}
                      <span class="hint own-line">
                        {gettext(
                          "One small question to GitHub every half hour. Nothing is downloaded and nothing is installed until you say so."
                        )}
                      </span>
                    </span>
                  </label>

                  <label class="check" for="update-mode-never">
                    <input
                      type="radio"
                      id="update-mode-never"
                      name="mode"
                      value="never"
                      checked={@update_mode == "never"}
                    /> <span>{gettext("Never")}</span>
                  </label>
                </fieldset>
              </form>

              <div class="row mt-4">
                <.button id="check-update" type="button" phx-click="check_update">
                  {gettext("Look now")}
                </.button>

                <span :if={@update_looked == :current} id="update-looked-current" class="note">
                  {gettext("This is the newest version.")}
                </span>

                <span :if={@update_looked == :error} id="update-looked-error" class="note">
                  {gettext(
                    "GitHub could not be reached, or gave no answer. That needs the internet; nothing else here does."
                  )}
                </span>
              </div>

              <div
                :if={match?({:failed, _, _}, @update_result)}
                id="update-failed"
                class="callout bad mt-5"
                role="status"
              >
                <p>
                  {gettext(
                    "The last update (to %{version}) did not succeed, and the version before it was put back: %{why}",
                    version: elem(@update_result, 1),
                    why: elem(@update_result, 2)
                  )}
                </p>
              </div>

              <div :if={@update_available} id="update-offer" class="callout mt-5">
                <p>
                  <b>
                    {gettext("Alnasl %{version} is out.", version: @update_available.version)}
                  </b>

                  <span :if={@update_available.size} id="update-size">
                    {gettext("The download is %{size}.",
                      size: Words.megabytes(@update_available.size)
                    )}
                  </span>

                  <a id="update-notes" href={@update_available.url} target="_blank" rel="noopener">
                    {gettext("What is new")}
                  </a>
                </p>

                <%= cond do %>
                  <% @update_step == :going -> %>
                    <p id="update-going" role="status">
                      {gettext(
                        "Downloading and installing. Alnasl stops and starts again by itself; this page comes back when it has. If the update fails, the version you have now is started again."
                      )}
                    </p>
                  <% @update_kind == :manual -> %>
                    <div id="update-manual">
                      <p>{gettext("This copy does not update itself. To get the new version:")}</p>

                      <ul>
                        <li>
                          {gettext(
                            "Windows, from the zip: download the new zip from the page above, unzip it beside the old folder and start Alnasl there. Your data is not in the folder and is used as it is."
                          )}
                        </li>

                        <li>
                          {gettext(
                            "Mac: download the new zip from the page above, stop Alnasl, and put the new Alnasl.app in place of the old one in Applications. Your data is not in the app and is used as it is."
                          )}
                        </li>

                        <li>
                          {gettext("Linux, installed with install.sh: run this on the box:")}
                          <code>sudo /opt/alnasl/update.sh</code>
                        </li>

                        <li>
                          {gettext("From the source code: fetch the new version and build it again.")}
                        </li>
                      </ul>
                    </div>
                  <% @update_step == :games -> %>
                    <div id="update-games" class="callout bad" role="alert">
                      <p>
                        {gettext(
                          "Not now: %{boards} - a game is being played there. An update stops Alnasl for about a minute, and moves played in that minute are not read. Wait until the games are over.",
                          boards: board_list(@update_games)
                        )}
                      </p>

                      <div class="row">
                        <.button
                          id="update-cancel"
                          type="button"
                          variant="primary"
                          phx-click="update_cancel"
                        >
                          {gettext("Wait")}
                        </.button>

                        <.button
                          id="update-force"
                          type="button"
                          variant="danger"
                          phx-click="update_apply"
                          phx-value-force="yes"
                          data-confirm={
                            gettext(
                              "Install now, while games are being played? Moves played while Alnasl restarts are not read and have to be put right by hand."
                            )
                          }
                        >
                          {gettext("Install anyway")}
                        </.button>
                      </div>
                    </div>
                  <% @update_step == :confirm -> %>
                    <div id="update-confirm" role="alert">
                      <p>
                        <%= if @update_available.size do %>
                          {gettext(
                            "This downloads up to %{size} over this box's internet connection, then stops Alnasl and starts the new version. It takes about a minute; the boards are not read meanwhile. Your data stays where it is.",
                            size: Words.megabytes(@update_available.size)
                          )}
                        <% else %>
                          {gettext(
                            "This downloads the new version over this box's internet connection (some tens of megabytes), then stops Alnasl and starts the new version. It takes about a minute; the boards are not read meanwhile. Your data stays where it is."
                          )}
                        <% end %>
                      </p>

                      <div class="row">
                        <.button
                          id="update-yes"
                          type="button"
                          variant="primary"
                          phx-click="update_apply"
                        >
                          {gettext("Yes, download and install")}
                        </.button>

                        <.button id="update-cancel" type="button" phx-click="update_cancel">
                          {gettext("Not now")}
                        </.button>
                      </div>
                    </div>
                  <% true -> %>
                    <div class="row">
                      <.button
                        id="update-start"
                        type="button"
                        variant="primary"
                        phx-click="update_start"
                      >
                        {gettext("Download and install...")}
                      </.button>
                    </div>
                <% end %>
              </div>

              <form
                :if={@autostart?}
                id="autostart-form"
                phx-change="set_autostart"
                class="stack mt-5"
              >
                <label class="check" for="autostart">
                  <input type="hidden" name="on" value="false" />
                  <input
                    type="checkbox"
                    id="autostart"
                    name="on"
                    value="true"
                    checked={@autostart_on?}
                  />
                  <span>
                    {gettext("Start Alnasl when Windows starts")}
                    <span class="hint own-line">
                      {gettext(
                        "For a computer that stays in the hall. It starts without opening the browser; the small Alnasl window is how you stop it."
                      )}
                    </span>
                  </span>
                </label>
              </form>
            </.panel>
          </div>

          <div :if={@section == :advanced} class="stack">
            <.panel :if={@box_admin?} id="setup-tracker" title={gettext("How patient the tracker is")}>
              <p class="note">
                {gettext(
                  "Times are in milliseconds. The defaults suit classical and rapid play, time scrambles included; leave them unless a hall teaches you otherwise."
                )}
              </p>

              <div id="tracker-presets" class="callout">
                <div class="row">
                  <.button
                    id="preset-bullet"
                    type="button"
                    phx-click="preset_tracker"
                    phx-value-preset="bullet"
                  >
                    {gettext("Bullet / fast play")}
                  </.button>

                  <.badge :if={@fast?} id="preset-bullet-on" tone="ok" icon="ok">
                    {gettext("Set for fast play")}
                  </.badge>
                </div>

                <p class="note">
                  {gettext(
                    "For games of a few minutes or less. It changes two things: a move must stand for %{settle} ms instead of %{settle_default}, and a board put back to the position before the last move is not read as a takeback - at that speed it is a piece going to and fro. Nothing else is touched, how many moves Alnasl reconstructs included. \"Back to the defaults\" undoes it.",
                    settle: @preset.settle_ms,
                    settle_default: @defaults.settle_ms
                  )}
                </p>
              </div>

              <.form for={@tracker_form} id="tracker-form" phx-submit="save_tracker" class="stack">
                <div class="form-grid">
                  <.input
                    field={@tracker_form[:settle_ms]}
                    id="tracker-settle"
                    type="number"
                    min="0"
                    label={gettext("A move must stand for")}
                  />
                  <.input
                    field={@tracker_form[:castle_hold_ms]}
                    id="tracker-castle"
                    type="number"
                    min="0"
                    label={gettext("A rook move that may be castling")}
                  />
                  <.input
                    field={@tracker_form[:promotion_hold_ms]}
                    id="tracker-promo"
                    type="number"
                    min="0"
                    label={gettext("A pawn waiting for its piece")}
                  />
                  <.input
                    field={@tracker_form[:takeback_settle_ms]}
                    id="tracker-takeback-ms"
                    type="number"
                    min="0"
                    label={gettext("A takeback must stand for")}
                  />
                  <.input
                    field={@tracker_form[:transient_ms]}
                    id="tracker-transient"
                    type="number"
                    min="0"
                    label={gettext("Unexplained board: alarm after")}
                  />
                  <.input
                    field={@tracker_form[:lifted_ms]}
                    id="tracker-lifted"
                    type="number"
                    min="0"
                    label={gettext("Piece off the board: alarm after")}
                  />
                  <.input
                    field={@tracker_form[:search_depth]}
                    id="tracker-depth"
                    type="number"
                    min="2"
                    max="12"
                    label={gettext("Reconstruct up to (half-moves)")}
                  />
                  <p id="tracker-depth-note" class="note">
                    {gettext(
                      "When the board has run ahead of the game, Alnasl looks for the moves in between rather than stop: up to this many (%{default} by default) over the squares it saw change, and up to 4 when it saw nothing of them. Every move found that way is marked: \"reconstructed\" when one line of moves fits, \"guessed\" when several did and one was taken. 2 is the least: one move missed and the next one seen.",
                      default: @defaults.search_depth
                    )}
                  </p>

                  <.input
                    field={@tracker_form[:promotion_default]}
                    id="tracker-default"
                    type="select"
                    label={gettext("Pawn left on the last rank counts as")}
                    options={[
                      {gettext("queen"), "q"},
                      {gettext("rook"), "r"},
                      {gettext("bishop"), "b"},
                      {gettext("knight"), "n"}
                    ]}
                  />
                </div>

                <.input
                  field={@tracker_form[:takeback]}
                  id="tracker-takeback"
                  type="checkbox"
                  label={
                    gettext("A board put back to the position before the last move is a takeback")
                  }
                />
                <.input
                  field={@tracker_form[:unseen_piece]}
                  id="tracker-unseen"
                  type="checkbox"
                  label={
                    gettext(
                      "A piece that leaves its square while the game goes on is still there (a warning, not an alarm)"
                    )
                  }
                />
                <p id="tracker-unseen-note" class="note">
                  {gettext(
                    "A player parks a piece beside the board, or a sensor loses one: Alnasl follows the moves and shows \"not seen on ...\" until the piece is seen again, moves, or is taken. One piece at a time; a king never. Off: such a board waits, and becomes an alarm."
                  )}
                </p>

                <div class="row">
                  <.button id="save-tracker" variant="primary" type="submit">{gettext("Save")}</.button>
                  <.button id="reset-tracker" type="button" phx-click="reset_tracker">{gettext(
                    "Back to the defaults"
                  )}</.button>
                </div>
              </.form>
            </.panel>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
