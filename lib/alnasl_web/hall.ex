defmodule AlnaslWeb.Hall do
  @moduledoc """
  What every page of the site needs before it draws anything: the language,
  the box's name, the connection to the results server - kept current - and
  the answer to "may this browser be here at all".

  ## Who may be here

  The box itself always may: a request from the loopback address is the
  kiosk browser on the box. A browser on another machine in the hall may
  when no PIN is set, or once it has given the PIN (`/unlock`). The plug
  (`gate/2`) decides for ordinary requests and notes in the session how the
  browser came in; `on_mount/4` reads that note for the LiveView socket.

  ## The notice of a newer version

  `update` is `Alnasl.Updates.notice/0`: the release the box heard of, or
  `nil`. The frame shows it on every page, and its two buttons that install
  nothing - "Later" and "Don't ask again" - are answered here, once, for
  every page. Installing is Setup's, where there is room to say what it
  costs.
  """

  import Plug.Conn
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, put_flash: 3, redirect: 2]

  use Gettext, backend: AlnaslWeb.Gettext

  alias Alnasl.{Accounts, Boards, Outbox, Seating, Settings, Tournaments, Updates}
  alias Alnasl.Accounts.Scope
  alias AlnaslWeb.UserAuth
  alias AlnaslWeb.Status

  # --- the plug ----------------------------------------------------------------

  @doc "Puts the language in place for a controller request."
  def put_locale(conn, _opts) do
    Gettext.put_locale(AlnaslWeb.Gettext, locale())
    conn
  end

  @doc """
  With accounts (or on the server): the signed-in, and nobody else - the
  box itself included, because on a server every request arrives from the
  tunnel on the loopback address. Without: the box, and anybody else once
  they have given the PIN. Needs `AlnaslWeb.UserAuth.fetch_current_scope/2`
  before it.
  """
  def gate(conn, _opts) do
    local? = loopback?(conn.remote_ip)
    conn = put_session(conn, :local, local?)

    cond do
      Accounts.login_required?() ->
        case conn.assigns[:current_scope] do
          %Scope{user: %{must_change_password: true}} ->
            conn |> Phoenix.Controller.redirect(to: "/account") |> halt()

          %Scope{user: %{}} ->
            conn

          _nobody ->
            conn
            |> then(
              &if(&1.method == "GET",
                do: put_session(&1, :user_return_to, &1.request_path),
                else: &1
              )
            )
            |> Phoenix.Controller.redirect(to: "/log-in")
            |> halt()
        end

      allowed?(local?, get_session(conn, :unlocked)) or conn.request_path == "/unlock" ->
        conn

      true ->
        conn |> Phoenix.Controller.redirect(to: "/unlock") |> halt()
    end
  end

  @doc "May a browser in on a box without accounts: the box itself, the PIN given, or no PIN."
  def allowed?(local?, unlocked), do: local? or unlocked == true or not Settings.pin_set?()

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 65_535, 32_512, _}), do: true
  defp loopback?(_other), do: false

  defp locale do
    case Settings.get("locale") do
      locale when locale in ["en", "nl"] -> locale
      _other -> "en"
    end
  end

  # --- the LiveView hook -------------------------------------------------------

  def on_mount(:default, _params, session, socket) do
    locale = locale()
    Gettext.put_locale(AlnaslWeb.Gettext, locale)

    case mount_scope(session) do
      # An account in no hall yet has one page: the one that says so.
      {:ok, %Scope{hall: nil, open?: false}} when socket.view != AlnaslWeb.HallsLive ->
        {:halt, redirect(socket, to: "/halls")}

      {:ok, scope} ->
        if connected?(socket) do
          Outbox.subscribe()
          Settings.subscribe()
          Updates.subscribe()
          Tournaments.subscribe()
        end

        socket =
          socket
          |> assign(
            current_scope: scope,
            link: Outbox.status(),
            box: Settings.get("box_name") || "Alnasl",
            locale: locale,
            update: Scope.can?(scope, :admin) && Updates.notice(),
            phone_signin: nil
          )
          |> refresh()
          # First: nothing below, and no page, sees an event the scope may not send.
          |> attach_hook(:permit, :handle_event, &AlnaslWeb.Permit.check/3)
          |> attach_hook(:hall, :handle_info, &info/2)
          |> attach_hook(:hall_update, :handle_event, &update_event/3)
          |> attach_hook(:hall_seating, :handle_event, &seating_event/3)
          |> attach_hook(:hall_phone, :handle_event, &phone_event/3)

        {:cont, socket}

      {:redirect, to} ->
        {:halt, redirect(socket, to: to)}
    end
  end

  # Who the page is for: `{:ok, scope}`, or where to send the browser.
  defp mount_scope(session) do
    if Accounts.login_required?() do
      case UserAuth.session_user(session) do
        %{must_change_password: true} -> {:redirect, "/account"}
        %{} = user -> {:ok, Accounts.scope(user, session["hall_id"])}
        nil -> {:redirect, "/log-in"}
      end
    else
      if allowed?(session["local"] == true, session["unlocked"]),
        do: {:ok, Accounts.scope(nil, session["hall_id"])},
        else: {:redirect, "/unlock"}
    end
  end

  # "A sign-in code for a phone": a link that signs the phone in as this
  # account, once, within five minutes (`Alnasl.Accounts.create_qr_token/1`).
  defp phone_event("phone_signin", params, socket) do
    case socket.assigns.current_scope do
      %Scope{user: %{} = user} ->
        token = Accounts.create_qr_token(user)
        to = AlnaslWeb.UserAuth.safe(params["to"])

        {:halt,
         assign(socket,
           phone_signin: %{
             path: "/log-in/qr/" <> token <> "?" <> URI.encode_query(%{"to" => to}),
             expires_at:
               DateTime.add(
                 DateTime.utc_now(:second),
                 Alnasl.Accounts.UserToken.qr_minutes() * 60
               )
           }
         )}

      _open ->
        {:halt, socket}
    end
  end

  defp phone_event(_event, _params, socket), do: {:cont, socket}

  # Keeps the connection badge and the box's name current on every page. The
  # message goes on to the page, which may care too.
  # Only the badges move with the queue; the lines about boards wait for a
  # change of tournaments or boards.
  defp info(:outbox_changed, socket) do
    link = Outbox.status()
    hall = socket.assigns[:hall]
    socket = assign(socket, link: link)

    {:cont,
     if(hall,
       do:
         assign(socket, hall: %{hall | heads: Status.heads(link, socket.assigns[:current_scope])}),
       else: refresh(socket)
     )}
  end

  defp info({:setting, "box_name"}, socket) do
    {:cont, assign(socket, link: Outbox.status(), box: Settings.get("box_name") || "Alnasl")}
  end

  # A tournament, a code or a board's place changed: which boards are
  # outside, what is asked, what the badges say.
  defp info({:tournament, _id}, socket), do: {:cont, refresh(socket)}

  defp info(:update_changed, socket),
    do:
      {:cont,
       assign(socket,
         update: Scope.can?(socket.assigns.current_scope, :admin) && Updates.notice()
       )}

  defp info(_other, socket), do: {:cont, socket}

  # Both halt: no page has a clause for them, and a second click on a notice
  # that is already gone must not be a page's crash.
  defp update_event("update_later", _params, socket) do
    with %{version: version} <- socket.assigns[:update], do: Updates.later(version)
    {:halt, assign(socket, update: nil)}
  end

  defp update_event("update_never", _params, socket) do
    Updates.put_mode("never")
    {:halt, assign(socket, update: nil)}
  end

  defp update_event(_event, _params, socket), do: {:cont, socket}

  @doc "The badges and the lines about boards, drawn again (a page that changed them says so)."
  def refresh(socket),
    do: assign(socket, hall: Status.build(socket.assigns.link, socket.assigns[:current_scope]))

  # --- the answers to the lines about boards and tournaments ---------------------

  # The browser asks "are you there?" every few seconds; the time it takes
  # to be answered is the number in the bar.
  defp seating_event("live_ping", _params, socket), do: {:halt, %{}, socket}

  defp seating_event("seat_put", %{"board" => board, "t" => t} = params, socket) do
    mode = if params["mode"] == "fresh", do: :fresh, else: :adopt

    with %{} = board <- Boards.get(board),
         %{} = tournament <- Tournaments.get(t) do
      {:ok, _board, carried} = Seating.put(board, tournament, carry: mode)
      {:halt, socket |> put_flash(:info, put_words(board, tournament, carried)) |> refresh()}
    else
      _gone -> {:halt, refresh(socket)}
    end
  end

  defp seating_event("seat_tables", %{"seat" => %{"id" => id} = params}, socket) do
    from = int(params["from"])
    to = int(params["to"]) || from

    with %{} = tournament <- Tournaments.get(id),
         true <- from != nil,
         hall_id = Scope.hall_id(socket.assigns[:current_scope]),
         {:ok, tournament, carried} <- Seating.assign_range(tournament, from, to, hall_id) do
      {:halt,
       socket
       |> put_flash(:info, range_words(tournament, from, to, carried, hall_id))
       |> refresh()}
    else
      _bad ->
        {:halt,
         socket
         |> put_flash(:error, gettext("Give the first and the last table: 5 and 8."))
         |> refresh()}
    end
  end

  defp seating_event("seat_decline", %{"t" => id}, socket) do
    with %{} = tournament <- Tournaments.get(id), do: Seating.decline(tournament)
    {:halt, refresh(socket)}
  end

  defp seating_event("seat_undo", _params, socket) do
    flash =
      case Seating.undo_auto() do
        :ok -> gettext("Undone: the boards play where they played before.")
        _nothing -> gettext("There is nothing to undo.")
      end

    {:halt, socket |> put_flash(:info, flash) |> refresh()}
  end

  defp seating_event("seat_dismiss", _params, socket) do
    Seating.dismiss_auto()
    {:halt, refresh(socket)}
  end

  defp seating_event(_event, _params, socket), do: {:cont, socket}

  defp int(text) do
    case Integer.parse(to_string(text)) do
      {n, ""} when n > 0 -> n
      _other -> nil
    end
  end

  @doc "What was done when a board was put in a tournament, in a sentence."
  def put_words(board, tournament, carried) do
    name = Tournaments.title(tournament) || ""
    base = gettext("%{board} now plays in %{tournament}.", board: board.name, tournament: name)
    base <> carried_words(carried)
  end

  @doc "What was done when a range of tables was given to a tournament."
  def range_words(tournament, from, to, carried, hall_id \\ nil) do
    name = Tournaments.title(tournament) || gettext("this box's own tournament")

    # Board 1, unless the tournament's first boards are played in another hall.
    case Alnasl.Placements.in_hall(tournament, hall_id || Alnasl.Halls.of(tournament)) do
      %{first_board: first} when first > 1 ->
        gettext("Tables %{from}-%{to} play in %{name}: table %{from} is its board %{first}.",
          from: from,
          to: to,
          name: name,
          first: first
        )

      _first ->
        gettext("Tables %{from}-%{to} play in %{name}: table %{from} is its board 1.",
          from: from,
          to: to,
          name: name
        )
    end <> Enum.join(Enum.map(carried, &carried_words/1))
  end

  @doc "A game that was under way on a board that moved, and what became of it."
  def carried_words(nil), do: ""

  def carried_words(%{outcome: :adopted} = c),
    do:
      " " <>
        gettext(
          "The game under way (%{moves} moves) is board %{n} of round %{r} there now, under the pairing's names and sent in full. If it is not that game, set it aside on the board's page.",
          moves: c.moves,
          n: c.board_no,
          r: c.round
        )

  def carried_words(%{outcome: :fresh} = c),
    do:
      " " <>
        gettext(
          "The game under way (%{moves} moves) was closed without a result and kept where it was; the board begins again.",
          moves: c.moves
        )

  def carried_words(%{outcome: :left} = c),
    do:
      " " <>
        gettext(
          "The game under way (%{moves} moves) stays where it was: the board has no board number there.",
          moves: c.moves
        )
end
