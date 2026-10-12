defmodule AlnaslWeb.PgnLive do
  @moduledoc """
  PGN in and out.

  In: a file (or pasted text) is read and every game replayed with the move
  checker - a game with an illegal move is listed as such and can do nothing.
  A good game can then

  - be **played on a simulator board**, for a demonstration or a test of the
    whole chain without hardware;
  - be **attached** to a board of the round: a game that was played but not
    captured. It replaces what the box and the server hold for that board, so
    it asks first;
  - be **compared** with the game captured on a board: the first move where
    a scoresheet and the board disagree.

  Out: any game or a whole round as a PGN file, with the clock times.
  """

  use AlnaslWeb, :live_view

  alias Alnasl.{Boards, Games, Pgn, Tournaments}
  alias AlnaslWeb.Scope

  @impl true
  def mount(_params, _session, socket) do
    # One tournament at a time: the first one shown, until another is picked.
    first = hd(Tournaments.active())

    {:ok,
     socket
     |> assign(
       page_title: "PGN",
       games: [],
       problems: [],
       tid: first.id,
       round: first.round,
       confirm: nil,
       verdicts: %{}
     )
     |> assign(paste_form: to_form(%{"text" => ""}, as: :paste), targets: %{})
     |> allow_upload(:pgn, accept: :any, max_entries: 4, max_file_size: 5_000_000)
     |> load()}
  end

  defp load(socket) do
    %{tid: tid, round: round} = socket.assigns
    shown = Tournaments.active()

    assign(socket,
      stored: Games.list(tid, round),
      rounds: Enum.uniq(Tournaments.rounds(tid) ++ Games.rounds(tid) ++ [round]) |> Enum.sort(),
      numbers: tid |> Tournaments.boards(round) |> Enum.map(& &1.board),
      shown: shown,
      names: Map.new(shown, &{&1.id, Tournaments.title(&1) || gettext("This box")})
    )
  end

  defp read(socket, text) do
    {games, problems} = Pgn.load(text)

    indexed =
      Enum.with_index(socket.assigns.games |> Enum.map(&elem(&1, 0)) |> Kernel.++(games), 1)
      |> Enum.map(fn {g, i} -> {g, i} end)

    assign(socket, games: indexed, problems: socket.assigns.problems ++ problems, confirm: nil)
  end

  # --- events ------------------------------------------------------------------

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("upload", _params, socket) do
    texts =
      consume_uploaded_entries(socket, :pgn, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    case texts do
      [] ->
        {:noreply, put_flash(socket, :error, gettext("Choose a PGN file first."))}

      texts ->
        socket = Enum.reduce(texts, socket, &read(&2, &1))

        {:noreply,
         put_flash(socket, :info, gettext("%{n} game(s) read.", n: length(socket.assigns.games)))}
    end
  end

  def handle_event("paste", %{"paste" => %{"text" => text}}, socket) do
    before = length(socket.assigns.games)
    problems = length(socket.assigns.problems)
    socket = read(socket, text)

    if length(socket.assigns.games) == before and length(socket.assigns.problems) == problems do
      {:noreply, put_flash(socket, :error, gettext("No game was found in that text."))}
    else
      {:noreply,
       socket
       |> assign(paste_form: to_form(%{"text" => ""}, as: :paste))
       |> put_flash(
         :info,
         gettext("%{n} game(s) read.", n: length(socket.assigns.games) - before)
       )}
    end
  end

  def handle_event("clear", _params, socket),
    do: {:noreply, assign(socket, games: [], problems: [], confirm: nil, verdicts: %{})}

  def handle_event("pick_tournament", %{"tournament_id" => value}, socket) do
    with {tid, ""} <- Integer.parse(value), %{} = tournament <- Tournaments.get(tid) do
      {:noreply,
       socket
       |> assign(tid: tournament.id, round: tournament.round, confirm: nil, targets: %{})
       |> load()}
    else
      _none -> {:noreply, socket}
    end
  end

  def handle_event("round", %{"round" => round}, socket) do
    {:noreply, socket |> assign(round: int(round, socket.assigns.round), confirm: nil) |> load()}
  end

  def handle_event("target", %{"index" => index, "board_no" => board_no}, socket) do
    {:noreply,
     assign(socket,
       targets: Map.put(socket.assigns.targets, int(index, 0), int(board_no, nil)),
       confirm: nil
     )}
  end

  def handle_event("simulate", %{"index" => index}, socket) do
    with {game, i} <- find(socket, index) do
      number = socket.assigns.targets[i]

      [board] =
        Boards.add_simulators(1, socket.assigns.round,
          games: [game],
          first: number || next_free(socket),
          faults: %{"lift" => 0.08, "slide" => 0.1}
        )

      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext("\"%{name}\" is playing that game on board %{n}.",
           name: board.name,
           n: board.board_no
         )
       )
       |> load()}
    else
      _missing -> {:noreply, socket}
    end
  end

  def handle_event("simulate_all", _params, socket) do
    games = Enum.map(socket.assigns.games, &elem(&1, 0))

    if games == [] do
      {:noreply, socket}
    else
      boards =
        Boards.add_simulators(length(games), socket.assigns.round,
          tournament_id: socket.assigns.tid,
          games: games,
          first: next_free(socket),
          faults: %{"lift" => 0.08, "slide" => 0.1}
        )

      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext("%{n} simulator board(s) are playing these games.", n: length(boards))
       )
       |> load()}
    end
  end

  def handle_event("ask_attach", %{"index" => index}, socket) do
    with {_game, i} <- find(socket, index),
         number when is_integer(number) <- socket.assigns.targets[i] do
      {:noreply,
       assign(socket,
         confirm: {i, number, Games.current(socket.assigns.tid, socket.assigns.round, number)}
       )}
    else
      _none ->
        {:noreply,
         put_flash(socket, :error, gettext("Choose the board this game belongs to first."))}
    end
  end

  def handle_event("cancel_attach", _params, socket), do: {:noreply, assign(socket, confirm: nil)}

  def handle_event("attach", _params, %{assigns: %{confirm: {i, number, _existing}}} = socket) do
    {game, _} = Enum.find(socket.assigns.games, fn {_g, index} -> index == i end)
    {:ok, _stored} = Boards.attach_pgn(socket.assigns.tid, socket.assigns.round, number, game)

    {:noreply,
     socket
     |> assign(confirm: nil)
     |> put_flash(
       :info,
       gettext(
         "The game is now board %{n} of round %{r}, and is on its way to the results server.",
         n: number,
         r: socket.assigns.round
       )
     )
     |> load()}
  end

  def handle_event("attach", _params, socket), do: {:noreply, socket}

  def handle_event("compare", %{"index" => index}, socket) do
    with {game, i} <- find(socket, index),
         {:board, number} when is_integer(number) <- {:board, socket.assigns.targets[i]},
         {:game, %{} = stored} <-
           {:game, Games.current(socket.assigns.tid, socket.assigns.round, number)} do
      verdict =
        {number, Pgn.first_difference(Games.sans(stored), game.moves), length(Games.sans(stored)),
         length(game.moves)}

      {:noreply, assign(socket, verdicts: Map.put(socket.assigns.verdicts, i, verdict))}
    else
      {:game, nil} ->
        {:noreply, put_flash(socket, :error, gettext("The box has no game for that board yet."))}

      _none ->
        {:noreply, put_flash(socket, :error, gettext("Choose the board to compare with first."))}
    end
  end

  defp find(socket, index) do
    i = int(index, 0)
    Enum.find(socket.assigns.games, fn {_game, n} -> n == i end)
  end

  defp next_free(socket) do
    used =
      (Boards.list()
       |> Enum.filter(&(&1.tournament_id == socket.assigns.tid))
       |> Enum.map(& &1.board_no)) ++ Enum.map(socket.assigns.stored, & &1.board_no)

    (used |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0 end)) + 1
  end

  defp int(text, default) do
    case Integer.parse(to_string(text)) do
      {n, ""} when n > 0 -> n
      _bad -> default
    end
  end

  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  # --- page --------------------------------------------------------------------

  defp upload_error(:too_large), do: gettext("That file is too large (5 MB at most).")
  defp upload_error(:not_accepted), do: gettext("That is not a .pgn file.")
  defp upload_error(:too_many_files), do: gettext("Four files at a time.")
  defp upload_error(_other), do: gettext("That file could not be read.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={:pgn}
      link={@link}
      hall={@hall}
      update={@update}
      box={@box}
      locale={@locale}
      title="PGN"
    >
      <:actions>
        <form
          :if={length(@shown) > 1}
          id="pgn-tournament-form"
          phx-change="pick_tournament"
          class="row"
        >
          <label for="pgn-tournament" class="note">{gettext("Tournament")}</label>
          <select id="pgn-tournament" name="tournament_id" class="input" style="width:auto">
            <option :for={t <- @shown} value={t.id} selected={t.id == @tid}>{@names[t.id]}</option>
          </select>
        </form>
        <form id="pgn-round-form" phx-change="round" class="row">
          <label for="pgn-round" class="note">{gettext("Round")}</label>
          <select id="pgn-round" name="round" class="input" style="width:auto">
            <option :for={n <- @rounds} value={n} selected={n == @round}>{n}</option>
          </select>
        </form>
      </:actions>

      <div class="cols">
        <.panel id="pgn-in" title={gettext("Bring in games")}>
          <form id="upload-form" phx-change="validate" phx-submit="upload" class="stack">
            <div class="field">
              <label for={@uploads.pgn.ref}>{gettext("PGN file(s)")}</label>
              <.live_file_input upload={@uploads.pgn} class="input" />
              <span class="hint">{gettext("One file may hold many games.")}</span>
            </div>
            <p :for={entry <- @uploads.pgn.entries} class="note">
              {entry.client_name}
              <span
                :for={err <- upload_errors(@uploads.pgn, entry)}
                class="error"
                style="color:var(--bad)"
              >{upload_error(err)}</span>
            </p>
            <p :for={err <- upload_errors(@uploads.pgn)} class="error" style="color:var(--bad)">
              {upload_error(err)}
            </p>
            <div class="row">
              <.button id="upload-submit" variant="primary" type="submit">{gettext("Read the file")}</.button>
            </div>
          </form>
          <.form
            for={@paste_form}
            id="paste-form"
            phx-submit="paste"
            class="stack"
            style="margin-top:1rem"
          >
            <.input
              field={@paste_form[:text]}
              id="paste-text"
              type="textarea"
              label={gettext("...or paste or type the moves")}
              placeholder="1. e4 e5 2. Nf3 Nc6 3. Bb5 a6"
              rows="5"
              spellcheck="false"
            />
            <div class="row">
              <.button id="paste-submit" type="submit">{gettext("Read this text")}</.button>
            </div>
          </.form>
        </.panel>

        <.panel id="pgn-out" title={gettext("Take games out (round %{n})", n: @round)} flush>
          <:actions>
            <.button
              :if={@stored != []}
              id="export-round"
              small
              href={Scope.round_file(@tid, @round)}
              download
            >{gettext("Whole round as PGN")}</.button>
          </:actions>
          <div :if={@stored == []} class="empty">
            {gettext("The box has no games for this round yet.")}
          </div>
          <table :if={@stored != []} id="stored-games">
            <thead>
              <tr>
                <th>{gettext("Board")}</th>
                <th>{gettext("Players")}</th>
                <th class="num">{gettext("Moves")}</th>
                <th>{gettext("Result")}</th>
                <th><span class="sr-only">{gettext("Actions")}</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={game <- @stored} id={"stored-#{game.board_no}"}>
                <td>
                  <.link navigate={Scope.game_path(@tid, @round, game.board_no)}>{game.board_no}</.link>
                </td>
                <td>{game.white || "?"} - {game.black || "?"}</td>
                <td class="num">{div(length(Games.sans(game)) + 1, 2)}</td>
                <td>
                  {game.result || "*"}
                  <span :if={game.source == "pgn"} class="flag plain">{gettext("from PGN")}</span>
                </td>
                <td class="act">
                  <.button
                    id={"export-#{game.board_no}"}
                    small
                    href={Scope.game_file(@tid, @round, game.board_no)}
                    download
                  >PGN</.button>
                </td>
              </tr>
            </tbody>
          </table>
        </.panel>
      </div>

      <div :if={@problems != []} id="pgn-problems" class="alarm warn" role="status">
        <.icon name="warning" />
        <div>
          <b>{gettext("%{n} game(s) could not be used", n: length(@problems))}</b>
          <ul style="margin:0.3rem 0 0;padding-left:1.1rem;color:var(--ink)">
            <li :for={{index, white, black, message} <- @problems}>
              {gettext("Game %{i} (%{white} - %{black}): %{message}",
                i: index,
                white: white || "?",
                black: black || "?",
                message: message
              )}
            </li>
          </ul>
        </div>
      </div>

      <div
        :if={@confirm}
        id="attach-confirm"
        class="alarm warn"
        role="alertdialog"
        aria-labelledby="attach-title"
      >
        <.icon name="warning" />
        <div>
          <% {_i, number, existing} = @confirm %>
          <b id="attach-title">{gettext("Attach this game as board %{n} of round %{r}?",
            n: number,
            r: @round
          )}</b>
          <p :if={existing && existing.plies != "[]"}>
            {gettext(
              "The box already has a game of %{n} move(s) for that board. It will be replaced, here and on the results server.",
              n: div(length(Games.sans(existing)) + 1, 2)
            )}
          </p>
          <p :if={!existing || existing.plies == "[]"}>
            {gettext("It will be sent to the results server as that board's game.")}
          </p>
          <div class="row" style="margin-top:0.5rem">
            <.button id="attach-yes" variant="primary" phx-click="attach">{gettext("Yes, attach it")}</.button>
            <.button id="attach-no" phx-click="cancel_attach">{gettext("No")}</.button>
          </div>
        </div>
      </div>

      <.panel
        :if={@games != []}
        id="read-games"
        title={gettext("Games read (%{n})", n: length(@games))}
        flush
      >
        <:actions>
          <.button id="simulate-all" small phx-click="simulate_all">{gettext(
            "Play them all on simulator boards"
          )}</.button>
          <.button id="clear-games" small phx-click="clear">{gettext("Clear")}</.button>
        </:actions>
        <div class="table-wrap">
          <table id="games-table">
            <thead>
              <tr>
                <th>#</th>
                <th>{gettext("Players")}</th>
                <th class="num">{gettext("Moves")}</th>
                <th>{gettext("Result")}</th>
                <th>{gettext("Board of round %{n}", n: @round)}</th>
                <th><span class="sr-only">{gettext("Actions")}</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{game, i} <- @games} id={"read-#{i}"}>
                <td>{i}</td>
                <td>
                  {game.headers["White"] || "?"} - {game.headers["Black"] || "?"}
                  <div class="note">{game.headers["Event"]} {game.headers["Date"]}</div>
                  <.verdict :if={@verdicts[i]} id={"verdict-#{i}"} verdict={@verdicts[i]} />
                </td>
                <td class="num">{div(length(game.moves) + 1, 2)}</td>
                <td>{game.result}</td>
                <td>
                  <form id={"target-form-#{i}"} phx-change="target">
                    <input type="hidden" name="index" value={i} />
                    <label class="sr-only" for={"target-#{i}"}>{gettext("Board for game %{i}", i: i)}</label>
                    <select id={"target-#{i}"} name="board_no" class="input" style="width:auto">
                      <option value="">{gettext("choose...")}</option>
                      <option
                        :for={
                          n <- Enum.uniq(@numbers ++ Enum.map(@stored, & &1.board_no)) |> Enum.sort()
                        }
                        value={n}
                        selected={@targets[i] == n}
                      >
                        {gettext("board %{n}", n: n)}
                      </option>
                    </select>
                  </form>
                </td>
                <td class="act">
                  <.button id={"simulate-#{i}"} small phx-click="simulate" phx-value-index={i}>{gettext(
                    "Simulate"
                  )}</.button>
                  <.button id={"compare-#{i}"} small phx-click="compare" phx-value-index={i}>{gettext(
                    "Compare"
                  )}</.button>
                  <.button id={"attach-#{i}"} small phx-click="ask_attach" phx-value-index={i}>{gettext(
                    "Attach"
                  )}</.button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.panel>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :verdict, :any, required: true

  defp verdict(%{verdict: {number, :same, _mine, _theirs}} = assigns) do
    assigns = assign(assigns, number: number)

    ~H"""
    <div id={@id}>
      <.badge tone="ok" icon="ok">{gettext("The same moves as board %{n}", n: @number)}</.badge>
    </div>
    """
  end

  defp verdict(%{verdict: {number, {ply, mine, theirs}, _a, _b}} = assigns) do
    assigns = assign(assigns, number: number, ply: ply, mine: mine, theirs: theirs)

    ~H"""
    <div id={@id}>
      <.badge tone="warn" icon="warning">
        {gettext("First difference with board %{n}", n: @number)}
      </.badge>
      <span>
        {gettext("move %{move} (%{side}): the board has %{mine}, this PGN has %{theirs}",
          move: div(@ply + 1, 2),
          side: if(rem(@ply, 2) == 1, do: gettext("White"), else: gettext("Black")),
          mine: @mine || gettext("nothing more"),
          theirs: @theirs || gettext("nothing more")
        )}
      </span>
    </div>
    """
  end
end
