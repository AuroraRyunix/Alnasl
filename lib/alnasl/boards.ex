defmodule Alnasl.Boards do
  @moduledoc """
  The boards the box knows, and everything the site does with one.

  A board is a row (`Alnasl.Boards.Board`) and, while it is connected, a
  process (`Alnasl.BoardServer`). This module is the one door to both:
  adding and removing boards, connecting and disconnecting them, linking
  them to the games of the round, and the arbiter's repair tools.

  The round model in short:

  - the arbiter **links** a physical board to "board N of round R". The game
    is `(R, N)`, whichever physical board feeds it;
  - a board linked to a game another board already has takes it over - a
    board carried to another table mid-round, or a broken board swapped for a
    spare. The game continues from the moves it has;
  - a board linked late is caught up by the tracker if it can be (a few
    moves in), and by the arbiter if not (the repair tools);
  - a game that does not start from the standard position gets a FEN before
    the first move (`set_fen/2`).
  """

  import Ecto.Query, only: [order_by: 3]

  alias Alnasl.{BoardServer, Games, Log, Outbox, Pgn, Repo, Settings, Tournament, Transport}
  alias Alnasl.Boards.Board

  def subscribe, do: BoardServer.subscribe()

  # --- rows --------------------------------------------------------------------

  def list, do: Board |> order_by([b], [b.board_no, b.id]) |> Repo.all()
  def get(id), do: Repo.get(Board, id)
  def get!(id), do: Repo.get!(Board, id)

  def create(attrs) do
    attrs = attrs |> Map.new() |> encode_options()

    with {:ok, board} <- %Board{} |> Board.changeset(attrs) |> Repo.insert() do
      Log.add(:info, "board.added", %{name: board.name, driver: board.driver}, %{
        board_id: board.id
      })

      if board.enabled, do: start(board)
      notify(board.id)
      {:ok, board}
    end
  end

  def update(%Board{} = board, attrs) do
    attrs = attrs |> Map.new() |> encode_options()

    with {:ok, updated} <- board |> Board.changeset(attrs) |> Repo.update() do
      rewired? =
        {updated.driver, updated.port, updated.address, updated.options} !=
          {board.driver, board.port, board.address, board.options}

      cond do
        not updated.enabled -> stop(updated)
        rewired? or not running?(updated.id) -> restart(updated)
        true -> call(updated.id, {:reload, updated})
      end

      notify(updated.id)
      {:ok, updated}
    end
  end

  def delete(%Board{} = board) do
    stop(board)
    Repo.delete(board)
    Log.add(:info, "board.removed", %{name: board.name}, %{board_id: board.id})
    notify(board.id)
    :ok
  end

  defp encode_options(attrs) do
    case attrs[:options] || attrs["options"] do
      %{} = options -> attrs |> Map.delete("options") |> Map.put(:options, Jason.encode!(options))
      _other -> attrs
    end
  end

  # --- processes ---------------------------------------------------------------

  def running?(id), do: BoardServer.whereis(id) != nil

  @doc "Connects a board: starts its process and its driver."
  def start(%Board{} = board) do
    case DynamicSupervisor.start_child(Alnasl.BoardSupervisor, {BoardServer, board}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  @doc "Disconnects a board. Its game stays as it is."
  def stop(%Board{id: id}) do
    case BoardServer.whereis(id) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(Alnasl.BoardSupervisor, pid)
        notify(id)
        :ok
    end
  end

  def restart(%Board{} = board) do
    stop(board)
    start(get!(board.id))
  end

  @doc "Starts every enabled board. Called when the application starts."
  def start_all do
    for board <- list(), board.enabled, do: start(board)
    :ok
  end

  def connect(%Board{} = board), do: update(board, %{enabled: true})
  def disconnect(%Board{} = board), do: update(board, %{enabled: false})

  defp call(id, message, default \\ {:error, :not_running}) do
    case BoardServer.whereis(id) do
      nil -> default
      pid -> GenServer.call(pid, message, 15_000)
    end
  catch
    :exit, _reason -> default
  end

  defp notify(id), do: Phoenix.PubSub.broadcast(Alnasl.PubSub, "boards", {:board, id})

  # --- what the site shows -----------------------------------------------------

  @doc "The board as the site shows it. A board that is not connected has a short snapshot."
  def snapshot(%Board{} = board) do
    case call(board.id, :snapshot, nil) do
      nil -> offline(board)
      snapshot -> snapshot
    end
  end

  def snapshot(id) when is_integer(id) do
    case get(id) do
      nil -> nil
      board -> snapshot(board)
    end
  end

  def snapshots, do: Enum.map(list(), &snapshot/1)

  defp offline(board) do
    game = board.round && board.board_no && Games.get(board.round, board.board_no)

    %{
      id: board.id,
      name: board.name,
      driver: board.driver,
      port: board.port,
      address: board.address,
      round: board.round,
      board_no: board.board_no,
      table_no: board.table_no,
      flipped: board.flipped,
      serial: board.serial,
      firmware: board.firmware,
      running?: false,
      connected?: false,
      last_seen: nil,
      stats: %{positions: 0, polls_ok: 0, polls_missed: 0},
      info: %{},
      raw: nil,
      warning: nil,
      player: nil,
      linked?: game != nil,
      status: if(game && game.status == "finished", do: :finished, else: :no_signal),
      detail: nil,
      plies: if(game, do: Enum.map(Games.plies(game), &Map.take(&1, [:san, :flags])), else: []),
      candidates: [],
      clock: nil,
      clock_check: nil,
      clock_alarm: nil,
      problems: [],
      white: game && game.white,
      black: game && game.black,
      result: game && game.result,
      suggestion: game && game.suggestion,
      paused: game && game.paused,
      game_status: game && game.status,
      game_id: game && game.id,
      fen: game && elem(Games.position(game), 0),
      certain: nil,
      last_move: game && elem(Games.position(game), 1)
    }
  end

  @doc """
  What could be connected: every serial port the machine offers (with a note
  when a board already uses it), and whether the serial library is there at
  all.
  """
  def discover do
    used = Map.new(list(), &{&1.port, &1.name})

    %{
      serial?: Transport.Uart.available?(),
      ports: Enum.map(Transport.ports(), &Map.put(&1, :used_by, used[&1.port])),
      games: length(Pgn.all_bundled())
    }
  end

  # --- linking -----------------------------------------------------------------

  @doc "Links a board to board `board_no` of `round`. A board that had that game lets go of it."
  def link(%Board{} = board, round, board_no) when is_integer(round) and is_integer(board_no) do
    for other <- list(), other.id != board.id, other.round == round, other.board_no == board_no do
      Log.add(:info, "board.moved", %{from: other.name, to: board.name}, %{
        round: round,
        board_no: board_no
      })

      update(other, %{round: nil, board_no: nil})
    end

    Log.add(:info, "board.linked", %{name: board.name}, %{
      board_id: board.id,
      round: round,
      board_no: board_no
    })

    update(board, %{round: round, board_no: board_no})
  end

  def unlink(%Board{} = board) do
    Log.add(:info, "board.unlinked", %{name: board.name}, %{
      board_id: board.id,
      round: board.round,
      board_no: board.board_no
    })

    update(board, %{round: nil, board_no: nil})
  end

  @doc """
  Links the boards, in the order they are listed, to boards `first`,
  `first + 1`, ... of `round`: twelve boards set out in a row are one click.
  """
  def link_in_order(round, first \\ 1) do
    list()
    |> Enum.sort_by(&{&1.address || 0, &1.id})
    |> Enum.with_index(first)
    |> Enum.each(fn {board, number} -> link(board, round, number) end)
  end

  @doc """
  Moves every linked board on to another round: the next round begins. A
  board with a table number feeds the board of that number again; one
  without keeps the board number it had.
  """
  def move_to_round(round) do
    # A board with a sticker goes back to its own number: "table 7 plays
    # board 3" was said for a round, not for the tournament.
    for board <- list(), board.board_no != nil do
      link(board, round, board.table_no || board.board_no)
    end

    Settings.put("round", round)
    :ok
  end

  def flip(%Board{id: id}, flipped?), do: call(id, {:flip, flipped?})
  def pause_player(%Board{id: id}), do: call(id, {:driver, :pause})
  def resume_player(%Board{id: id}), do: call(id, {:driver, :resume})
  def note(%Board{id: id}, text), do: call(id, {:note, text})

  # --- the repair tools --------------------------------------------------------

  def undo(id), do: call(id, {:repair, :undo, nil})
  def append(id, sans), do: call(id, {:repair, :append, sans})
  def edit(id, number, san), do: call(id, {:repair, :edit, {number, san}})
  def set_fen(id, fen), do: call(id, {:repair, :set_fen, fen})
  def resync(id, depth \\ 6), do: call(id, {:repair, :resync, depth})
  def choose(id, index), do: call(id, {:repair, :choose, index})
  def pause(id, paused?), do: call(id, {:repair, :pause, paused?})
  def reopen(id), do: call(id, {:repair, :reopen, nil})

  @doc "Sets the result of the game on a board. The arbiter's word."
  def set_result(id, result), do: call(id, {:repair, :result, result})

  # --- games without a board ---------------------------------------------------

  @doc """
  Sets the result of a game no connected board is feeding (one attached from
  a PGN, or whose board is switched off).
  """
  def set_game_result(round, board_no, result) do
    case linked_running(round, board_no) do
      nil ->
        with %{} = game <- Games.get(round, board_no) do
          Log.add(:info, "result.set", %{result: result, by: "arbiter"}, %{
            round: round,
            board_no: board_no
          })

          game |> Games.finish(result) |> Outbox.enqueue(nil, false)
          :ok
        end

      board ->
        set_result(board.id, result)
    end
  end

  @doc """
  Attaches a game from a PGN to board `board_no` of `round` - a game that was
  played but not captured. It replaces what the box and the server hold for
  that board. A connected board linked to it lets go.
  """
  def attach_pgn(round, board_no, %{moves: moves} = pgn_game) do
    if board = linked_running(round, board_no), do: unlink(board)

    for board <- list(), board.round == round, board.board_no == board_no do
      update(board, %{round: nil, board_no: nil})
    end

    names = Tournament.board(round, board_no) || %{}

    game =
      Games.ensure(round, board_no, %{
        white: names[:white] || pgn_game.headers["White"],
        black: names[:black] || pgn_game.headers["Black"]
      })

    result = if pgn_game.result in ["1-0", "0-1", "1/2-1/2"], do: pgn_game.result, else: "*"
    game = game |> Games.pause(false) |> Games.attach(moves, result, pgn_game[:start_fen])

    Log.add(:info, "pgn.attached", %{moves: length(moves), result: result, by: "arbiter"}, %{
      round: round,
      board_no: board_no
    })

    {:ok, Outbox.enqueue(game, nil, true)}
  end

  defp linked_running(round, board_no) do
    Enum.find(list(), &(&1.round == round and &1.board_no == board_no and running?(&1.id)))
  end

  # --- demonstrations ----------------------------------------------------------

  @doc """
  Adds `count` simulator boards playing bundled games (or `games`, a list of
  `Alnasl.Pgn` games), linked to boards 1..count of `round`. Returns them.
  """
  def add_simulators(count, round, opts \\ []) do
    games = Keyword.get(opts, :games)
    faults = Keyword.get(opts, :faults, %{})
    speed = Keyword.get(opts, :speed, 20)
    first = Keyword.get(opts, :first, 1)
    existing = length(list())

    for i <- 1..count do
      options =
        %{
          "speed" => speed,
          "faults" => faults,
          "seed" => existing + i,
          "start_delay_ms" => 3_000 * i
        }
        |> Map.merge(
          case games && Enum.at(games, i - 1) do
            %{moves: moves} = game -> %{"moves" => moves, "start_fen" => game[:start_fen]}
            nil -> %{"game" => existing + i}
          end
        )

      {:ok, board} =
        create(%{
          name: "Sim #{existing + i}",
          driver: "simulator",
          port: "sim-#{existing + i}",
          options: options,
          round: round,
          board_no: first + i - 1
        })

      board
    end
  end
end
