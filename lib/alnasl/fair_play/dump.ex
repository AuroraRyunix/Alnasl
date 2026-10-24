defmodule Alnasl.FairPlay.Dump do
  @moduledoc """
  Every counted ply of a calibration run as one line of numbers, for
  looking at the score from outside Elixir: what the model expected, what
  happened, and enough of the position to ask why. No names, no events,
  no moves - integers for the player-event and the game, a hash for the
  event's split.

  Two sets: `held` (the held-out player-events, residuals of the model
  fitted on the training events, as `mix fair_play.fit` scores them) and
  `cross` (the training events, residuals of the half-model that did not
  see them: what the fit measures its correlations and scan on).

      mix fair_play.dump --holdout 0.67 --out plies.csv labels.jsonl
  """

  alias Alnasl.FairPlay.{Calibration, Model, Selection, Stats}

  @columns ~w(set pe game ev fold rating opp near gap cp1 cp2 cp3 cp4 played rank material think p q lm lv loss)

  def main(argv, opts \\ [halt: true]) do
    {parsed, paths, _} =
      OptionParser.parse(argv, strict: [holdout: :float, out: :string, model: :string])

    holdout = Keyword.get(parsed, :holdout, 0.2)
    out = Keyword.fetch!(parsed, :out)

    {:ok, games, _meta} = Calibration.read_labels(paths)

    {held, train} =
      Enum.split_with(games, &Calibration.held_out?(Calibration.holdout_key(&1), holdout))

    keyed = Calibration.keyed_events(train)

    model =
      case parsed[:model] do
        nil -> Model.fit(keyed)
        path -> elem(Model.read(path), 1)
      end

    {a, b} = Enum.split_with(keyed, &(Model.fold(elem(&1, 0)) == 0))
    on_a = Task.async(fn -> Model.regression(Enum.map(a, &elem(&1, 1)), []) end)
    on_b = Model.regression(Enum.map(b, &elem(&1, 1)), [])
    on_a = Task.await(on_a, :infinity)

    {:ok, file} = File.open(out, [:write, :binary])
    IO.binwrite(file, Enum.join(@columns, ",") <> "\n")

    sets =
      [{"held", Calibration.keyed_player_events(held), fn _ -> model end}] ++
        [
          {"cross", Calibration.keyed_player_events(train),
           fn event -> if Model.fold(event) == 0, do: on_b, else: on_a end}
        ]

    {_, _} =
      Enum.reduce(sets, {0, 0}, fn {set, events, pick}, {pe, g} ->
        Enum.reduce(events, {pe, g}, fn {{event, _player}, records}, {pe, g} ->
          key = event || "game:" <> hd(records).game

          ev =
            :crypto.hash(:sha256, "holdout:event:" <> key)
            |> binary_part(0, 4)
            |> :binary.decode_unsigned()

          lines = lines(set, pe, g, ev, Model.fold(key), records, pick.(key))
          IO.binwrite(file, lines.iodata)
          {pe + 1, g + lines.games}
        end)
      end)

    File.close(file)
    if opts[:halt], do: :ok, else: {:ok, out}
  end

  defp lines(set, pe, g0, ev, fold, records, model) do
    counted = records |> Model.prepare() |> Enum.filter(&Selection.counted?/1)
    games = counted |> Enum.map(& &1.game) |> Enum.uniq() |> Enum.with_index() |> Map.new()

    iodata =
      for r <- counted do
        cps = Enum.map(r.best, & &1.cp)

        cp = fn i ->
          case Enum.at(cps, i) do
            nil -> ""
            x -> x
          end
        end

        {lm, lv} = Model.loss_moments(model, r)

        [
          set,
          pe,
          g0 + games[r.game],
          ev,
          fold,
          r.rating,
          r[:opponent_rating] || "",
          r.near_count || 0,
          f(Stats.scaled_gap(r)),
          cp.(0),
          cp.(1),
          cp.(2),
          cp.(3),
          r.played_cp,
          r.rank,
          r.material,
          if(r[:think], do: f(r.think), else: ""),
          f(Model.p_match(model, r)),
          f(Model.p_ev(model, r)),
          f(lm),
          f(lv),
          f(Stats.scaled_loss(r))
        ]
        |> Enum.map(&to_string/1)
        |> Enum.intersperse(",")
        |> then(&[&1, "\n"])
      end

    %{iodata: iodata, games: map_size(games)}
  end

  defp f(x), do: :erlang.float_to_binary(x / 1, decimals: 6)
end
