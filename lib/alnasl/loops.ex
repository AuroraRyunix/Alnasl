defmodule Alnasl.Loops do
  @moduledoc """
  Boards on a loop, as rows: who is on a port, and a row for each.

  The arbiter never types a number for this. He picks the port; the box
  asks the line who is there (`Arkab.Dgt.Loop`) and makes of it what it is:

  - nobody answers, or one board: a single board on its own port
    (`dgt_serial`), as before. (One board on a loop cable is read that way
    too. It is the same board either way, and the single-board driver is
    the one that has seen a clock.)
  - two or more: a loop. Each board gets a row (`dgt_bus`) with the number
    it answers to as its address - an internal detail, shown in small
    print.

  ## Which row a board on a loop gets

  `row_for/2`, in this order:

  1. the row that already has that address on that port;
  2. a row with that address on another port, not connected now: the loop
     was plugged into another adapter;
  3. a row that learned that address when the board was alone on a port
     (the single-board driver asks, and the row keeps it) - the board keeps
     its serial number, its table number and its games;
  4. a new row, "Board 06310".

  A board with firmware 1.x then says its serial number (its address IS
  its serial number: `Arkab.Dgt.Bus.serial/2`), and the usual recognition
  takes over (`Alnasl.Tables.recognise/4`): a row the box already has for
  that serial takes the place. A newer board's address says nothing about
  its serial number; on a loop it is known by the address until it has been
  seen alone once.

  ## A board added to the loop later

  The bus notices (`Arkab.Driver.DgtBus`, every ten seconds, without
  stopping the reading) and calls `stranger/2`: the board gets its row, and
  the log says so. A board taken off the loop stops answering: its row
  stays, says "No signal", and is back when the board is.
  """

  alias Alnasl.{Boards, Log}
  alias Arkab.Transport
  alias Alnasl.Boards.Board
  alias Arkab.Dgt.{Bus, Loop}
  alias Arkab.Driver.DgtBus

  @doc """
  Asks the line on `port` who is there: `{:ok, addresses}` or `{:error,
  reason}` (the port cannot be opened: somebody has it, or it is gone). When
  a loop is already being read on that port, it is that loop's word.

  Takes two to four seconds on a closed port: call it from a task.
  """
  def probe(port, tries \\ 1) do
    # A box without boards of its own opens no port, not even to ask.
    if Boards.local?(), do: probe_line(port, tries), else: {:error, :no_local_boards}
  end

  defp probe_line(port, tries) do
    case DgtBus.whereis(port) do
      nil -> ask(port, tries)
      bus -> {:ok, DgtBus.present(bus)}
    end
  catch
    :exit, _reason -> ask(port, tries)
  end

  # A port that was let go of a moment ago is not always free yet.
  defp ask(port, tries) do
    transport = Transport.for_port(port)

    case transport.open(port, baud: Arkab.Dgt.Protocol.baud()) do
      {:ok, handle} ->
        try do
          addresses = Loop.discover(transport, handle)
          transport.write(handle, Bus.command(:end_busmode, 0))
          {:ok, addresses}
        after
          transport.close(handle)
        end

      {:error, _busy} when tries > 1 ->
        Process.sleep(250)
        ask(port, tries - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Adds whatever is on `port`: `{:ok, :loop | :single, [board]}`. `name` is
  for a single board; the boards of a loop are named after their numbers.
  """
  def add(port, name \\ nil) do
    if Boards.local?(), do: add_port(port, name), else: {:error, :no_local_boards}
  end

  defp add_port(port, name) do
    case probe(port) do
      {:ok, [_, _ | _] = addresses} ->
        {:ok, :loop, adopt(port, addresses)}

      # A port that cannot be opened now gets its row all the same: the
      # row says so, keeps trying, and asks again when it gets through.
      other ->
        address =
          case other do
            {:ok, [alone]} -> alone
            _nobody -> nil
          end

        with {:ok, board} <-
               Boards.create(%{
                 name: name || default_name(),
                 driver: "dgt_serial",
                 port: port,
                 address: address,
                 options: %{}
               }) do
          {:ok, :single, [board]}
        end
    end
  end

  defp default_name, do: "Board #{length(Boards.list()) + 1}"

  @doc "A row for each of `addresses` on `port`, connected. Returns the rows."
  def adopt(port, addresses) do
    for address <- addresses do
      {:ok, board} = row_for(port, address)
      board
    end
  end

  @doc """
  The row of a single board turned out to be a loop: its port is read as
  one. A row that knows which board it is becomes that board's row on the
  loop. Otherwise it goes when nobody gave it a number; a numbered row
  stays, switched off, until its own board says who it is - which a board
  with firmware 1.x does at once, and then the row is that board's again.
  """
  def read_as_loop(%Board{driver: "dgt_serial", port: port} = row) when is_binary(port) do
    Boards.stop(row)

    with {:ok, addresses} when length(addresses) > 1 <- probe(port, 8) do
      Log.add(:info, "loop.read", %{port: port, boards: length(addresses)}, %{board_id: row.id})
      boards = adopt(port, addresses)

      # The row was one of them (it knew its board's number), or it is in
      # the way.
      case Boards.get(row.id) do
        %Board{driver: "dgt_serial"} = left ->
          if Alnasl.Tables.new?(left),
            do: Boards.delete(left),
            else: Boards.update(left, %{enabled: false})

        _one_of_them ->
          :ok
      end

      {:ok, boards}
    else
      {:ok, _one_or_none} ->
        Boards.start(row)
        {:error, :not_a_loop}

      {:error, reason} ->
        Boards.start(row)
        {:error, reason}
    end
  end

  def read_as_loop(_other), do: {:error, :not_a_single_board}

  @doc """
  A board answered on the loop of `port` that has no row. Called by the bus,
  in the bus's own process: the row is made elsewhere, because making it
  starts a board that calls the bus.
  """
  def stranger(port, address) do
    Task.Supervisor.start_child(Alnasl.TaskSupervisor, fn ->
      {:ok, board} = row_for(port, address)
      Log.add(:info, "loop.joined", %{name: board.name, port: port}, %{board_id: board.id})
    end)

    :ok
  end

  @doc "The row for the board that answers as `address` on the loop of `port`, connected."
  def row_for(port, address) do
    rows = Enum.filter(Boards.list(), &(&1.driver in ["dgt_serial", "dgt_bus"]))
    here = %{driver: "dgt_bus", port: port, address: address, enabled: true}

    known =
      Enum.find(rows, &(&1.driver == "dgt_bus" and &1.port == port and &1.address == address)) ||
        Enum.find(rows, &(&1.driver == "dgt_bus" and &1.address == address and away?(&1))) ||
        Enum.find(
          rows,
          &(&1.address == address and &1.serial not in [nil, ""] and away?(&1, port))
        )

    case known do
      nil ->
        Boards.create(Map.merge(here, %{name: "Board " <> Bus.number(address), options: %{}}))

      %Board{} = row ->
        if row.driver != "dgt_bus" or row.port != port do
          Log.add(
            :info,
            "board.recognised",
            %{
              name: row.name,
              serial: row.serial || Bus.number(address),
              from: row.port,
              to: port,
              table: row.table_no
            },
            %{board_id: row.id}
          )
        end

        Boards.update(row, here)
    end
  end

  # Not being read anywhere else just now. A single-board row on this very
  # port counts as away: the port is a loop, so it reads nothing.
  defp away?(row, port \\ nil),
    do: row.port == port or Boards.snapshot(row).connected? != true
end
