defmodule Alnasl.Finder do
  @moduledoc """
  "Which board is this?" - answered by touching it.

  A board reports the whole position whenever a piece is lifted or put down.
  That is all this needs: the board that just reported a change is the board
  somebody just touched. So nobody has to follow a cable.

  ## Finding

  Every touch is remembered with its time and announced (`subscribe/0`,
  `{:finder, {:touch, board_id, at}}`). The Boards page lights up the row;
  with several boards being touched, the newest wins and each keeps its time.

  ## Numbering a hall by touching

  `start_wizard/1`, then lift a piece on table 1's board, then on table 2's,
  and so on: each board touched for the first time gets the next table
  number (`Alnasl.Tables.set_table/2`). Putting the piece back is a touch
  too, and touching a board twice is easy; a board that already got its
  number in this run is not given another. `undo/0` takes the last number
  back, `skip/0` leaves a number out (an empty table), `stop/0` ends it.

  The run lives **here, on the box** - not in a browser. The arbiter walks
  the hall with a phone; the phone may lose the network between two tables,
  and the page may be open on the box's own screen as well. Whoever looks,
  from wherever, sees the same run and can carry on with it. It ends by
  itself when every board has a number, or after a quarter of an hour in
  which nothing was touched - so it cannot still be handing out numbers
  when the round has started and forty hands are on the boards.

  The numbers themselves are in the database the moment they are given; the
  run is only the question "what is the next number", and is not kept across
  a restart of the box.
  """

  use GenServer

  alias Alnasl.{Boards, Tables}

  @topic "finder"
  @idle_ms 15 * 60 * 1000

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(Alnasl.PubSub, @topic)

  # --- from the boards ---------------------------------------------------------

  @doc "A board read `new` where it read `old` before. Called by the board's own process."
  def reading(_board_id, nil, _new), do: :ok
  def reading(_board_id, same, same), do: :ok

  def reading(board_id, _old, _new),
    do: GenServer.cast(__MODULE__, {:touch, board_id, System.system_time(:millisecond)})

  @doc """
  The board on `board`'s port has said it is `serial`. It may be one the box
  knows from another port, or not the board this row is
  (`Alnasl.Tables.recognise/4`). Sorted out here and not in the board's own
  process, because sorting it out may stop that process.
  """
  def identified(%{id: id, port: port, address: address}, serial),
    do: GenServer.cast(__MODULE__, {:identified, id, port, address, serial})

  @doc "A touch from outside a board process: the tests, and nothing else."
  def touch(board_id, at \\ System.system_time(:millisecond)),
    do: GenServer.cast(__MODULE__, {:touch, board_id, at})

  # --- for the site ------------------------------------------------------------

  @doc """
  `%{last, touches, wizard}`: the newest touch (`%{board_id, at}` or `nil`),
  every board's last touch (`%{board_id => at}`, wall-clock ms), and the run
  (`nil`, or `%{next, first, done, skipped, started_at}` with `done` the
  boards numbered so far, newest first: `%{board_id, table, name, serial, at}`).
  """
  def state, do: GenServer.call(__MODULE__, :state)

  @doc """
  Starts a run. With a `hall_id` the run is that hall's: a board of another
  hall that feels a piece lift is not numbered by it, and the run is over
  when every board of the hall has its number.
  """
  def start_wizard(first \\ 1, hall_id \\ nil) when is_integer(first) and first > 0,
    do: GenServer.call(__MODULE__, {:start, first, hall_id})

  def undo, do: GenServer.call(__MODULE__, :undo)
  def skip, do: GenServer.call(__MODULE__, :skip)
  def stop, do: GenServer.call(__MODULE__, :stop)

  @doc "Forgets everything: for the tests."
  def reset, do: GenServer.call(__MODULE__, :reset)

  # --- the process -------------------------------------------------------------

  @impl true
  def init(_arg), do: {:ok, fresh()}

  defp fresh, do: %{last: nil, touches: %{}, wizard: nil}

  @impl true
  def handle_call(:state, _from, s) do
    s = expire(s)
    {:reply, public(s), s}
  end

  def handle_call({:start, first, hall_id}, _from, s) do
    now = System.system_time(:millisecond)

    s = %{
      s
      | wizard: %{
          next: first,
          first: first,
          hall_id: hall_id,
          done: [],
          skipped: [],
          started_at: now,
          active_at: now
        }
    }

    announce(:wizard)
    {:reply, public(s), s}
  end

  # The last thing done was a skip: that is what is undone.
  def handle_call(:undo, _from, %{wizard: %{skipped: [n | rest], next: next} = w} = s)
      when n == next - 1 do
    s = %{s | wizard: active(%{w | skipped: rest, next: n})}
    announce(:wizard)
    {:reply, public(s), s}
  end

  def handle_call(:undo, _from, %{wizard: %{done: [entry | rest]} = w} = s) do
    safely(fn ->
      if board = Boards.get(entry.board_id), do: Boards.update(board, entry.before)
    end)

    s = %{s | wizard: active(%{w | done: rest, next: entry.table})}
    announce(:wizard)
    {:reply, public(s), s}
  end

  def handle_call(:undo, _from, s), do: {:reply, public(s), s}

  def handle_call(:skip, _from, %{wizard: %{next: next} = w} = s) do
    s = %{s | wizard: active(%{w | next: next + 1, skipped: [next | w.skipped]})}
    announce(:wizard)
    {:reply, public(s), s}
  end

  def handle_call(:skip, _from, s), do: {:reply, public(s), s}

  def handle_call(:stop, _from, s) do
    s = %{s | wizard: nil}
    announce(:wizard)
    {:reply, public(s), s}
  end

  def handle_call(:reset, _from, _s), do: {:reply, :ok, fresh()}

  @impl true
  def handle_cast({:touch, board_id, at}, s) do
    s =
      expire(%{
        s
        | last: %{board_id: board_id, at: at},
          touches: Map.put(s.touches, board_id, at)
      })

    announce({:touch, board_id, at})
    {:noreply, number(s, board_id, at)}
  end

  def handle_cast({:identified, id, port, address, serial}, s) do
    safely(fn -> Tables.recognise(id, port, address, serial) end)
    {:noreply, s}
  end

  # The run: a board touched for the first time gets the next number.
  defp number(%{wizard: nil} = s, _board_id, _at), do: s

  defp number(%{wizard: w} = s, board_id, at) do
    case Enum.find(w.done, &(&1.board_id == board_id)) do
      %{} = entry ->
        announce({:already, entry})
        s

      nil ->
        if safely(fn -> in_run?(board_id, w) end) == false do
          s
        else
          assign_or_skip(s, w, board_id, at)
        end
    end
  end

  # A run of one hall keeps to that hall's boards.
  defp in_run?(_board_id, %{hall_id: nil}), do: true

  defp in_run?(board_id, %{hall_id: hall_id}) do
    case Boards.get(board_id) do
      nil -> false
      board -> Alnasl.Halls.of(board) == hall_id
    end
  end

  defp assign_or_skip(s, w, board_id, at) do
    case safely(fn -> assign_next(board_id, w.next, at) end) do
      %{} = entry ->
        w = active(%{w | done: [entry | w.done], next: w.next + 1})
        announce({:assigned, entry})
        finish(%{s | wizard: w})

      _failed ->
        s
    end
  end

  defp assign_next(board_id, table, at) do
    with %{} = board <- Boards.get(board_id) do
      before = Map.take(board, [:table_no, :round, :board_no])
      Tables.set_table(board, table)

      %{
        board_id: board.id,
        table: table,
        name: board.name,
        serial: board.serial,
        at: at,
        before: before
      }
    end
  end

  # Every board the box knows has its number: there is nothing left to touch.
  defp finish(%{wizard: w} = s) do
    ids = MapSet.new(w.done, & &1.board_id)

    if safely(fn -> Enum.all?(boards_of(w), &(&1.id in ids)) end) == true do
      announce(:complete)
      %{s | wizard: nil}
    else
      s
    end
  end

  defp boards_of(%{hall_id: nil}), do: Boards.list()

  defp boards_of(%{hall_id: hall_id}),
    do: Enum.filter(Boards.list(), &(Alnasl.Halls.of(&1) == hall_id))

  defp active(w), do: %{w | active_at: System.system_time(:millisecond)}

  defp expire(%{wizard: %{active_at: at}} = s) do
    if System.system_time(:millisecond) - at > idle_ms() do
      announce(:wizard)
      %{s | wizard: nil}
    else
      s
    end
  end

  defp expire(s), do: s

  defp idle_ms, do: Application.get_env(:alnasl, :finder_idle_ms, @idle_ms)

  defp public(s) do
    %{
      last: s.last,
      touches: s.touches,
      wizard:
        s.wizard && Map.take(s.wizard, [:next, :first, :done, :skipped, :started_at, :hall_id])
    }
  end

  defp announce(event), do: Phoenix.PubSub.broadcast(Alnasl.PubSub, @topic, {:finder, event})

  # The database being busy must not end the run, or this process.
  defp safely(fun) do
    fun.()
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end
end
