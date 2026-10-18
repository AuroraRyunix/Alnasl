defmodule Alnasl.Wizard do
  @moduledoc """
  The setup wizard of a hall (Setup, Setup wizard): a few answers about what
  the hall looks like, and the steps that follow from them, each ticked off
  by what the box really has - never by somebody having pressed "Next".

  ## The answers

  Kept per hall, as a setting (`"wizard:<hall id>"`), so the wizard can be
  opened again, answered again and changed, and the ticks keep working:

  * `shape` - `"simple"` (one hall, one computer with the boards, one
    tournament), `"tournaments"` (one hall, several tournaments) or
    `"halls"` (several halls or rooms);
  * `halls` - how many halls, on the server with `"halls"`;
  * `bridges` - how many Arkab bridges in this hall: always on the server
    (boards split over rooms or tables need one each), on a box only for
    the rooms beyond the one it stands in;
  * `boards` - roughly how many boards per bridge, or on the box itself;
  * `tournaments` - how many tournaments, with `"tournaments"`;
  * `extras` - what else the hall wants (`extras/1`);
  * `done` - the steps nobody here can see done (a print station, an
    announcer: they talk to OpenPairings, not to Alnasl), marked by hand,
    and shown as marked by hand.

  ## The steps

  `plan/3` turns the answers and the hall's rows into steps, in the order
  they depend on each other: `%{key, done?, can, have, want, ...}`. What a
  step says is the page's business (`AlnaslWeb.WizardComponents`); what
  decides the tick is here, from the bridges, boards, tournaments and
  settings themselves.
  """

  alias Alnasl.{Boards, Bridges, Halls, Repo, Settings, Tournaments}
  alias Alnasl.Accounts.Scope

  @shapes ~w(simple tournaments halls)
  # Polis prints, Nunki speaks: both join OpenPairings, so Alnasl only
  # hears about them from whoever ticks the box.
  @manual ~w(polis nunki)

  @doc "The shapes a hall can have, in the order they are offered."
  def shapes, do: @shapes

  @doc """
  The extras offered in this edition, for a hall: the results site always,
  Lichess where Setup has its card (the own hall), the print station and
  the announcer, and on a box the other machines in the hall (phones, the
  PIN). The server is on the internet already; it needs no letting in.
  """
  def extras(%{server?: server?, own_hall?: own_hall?}) do
    ["results"] ++
      if(own_hall?, do: ["lichess"], else: []) ++
      ["polis", "nunki"] ++
      if(server?, do: [], else: ["phone"])
  end

  @doc "Are the extras of `key` marked by hand (Alnasl cannot see them)?"
  def manual?(key), do: key in @manual

  defp key(hall_id), do: "wizard:#{hall_id}"

  @doc "The answers of hall `hall_id`, or `nil` when nobody has answered yet."
  def answers(hall_id) do
    case Settings.get(key(hall_id)) do
      %{} = answers -> normalize(answers)
      _none -> nil
    end
  end

  @doc "What the form starts with: the answers given, else the defaults."
  def defaults(server?) do
    %{
      "shape" => "simple",
      "halls" => 2,
      "bridges" => if(server?, do: 1, else: 0),
      "boards" => 8,
      "tournaments" => 2,
      "extras" => ["results"],
      "done" => []
    }
  end

  @doc """
  Keeps the answers of a form, made sensible: numbers in range, a shape
  that exists, only extras this hall is offered. The marks by hand stay.
  """
  def save(hall_id, params, ctx) do
    old = answers(hall_id) || defaults(ctx.server?)

    extras =
      params
      |> Map.get("extras", [])
      |> List.wrap()
      |> Enum.filter(&(&1 in extras(ctx)))

    answers =
      normalize(%{
        "shape" => params["shape"],
        "halls" => params["halls"],
        "bridges" => params["bridges"],
        "boards" => params["boards"],
        "tournaments" => params["tournaments"],
        "extras" => extras,
        "done" => old["done"]
      })

    # A box in one room has no bridges, whatever the field said before the
    # shape was changed under it.
    answers =
      if ctx.server? or answers["shape"] == "halls",
        do: Map.update!(answers, "bridges", &max(&1, 1)),
        else: Map.put(answers, "bridges", 0)

    Settings.put(key(hall_id), answers)
    answers
  end

  @doc "Marks a step nobody here can see (`manual?/1`) as done, or not."
  def mark(hall_id, key, done?) when key in @manual do
    case answers(hall_id) do
      nil ->
        :error

      answers ->
        done = List.delete(answers["done"], key)
        Settings.put(key(hall_id), %{answers | "done" => if(done?, do: [key | done], else: done)})
        :ok
    end
  end

  def mark(_hall_id, _key, _done?), do: :error

  @doc "Forgets the answers of a hall (it is being deleted)."
  def forget(hall_id) do
    import Ecto.Query, only: [from: 2]
    key = key(hall_id)
    Repo.delete_all(from s in Alnasl.Settings.Setting, where: s.key == ^key)
    :ok
  end

  defp normalize(a) do
    %{
      "shape" => if(a["shape"] in @shapes, do: a["shape"], else: "simple"),
      "halls" => int(a["halls"], 2, 1, 50),
      "bridges" => int(a["bridges"], 0, 0, 50),
      "boards" => int(a["boards"], 8, 1, 500),
      "tournaments" => int(a["tournaments"], 2, 1, 50),
      "extras" => a["extras"] |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.uniq(),
      "done" => a["done"] |> List.wrap() |> Enum.filter(&(&1 in @manual)) |> Enum.uniq()
    }
  end

  defp int(value, _default, lo, hi) when is_integer(value), do: value |> max(lo) |> min(hi)

  defp int(value, default, lo, hi) do
    case Integer.parse(to_string(value)) do
      {n, _rest} -> int(n, default, lo, hi)
      :error -> default
    end
  end

  # --- the plan ----------------------------------------------------------------

  @doc """
  The steps for hall `hall_id` as `scope` sees it, from its answers:
  `%{answers, steps, current, complete?}`. `current` is the key of the
  first step not done; `complete?` is answered and every step done. Without
  answers there are no steps yet, and the wizard is not complete.

  `ctx` is what the page knows already: `server?`, `own_hall?` and `lan?`
  (other machines in the hall may reach the box).
  """
  def plan(scope, hall_id, ctx) do
    case answers(hall_id) do
      nil ->
        %{answers: nil, steps: [], current: nil, complete?: false}

      answers ->
        steps = steps(answers, facts(scope, hall_id), ctx)
        current = Enum.find(steps, &(not &1.done?))

        %{
          answers: answers,
          steps: steps,
          current: current && current.key,
          complete?: current == nil
        }
    end
  end

  @doc "Is the wizard of this hall answered, and is every step of it done?"
  def complete?(scope, hall_id, ctx), do: plan(scope, hall_id, ctx).complete?

  defp facts(scope, hall_id) do
    boards = Halls.here(scope, Boards.list())

    bridges =
      for b <- Bridges.list(), Halls.of(b) == hall_id do
        %{bridge: b, live?: Bridges.live(b.id) != nil, ever?: b.last_connected_at != nil}
      end

    tournaments = Halls.here(scope, Tournaments.list())
    linked = Enum.filter(tournaments, &(Tournaments.linked?(&1) and not &1.gone))

    %{
      hall_id: hall_id,
      halls: if(scope && not scope.open?, do: length(scope.halls), else: 1),
      bridges: bridges,
      boards: length(boards),
      own_boards: Enum.count(boards, &(&1.driver in ~w(dgt_serial dgt_bus))),
      numbered: Enum.count(boards, &(&1.table_no != nil)),
      linked: linked,
      # Every free table can go to one tournament; two of them need ranges.
      free_tables: Enum.count(linked, &(Tournaments.tables(&1, hall_id) == {nil, nil})),
      results?: Enum.any?(tournaments, &Tournaments.openresults_configured?/1),
      lichess?: Enum.any?(tournaments, &Tournaments.lichess_configured?/1)
    }
  end

  defp steps(a, f, ctx) do
    halls? = a["shape"] == "halls"
    n = if ctx.server? or halls?, do: max(a["bridges"], 1), else: 0
    want_tournaments = if a["shape"] == "tournaments", do: max(a["tournaments"], 2), else: 1

    [
      (ctx.server? and halls?) &&
        step(:halls, f.halls >= a["halls"], :admin, have: f.halls, want: a["halls"]),
      not ctx.server? &&
        step(:plug, f.own_boards >= a["boards"], :arbiter,
          have: f.own_boards,
          want: a["boards"]
        ),
      n > 0 && step(:arkab, Enum.any?(f.bridges, & &1.ever?), :anyone),
      for i <- 1..max(n, 1)//1, n > 0 do
        b = Enum.at(f.bridges, i - 1)

        step({:bridge, i}, b != nil and b.ever?, :owner,
          of: n,
          name: b && b.bridge.name,
          joined?: b != nil,
          live?: b != nil and b.live?
        )
      end,
      ctx.server? &&
        step(:boards, f.boards >= a["boards"] * n, :anyone, have: f.boards, want: a["boards"] * n),
      step(:connect, length(f.linked) >= want_tournaments, :arbiter,
        have: length(f.linked),
        want: want_tournaments
      ),
      a["shape"] == "tournaments" &&
        step(:tables, f.linked != [] and f.free_tables <= 1, :arbiter),
      step(:number, f.boards > 0 and f.numbered == f.boards, :arbiter,
        have: f.numbered,
        want: f.boards
      ),
      for x <- extras(ctx), x in a["extras"] do
        case x do
          "results" -> step(:results, f.results?, :arbiter)
          "lichess" -> step(:lichess, f.lichess?, :arbiter)
          "phone" -> step(:phone, ctx.lan?, :admin)
          "polis" -> step(:polis, "polis" in a["done"], :arbiter, manual?: true)
          "nunki" -> step(:nunki, "nunki" in a["done"], :arbiter, manual?: true)
        end
      end
    ]
    |> List.flatten()
    |> Enum.filter(& &1)
  end

  defp step(key, done?, can, extra \\ []),
    do: Map.merge(%{key: key, done?: done?, can: can, manual?: false}, Map.new(extra))

  @doc "May `scope` do what step `step` needs, in hall `hall_id`?"
  def can?(_scope, %{can: :anyone}, _hall_id), do: true
  def can?(scope, %{can: :admin}, _hall_id), do: Scope.can?(scope, :admin)
  def can?(scope, %{can: need}, hall_id), do: Scope.can?(scope, need, hall_id)
end
