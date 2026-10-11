defmodule AlnaslWeb.SetupLive do
  @moduledoc """
  First run, and whenever something changes: which results server, which
  tournament, the relay key; the box's name and language; a PIN for browsers
  on other machines; how patient the tracker is.

  "Test connection" really asks the server, with what is in the form (saved
  or not), and says in words which of three steps failed and why.

  The relay key is a secret: once saved, only its first and last characters
  are ever shown again. Leaving the field empty keeps the key that is stored.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{Destination, Log, Settings, Tournament, Tracker}
  alias Alnasl.Destination.{LichessApi, LichessBroadcast}
  alias AlnaslWeb.{Access, DestinationWords, Words}

  @tracker_fields ~w(settle_ms castle_hold_ms promotion_hold_ms takeback_settle_ms transient_ms lifted_ms search_depth)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Setup"), checks: nil, testing?: false)
     |> assign(lichess_checks: nil, lichess_testing?: false)
     |> load()}
  end

  defp load(socket) do
    s =
      Settings.get_many(
        ~w(server_url slug box_name locale round auto_suggest capture_cap_mb clock_heartbeat_s tracker)
      )

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
          %{"server_url" => s["server_url"], "tournament" => s["slug"], "relay_key" => ""},
          as: :server
        ),
      box_form:
        to_form(
          %{
            "box_name" => s["box_name"],
            "locale" => s["locale"],
            "round" => s["round"],
            "auto_suggest" => s["auto_suggest"],
            "capture_cap_mb" => s["capture_cap_mb"],
            "clock_heartbeat_s" => s["clock_heartbeat_s"]
          },
          as: :box
        ),
      pin_form: to_form(%{"pin" => ""}, as: :door),
      lichess_form:
        to_form(
          %{
            "round" => Settings.get("lichess_round_id") || "",
            "token" => "",
            "round_no" => LichessBroadcast.round(),
            "enabled" => Destination.enabled?(LichessBroadcast)
          },
          as: :lichess
        ),
      lichess_hint: LichessBroadcast.token_hint(),
      lichess_round_id: Settings.get("lichess_round_id"),
      tracker_form:
        to_form(
          tracker
          |> Map.take(@tracker_fields ++ ~w(takeback promotion_default))
          |> Map.update!("promotion_default", &to_string/1),
          as: :tracker
        ),
      key_hint: Settings.relay_key_hint(),
      pin_set?: Settings.pin_set?(),
      snapshot_at: Settings.get("snapshot_at")
    )
  end

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
    {url, String.trim(slug), if(key == "", do: Settings.get("relay_key"), else: key)}
  end

  # What is in the Lichess form, as it would be saved: `{round id | :error | "", token}`.
  defp read_lichess(params) do
    text = String.trim(params["round"] || "")

    round =
      case {text, LichessApi.parse_round(text)} do
        {"", _} -> ""
        {_text, {:ok, id}} -> id
        {_text, :error} -> :error
      end

    token = String.trim(params["token"] || "")
    {round, if(token == "", do: Settings.get("lichess_token"), else: token)}
  end

  # --- events ------------------------------------------------------------------

  @impl true
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
         |> put_flash(:error, gettext("Give the server's address and the tournament."))}

      true ->
        Settings.put_many(%{"server_url" => url, "slug" => slug, "relay_key" => key || ""})
        Log.add(:info, "setup.saved", %{})

        socket =
          case Tournament.refresh() do
            {:ok, _snapshot} ->
              put_flash(socket, :info, gettext("Saved. The pairings were fetched."))

            {:error, reason} ->
              put_flash(
                socket,
                :error,
                gettext("Saved - but: %{why}", why: Words.fetch_error(reason))
              )
          end

        {:noreply, load(socket)}
    end
  end

  # One form, two buttons, like the results server's: "Test" saves nothing.
  def handle_event("save_lichess", %{"lichess" => params, "intent" => "test"}, socket) do
    {round, token} = read_lichess(params)
    send(self(), {:run_lichess_test, round, token})

    {:noreply,
     assign(socket,
       lichess_testing?: true,
       lichess_checks: nil,
       lichess_form: to_form(Map.put(params, "token", ""), as: :lichess)
     )}
  end

  def handle_event("save_lichess", %{"lichess" => params}, socket) do
    case read_lichess(params) do
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
        Settings.put_many(%{
          "lichess_round_id" => round,
          "lichess_token" => token || "",
          "lichess_round" => int(params["round_no"], Settings.get("round") || 1, 1, 999)
        })

        Destination.set_enabled(LichessBroadcast, params["enabled"] == "true")
        Log.add(:info, "setup.saved", %{})
        {:noreply, socket |> put_flash(:info, gettext("Saved.")) |> load()}
    end
  end

  def handle_event("clear_lichess", _params, socket) do
    Settings.put_many(%{"lichess_round_id" => "", "lichess_token" => ""})
    Destination.set_enabled(LichessBroadcast, false)
    Log.add(:info, "setup.saved", %{})

    {:noreply,
     socket
     |> assign(lichess_checks: nil)
     |> put_flash(:info, gettext("The Lichess round and its token are forgotten."))
     |> load()}
  end

  def handle_event("save_box", %{"box" => params}, socket) do
    name = String.trim(params["box_name"] || "")

    Settings.put_many(%{
      "box_name" => if(name == "", do: "Alnasl", else: String.slice(name, 0, 40)),
      "locale" => if(params["locale"] in ["en", "nl"], do: params["locale"], else: "en"),
      "round" => int(params["round"], 1, 1, 999),
      "auto_suggest" => params["auto_suggest"] == "true",
      "capture_cap_mb" => int(params["capture_cap_mb"], 500, 10, 100_000),
      "clock_heartbeat_s" => int(params["clock_heartbeat_s"], 20, 5, 600)
    })

    Log.add(:info, "setup.saved", %{})
    # The language may have changed: draw the page again from the top.
    {:noreply, socket |> put_flash(:info, gettext("Saved.")) |> push_navigate(to: ~p"/setup")}
  end

  def handle_event("save_pin", %{"door" => %{"pin" => pin}}, socket) do
    pin = String.trim(pin)

    cond do
      pin == "" ->
        {:noreply, put_flash(socket, :error, gettext("Type a PIN, or use \"Remove the PIN\"."))}

      String.length(pin) < 4 ->
        {:noreply, put_flash(socket, :error, gettext("A PIN needs at least 4 characters."))}

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

  def handle_event("save_tracker", %{"tracker" => params}, socket) do
    values =
      for field <- @tracker_fields, into: %{} do
        default = Map.fetch!(Tracker.defaults(), String.to_existing_atom(field))

        {field,
         int(
           params[field],
           default,
           if(field == "search_depth", do: 2, else: 0),
           if(field == "search_depth", do: 6, else: 600_000)
         )}
      end
      |> Map.put("takeback", params["takeback"] == "true")
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
  # top of whatever else was set (the search depth is left as it is).
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
        do: [server: {:error, {:unreachable, :nxdomain}}, tournament: :skipped, key: :skipped],
        else: Tournament.test(url, slug, key)

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

  def handle_info(_other, socket), do: {:noreply, socket}

  # --- page --------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:setup}
      link={@link}
      box={@box}
      locale={@locale}
      title={gettext("Setup")}
    >
      <div class="cols">
        <.panel id="setup-server" title={gettext("Results server")}>
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

          <p :if={@testing?} id="test-running" class="note" role="status" style="margin-top:0.8rem">
            {gettext("Asking the server...")}
          </p>
          <ul
            :if={@checks}
            id="test-result"
            class="stack"
            style="list-style:none;padding:0;margin:0.8rem 0 0"
            role="status"
          >
            <li
              :for={{step, result} <- @checks}
              id={"check-#{step}"}
              class="row"
              style="align-items:flex-start;flex-wrap:nowrap"
            >
              <% {tone, sentence} = Words.test_step(step, result) %>
              <.badge
                tone={tone}
                icon={if tone == "ok", do: "ok", else: if(tone == nil, do: "waiting", else: "error")}
              >
                {Words.step_name(step)}
              </.badge>
              <span>{sentence}</span>
            </li>
          </ul>
          <p :if={@snapshot_at} class="note" style="margin-top:0.8rem">
            {gettext("Pairings last fetched: %{t}",
              t: String.slice(@snapshot_at, 0, 16) |> String.replace("T", " ")
            )} UTC
          </p>
        </.panel>

        <.panel id="setup-lichess" title={gettext("Lichess broadcast")}>
          <p class="note">
            {gettext(
              "Optional. The box pushes each game of one round to a Lichess broadcast round as it changes - besides the results site, and without waiting for it. On Lichess, make the broadcast and its round first; leave the round's source empty."
            )}
            <.link navigate={~p"/help#help-lichess"}>{gettext("How, step by step")}</.link>
          </p>
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
            class="note"
            role="status"
            style="margin-top:0.8rem"
          >
            {gettext("Asking Lichess...")}
          </p>
          <ul
            :if={@lichess_checks}
            id="lichess-test-result"
            class="stack"
            style="list-style:none;padding:0;margin:0.8rem 0 0"
            role="status"
          >
            <li
              :for={{step, result} <- @lichess_checks}
              id={"lichess-check-#{step}"}
              class="row"
              style="align-items:flex-start;flex-wrap:nowrap"
            >
              <% {tone, sentence} = DestinationWords.test_step(step, result) %>
              <.badge
                tone={tone}
                icon={if tone == "ok", do: "ok", else: if(tone == nil, do: "waiting", else: "error")}
              >
                {DestinationWords.step_name(step)}
              </.badge>
              <span>{sentence}</span>
            </li>
          </ul>
          <p class="note" style="margin-top:0.8rem">
            {gettext(
              "The test asks Lichess who the token belongs to and whether the round exists. It sends no game and changes nothing there."
            )}
          </p>
        </.panel>

        <.panel id="setup-look" title={gettext("Colour theme")}>
          <p class="note">
            {gettext(
              "Chosen per device and kept in this browser; the box and the other screens are not told. Match device follows the phone or computer, light by day and dark by night."
            )}
          </p>
          <Layouts.theme_picker id="theme-grid" variant={:grid} />
        </.panel>

        <.panel id="setup-box" title={gettext("This box")}>
          <.form for={@box_form} id="box-form" phx-submit="save_box" class="stack">
            <div class="form-grid">
              <.input
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
                label={gettext("Language")}
                options={[{"English", "en"}, {"Nederlands", "nl"}]}
              />
              <.input
                field={@box_form[:round]}
                id="box-round"
                type="number"
                min="1"
                max="999"
                label={gettext("Round in play")}
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
              label={gettext("Offer mate and stalemate to the results site without waiting for me")}
              hint={
                gettext(
                  "Off: every result waits for the arbiter. On: a game that ends in mate or stalemate on the board is sent as finished at once - still provisional on the site."
                )
              }
            />
            <div class="row">
              <.button id="save-box" variant="primary" type="submit">{gettext("Save")}</.button>
            </div>
          </.form>
        </.panel>

        <.panel id="setup-pin" title={gettext("Access from other machines")}>
          <p class="note">
            {gettext(
              "The box itself is always let in. A browser on another machine in the hall is let in freely, unless a PIN is set here. (Other machines can only reach the box at all when it was started with ALNASL_LISTEN=lan.)"
            )}
          </p>
          <p id="pin-state">
            <.badge :if={@pin_set?} tone="ok" icon="ok">{gettext("A PIN is set")}</.badge>
            <.badge :if={!@pin_set?} icon="waiting">{gettext("No PIN")}</.badge>
          </p>
          <.form
            for={@pin_form}
            id="pin-form"
            phx-submit="save_pin"
            class="row"
            style="align-items:flex-end"
          >
            <.input
              field={@pin_form[:pin]}
              id="pin-input"
              type="password"
              label={gettext("New PIN")}
              autocomplete="new-password"
            />
            <.button id="save-pin" type="submit">{gettext("Set the PIN")}</.button>
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
          <Access.phone id="setup-phone-access" />
        </.panel>

        <.panel id="setup-tracker" title={gettext("How patient the tracker is")}>
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
                "For games of a few minutes or less. It changes two things: a move must stand for %{settle} ms instead of %{settle_default}, and a board put back to the position before the last move is not read as a takeback - at that speed it is a piece going to and fro. Nothing else is touched, the number of unseen moves searched for included. \"Back to the defaults\" undoes it.",
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
                max="6"
                label={gettext("Unseen moves searched for (half-moves)")}
              />
              <p id="tracker-depth-note" class="note">
                {gettext(
                  "2 by default: the box works out up to two moves it did not see, and raises the alarm beyond that. Higher finds more by itself, and is more often wrong when a move on the board was illegal. \"Resync\" on a board's page searches deeper whatever is set here."
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
              label={gettext("A board put back to the position before the last move is a takeback")}
            />
            <div class="row">
              <.button id="save-tracker" variant="primary" type="submit">{gettext("Save")}</.button>
              <.button id="reset-tracker" type="button" phx-click="reset_tracker">{gettext(
                "Back to the defaults"
              )}</.button>
            </div>
          </.form>
        </.panel>
      </div>
    </Layouts.app>
    """
  end
end
