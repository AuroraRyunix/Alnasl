defmodule AlnaslWeb.TableWords do
  @moduledoc """
  Sentences about which board is which: a board's identity, and each line of
  the "ready / not ready" list (`Alnasl.Tables.checks/1`).
  """

  use Gettext, backend: AlnaslWeb.Gettext

  alias Alnasl.Tables

  @doc "\"serial 06310\", \"no. 12799 on the loop\", \"slot sim-3\", \"port COM7\"."
  def identity(board) do
    case Tables.identity(board) do
      {:serial, serial} -> gettext("serial %{s}", s: serial)
      {:address, address} -> gettext("no. %{a} on the loop", a: Alnasl.Dgt.Bus.number(address))
      {:slot, slot} -> gettext("slot %{s}", s: slot)
      {:port, nil} -> gettext("no port")
      {:port, port} -> gettext("port %{p}", p: port)
    end
  end

  @doc "\"table 7 · serial 06310\" - what is small on a tile."
  def sticker(%{table_no: nil} = board), do: identity(board)

  def sticker(%{table_no: table} = board),
    do: gettext("table %{n}", n: table) <> " · " <> identity(board)

  def sticker(board), do: identity(board)

  @doc "One line of the checks as `{tone, sentence}`."
  def check(%{level: level, what: what}), do: {tone(level), sentence(what)}

  defp tone(:bad), do: "bad"
  defp tone(:warn), do: "warn"
  defp tone(_info), do: nil

  defp names(names), do: Enum.map_join(names, ", ", &"\"#{&1}\"")

  defp sentence({:outside, name, titles}),
    do:
      gettext(
        "%{name} is not playing in %{tournament}: what it reads goes nowhere. Put it there (the line under the bar), or give its table to a tournament in Setup.",
        name: name,
        tournament: Enum.join(titles, " / ")
      )

  defp sentence({:duplicate_table, n, names}),
    do:
      gettext("Table %{n} is on more than one board: %{names}. A sticker belongs on one.",
        n: n,
        names: names(names)
      )

  defp sentence({:duplicate_board, n, names}),
    do:
      gettext("Board %{n} of the round is fed by more than one board: %{names}.",
        n: n,
        names: names(names)
      )

  defp sentence({:same_serial, serial, names}),
    do:
      gettext(
        "Serial %{serial} is seen more than once (%{names}): the same board on two ports, or two adapters on one loop. Remove one.",
        serial: serial,
        names: names(names)
      )

  defp sentence({:other_board, name, serial, seen}),
    do:
      gettext(
        "The board on the cable of \"%{name}\" says it is serial %{seen}, not %{serial}. Nothing was changed mid-game: check which board stands there.",
        name: name,
        serial: serial,
        seen: seen
      )

  defp sentence({:no_signal, name, n}),
    do:
      gettext("Board %{n}: \"%{name}\" does not answer. Check cable and power.", n: n, name: name)

  defp sentence({:start_wrong, name, n, count}),
    do:
      gettext(
        "Board %{n}: the pieces on \"%{name}\" are not in the starting position (%{count} wrong). Colours swapped, or king and queen?",
        n: n,
        name: name,
        count: count
      )

  # The same sentence the Boards column and the Round tile use, with the
  # board it is about in front.
  defp sentence({:clock_wrong, name, n, side}),
    do:
      gettext("Board %{n}, \"%{name}\": %{problem}.",
        n: n,
        name: name,
        problem: AlnaslWeb.Words.clock_problem({:wrong, side})
      )

  defp sentence({:no_number, name}),
    do: gettext("\"%{name}\" is connected but feeds no board of this round.", name: name)

  defp sentence({:no_table, name}),
    do: gettext("\"%{name}\" has no table number yet.", name: name)

  defp sentence({:gap, n}),
    do: gettext("Board %{n} of the round has no electronic board, though higher boards do.", n: n)

  defp sentence({:gap_match, n, match, place}),
    do:
      gettext(
        "Board %{n} of the round (match %{match}, board %{place}) has no electronic board, though higher boards do.",
        n: n,
        match: match,
        place: place
      )

  defp sentence({:part_match, match, have, of}),
    do:
      gettext("Match %{match}: %{have} of its %{of} boards are on electronic boards.",
        match: match,
        have: have,
        of: of
      )

  defp sentence({:turned, name, n}),
    do:
      gettext("Board %{n}: \"%{name}\" is plugged in turned round. It is read the other way up.",
        n: n,
        name: name
      )

  defp sentence({:remapped, name, table, n}),
    do:
      gettext("\"%{name}\" (table %{table}) plays board %{n} this round, as you asked.",
        name: name,
        table: table,
        n: n
      )

  defp sentence({:uncovered, count}),
    do: gettext("%{count} board(s) of the round have no electronic board.", count: count)

  defp sentence(_other), do: gettext("Something is not as expected.")
end
