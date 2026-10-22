defmodule Alnasl.FairPlay.Uci do
  @moduledoc """
  One UCI engine behind a Port, asked one position at a time.

  The engine is set up once (`Threads 1`, `Hash 64`, `MultiPV 4` unless
  told otherwise) and then, per position:

      ucinewgame / isready
      position (startpos | fen F) moves ...
      go nodes N

  and the answer is the last `info` line of each `multipv` before
  `bestmove`: the engine's four best moves with their evaluations. When the
  move that was actually played is not among them, a second search with
  `go nodes N searchmoves <move>` prices it.

  Why `ucinewgame` before every position: with one thread and a fixed node
  count Stockfish is deterministic, but only from the same hash. Clearing
  it each time makes a position's numbers independent of what the engine
  happened to look at before, so a game scores the same whether the queue
  took it first or last. That costs a hash clear per position, which is
  nothing next to a million nodes.

  Scores come back in centipawns from the side to move's point of view, as
  UCI gives them. A mate is `±(10000 − plies)`: mate in 2 for the mover
  (3 plies) is 9997, being mated in 1 (2 plies) is −9998.

  An engine that dies or stops answering is killed, started again, and
  asked once more. A second failure is returned as an error; the GenServer
  stays up and starts a fresh engine for the next position.

  The parsing (`parse_info/1`, `collect/1`, `mate_cp/1`) is public and pure,
  so a transcript of a real engine can be tested without one.
  """

  use GenServer
  require Logger

  @default_options [{"Threads", 1}, {"Hash", 64}, {"MultiPV", 4}]
  @handshake_timeout 30_000

  @type line :: %{move: String.t(), cp: integer()}
  @type result :: %{
          best: [line()],
          played_cp: integer() | nil,
          bestmove: String.t() | nil,
          restarted: boolean()
        }

  @type position :: String.t() | %{optional(:start_fen) => String.t() | nil, moves: [String.t()]}

  # --- API ---------------------------------------------------------------------

  @doc """
  Starts an engine.

    * `:cmd` - the executable (required)
    * `:args` - its arguments (default none)
    * `:options` - `[{name, value}]` sent as `setoption` (default Threads 1,
      Hash 64, MultiPV 4)
    * `:timeout` - how long one search may take, ms (default 120 000)
    * `:low_priority` - ask the operating system to give the engine's
      process the lowest priority, so the machine's own work (the tracker,
      the page) wins when cores are scarce; best effort, never an error
    * `:name` - a GenServer name
  """
  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  The engine's view of a position: a FEN, or `%{start_fen: fen | nil, moves:
  [uci]}` (better: the engine then sees the game's repetitions).

  Options: `:nodes` (default 1 000 000), `:played` (the UCI move played
  there, priced separately when it is not in the top lines).
  """
  @spec analyse(GenServer.server(), position(), keyword()) :: {:ok, result()} | {:error, term()}
  def analyse(server, position, opts \\ []) do
    GenServer.call(server, {:analyse, position, opts}, :infinity)
  end

  @doc "What the engine said it is, and how often it had to be restarted."
  def info(server), do: GenServer.call(server, :info)

  @doc "`start_link/1` without the link: a failed engine is an answer, not a crash."
  def start(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start(__MODULE__, opts, gen_opts)
  end

  def stop(server), do: GenServer.stop(server)

  @doc """
  An engine function for `Alnasl.FairPlay.Analyzer`: `fn position, played ->
  {:ok, %{best, played_cp}} | {:error, reason}`.
  """
  def engine_fun(server, nodes) do
    fn position, played -> analyse(server, position, nodes: nodes, played: played) end
  end

  # --- server ------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      cmd: Keyword.fetch!(opts, :cmd),
      args: Keyword.get(opts, :args, []),
      options: Keyword.get(opts, :options, @default_options),
      timeout: Keyword.get(opts, :timeout, 120_000),
      low_priority: Keyword.get(opts, :low_priority, false),
      port: nil,
      id: %{},
      restarts: 0,
      buffer: ""
    }

    case boot(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason, _state} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, Map.merge(state.id, %{restarts: state.restarts}), state}
  end

  def handle_call({:analyse, position, opts}, _from, state) do
    case attempt(state, position, opts) do
      {:ok, result, state} ->
        {:reply, {:ok, Map.put(result, :restarted, false)}, state}

      {:error, first, state} ->
        Logger.warning("fair play: engine failed (#{inspect(first)}), restarting it once")
        state = %{kill(state) | restarts: state.restarts + 1}

        with {:ok, state} <- boot(state),
             {:ok, result, state} <- attempt(state, position, opts) do
          {:reply, {:ok, Map.put(result, :restarted, true)}, state}
        else
          {:error, second, state} ->
            {:reply, {:error, {:engine_failed, second}}, kill(state)}
        end
    end
  end

  @impl true
  def handle_info({port, {:exit_status, _}}, %{port: port} = state),
    do: {:noreply, %{state | port: nil}}

  def handle_info(_stale, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.port do
      send_line(state, "quit")
      kill(state)
    end

    :ok
  end

  # --- conversation ------------------------------------------------------------

  defp boot(state) do
    port =
      Port.open({:spawn_executable, state.cmd}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        {:line, 16_384},
        args: state.args
      ])

    state = %{state | port: port, buffer: "", id: %{}}
    if state.low_priority, do: lower_priority(port)
    send_line(state, "uci")

    with {:ok, lines, state} <- until(state, "uciok", @handshake_timeout) do
      id =
        for "id " <> rest <- lines,
            [key, value] <- [String.split(rest, " ", parts: 2)],
            key in ["name", "author"],
            into: %{},
            do: {if(key == "name", do: :name, else: :author), value}

      Enum.each(state.options, fn {name, value} ->
        send_line(state, "setoption name #{name} value #{value}")
      end)

      send_line(state, "isready")

      with {:ok, _, state} <- until(state, "readyok", @handshake_timeout) do
        {:ok, %{state | id: id}}
      end
    end
  rescue
    e in ErlangError -> {:error, {:cannot_start, e.original}, %{state | port: nil}}
  end

  # Nice 19 on Unix, "below normal" on Windows: the engine is a guest.
  # Asked of the system from a task of its own, so a slow `powershell` never
  # delays the handshake, and any failure is nobody's business.
  defp lower_priority(port) do
    with {:os_pid, os_pid} <- Port.info(port, :os_pid) do
      Task.start(fn ->
        try do
          case :os.type() do
            {:win32, _} ->
              System.cmd(
                "powershell",
                [
                  "-NoProfile",
                  "-Command",
                  "(Get-Process -Id #{os_pid}).PriorityClass = 'BelowNormal'"
                ],
                stderr_to_stdout: true
              )

            _unix ->
              System.cmd("renice", ["-n", "19", "-p", "#{os_pid}"], stderr_to_stdout: true)
          end
        rescue
          _error -> :ok
        end
      end)
    end

    :ok
  end

  defp attempt(%{port: nil} = state, _position, _opts), do: {:error, :not_running, state}

  defp attempt(state, position, opts) do
    nodes = Keyword.get(opts, :nodes, 1_000_000)
    played = Keyword.get(opts, :played)
    position_line = position_command(position)

    with {:ok, state} <- fresh(state),
         {:ok, lines, state} <- search(state, position_line, "go nodes #{nodes}") do
      %{best: best, bestmove: bestmove} = collect(lines)

      cond do
        played == nil ->
          {:ok, %{best: best, bestmove: bestmove, played_cp: nil}, state}

        found = Enum.find(best, &(&1.move == played)) ->
          {:ok, %{best: best, bestmove: bestmove, played_cp: found.cp}, state}

        true ->
          go = "go nodes #{nodes} searchmoves #{played}"

          with {:ok, lines, state} <- search(state, position_line, go) do
            played_cp =
              case collect(lines).best do
                [%{cp: cp} | _] -> cp
                [] -> nil
              end

            {:ok, %{best: best, bestmove: bestmove, played_cp: played_cp}, state}
          end
      end
    end
  end

  defp fresh(state) do
    send_line(state, "ucinewgame")
    send_line(state, "isready")

    case until(state, "readyok", @handshake_timeout) do
      {:ok, _, state} -> {:ok, state}
      error -> error
    end
  end

  defp search(state, position_line, go) do
    send_line(state, position_line)
    send_line(state, go)
    until(state, "bestmove", state.timeout)
  end

  @doc "The `position` command for a FEN or a start position and moves."
  @spec position_command(position()) :: String.t()
  def position_command(fen) when is_binary(fen), do: "position fen " <> fen

  def position_command(%{moves: moves} = position) do
    base =
      case position[:start_fen] do
        nil -> "position startpos"
        fen -> "position fen " <> fen
      end

    if moves == [], do: base, else: base <> " moves " <> Enum.join(moves, " ")
  end

  defp send_line(%{port: nil}, _line), do: :ok

  defp send_line(%{port: port}, line) do
    Port.command(port, line <> "\n")
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Reads lines until one starts with `stop`, which is included. Everything
  # an engine says on the way is kept: the `info string` before a crash is
  # the only explanation one gets.
  defp until(state, stop, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    read(state, stop, deadline, [])
  end

  defp read(%{port: port} = state, stop, deadline, acc) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:noeol, part}}} ->
        read(%{state | buffer: state.buffer <> part}, stop, deadline, acc)

      {^port, {:data, {:eol, part}}} ->
        line = String.trim_trailing(state.buffer <> part, "\r")
        state = %{state | buffer: ""}

        if String.starts_with?(line, stop),
          do: {:ok, Enum.reverse([line | acc]), state},
          else: read(state, stop, deadline, [line | acc])

      {^port, {:exit_status, status}} ->
        said = acc |> Enum.filter(&String.starts_with?(&1, "info string")) |> Enum.take(3)
        {:error, {:exited, status, Enum.reverse(said)}, %{state | port: nil}}
    after
      wait -> {:error, {:timeout, stop}, state}
    end
  end

  # Port.close does not stop a program that ignores its stdin, and on
  # Windows it stops nothing at all; the OS pid does.
  defp kill(%{port: nil} = state), do: state

  defp kill(%{port: port} = state) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    if os_pid do
      case :os.type() do
        {:win32, _} ->
          System.cmd("taskkill", ["/F", "/T", "/PID", "#{os_pid}"], stderr_to_stdout: true)

        _unix ->
          System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
      end
    end

    %{state | port: nil, buffer: ""}
  end

  # --- parsing -----------------------------------------------------------------

  @doc """
  One `info` line as `%{multipv, cp, move, bound}`, or `nil` for a line
  that carries no scored line of play (`currmove`, `string`, `hashfull`
  only...). `bound` is `nil`, `:lower` or `:upper`.
  """
  @spec parse_info(String.t()) ::
          %{multipv: pos_integer(), cp: integer(), move: String.t(), bound: atom() | nil} | nil
  def parse_info("info " <> rest) do
    tokens = String.split(rest)

    if "string" in Enum.take(tokens, 1) do
      nil
    else
      fields(tokens, %{multipv: 1, cp: nil, move: nil, bound: nil})
    end
  end

  def parse_info(_other), do: nil

  defp fields([], %{cp: cp, move: move} = acc) when is_integer(cp) and is_binary(move), do: acc
  defp fields([], _incomplete), do: nil
  defp fields(["multipv", k | rest], acc), do: fields(rest, %{acc | multipv: int(k)})
  defp fields(["score", "cp", x | rest], acc), do: fields(rest, %{acc | cp: int(x)})
  defp fields(["score", "mate", y | rest], acc), do: fields(rest, %{acc | cp: mate_cp(int(y))})
  defp fields(["lowerbound" | rest], acc), do: fields(rest, %{acc | bound: :lower})
  defp fields(["upperbound" | rest], acc), do: fields(rest, %{acc | bound: :upper})
  # The principal variation is the rest of the line; its first move is ours.
  defp fields(["pv", move | _rest], acc), do: fields([], %{acc | move: move})
  defp fields([_ | rest], acc), do: fields(rest, acc)

  defp int(text) do
    case Integer.parse(text) do
      {n, _} -> n
      :error -> 0
    end
  end

  @doc """
  A UCI mate score in centipawns: `mate y` is mate in `y` moves for the side
  to move (negative: being mated). Mate in `y > 0` is `2y − 1` plies away,
  being mated in `|y|` is `2|y|`; the score is `±(10000 − plies)`, so a
  nearer mate is worth more and every mate outranks every evaluation.
  """
  @spec mate_cp(integer()) :: integer()
  def mate_cp(y) when is_integer(y) and y > 0, do: 10_000 - (2 * y - 1)
  def mate_cp(y) when is_integer(y) and y < 0, do: -(10_000 - 2 * -y)
  def mate_cp(0), do: -10_000

  @doc """
  The search's answer from its output lines: the last scored `info` of each
  `multipv`, best first, and `bestmove`.

  Best first means: line 1 first (the move the engine chose), the others
  by score. They are not simply in `multipv` order because the last
  iteration is often unfinished, and its later lines are then left over
  from the depth before - sometimes scoring above line 2 of the newer one.
  """
  @spec collect([String.t()]) :: %{best: [line()], bestmove: String.t() | nil}
  def collect(lines) do
    last =
      Enum.reduce(lines, %{}, fn line, acc ->
        case parse_info(line) do
          nil -> acc
          info -> Map.put(acc, info.multipv, info)
        end
      end)

    {first, rest} =
      last
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {_, info} -> %{move: info.move, cp: info.cp} end)
      |> Enum.split(1)

    bestmove =
      Enum.find_value(lines, fn
        "bestmove " <> rest -> rest |> String.split() |> List.first()
        _ -> nil
      end)

    %{best: first ++ Enum.sort_by(rest, & &1.cp, :desc), bestmove: bestmove}
  end
end
