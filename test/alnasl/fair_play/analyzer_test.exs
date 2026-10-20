defmodule Alnasl.FairPlay.AnalyzerTest do
  use ExUnit.Case, async: true

  alias Alnasl.FairPlay.{Analyzer, Selection}

  # Twenty plies of a quiet Italian, so that moves 9 and 10 of each side
  # are past the opening rule.
  @italian ~w(e4 e5 Nf3 Nc6 Bc4 Bc5 c3 Nf6 d3 d6 O-O O-O h3 a6 Re1 Ba7 Nbd2 h6 Nf1 Re8)

  defp plies(sans, extra \\ %{}),
    do: Enum.map(sans, &Map.merge(%{san: &1, flags: [], clock_ms: nil}, extra))

  defp game(plies, opts \\ []) do
    %{
      start_fen: opts[:start_fen],
      plies: plies,
      white_rating: Keyword.get(opts, :white, 2000),
      black_rating: Keyword.get(opts, :black, 1900),
      result_confirmed: Keyword.get(opts, :confirmed, false)
    }
  end

  # An engine that thinks the move played is always line 2, 15 cp worse.
  defp polite_engine(me \\ nil) do
    fn position, played ->
      if me, do: send(me, {:asked, length(position.moves) + 1, position})

      {:ok,
       %{
         best: [
           %{move: "a1a1", cp: 40},
           %{move: played, cp: 25},
           %{move: "b1b1", cp: 15},
           %{move: "c1c1", cp: -100}
         ],
         played_cp: 25
       }}
    end
  end

  defp skips(records), do: Enum.map(records, & &1.skip)

  describe "SAN to UCI" do
    defp last_uci(fen, sans) do
      {:ok, records} = Analyzer.prepare(game(plies(sans), start_fen: fen))
      List.last(records).played_uci
    end

    test "castling is the king's move" do
      assert last_uci(nil, ~w(e4 e5 Nf3 Nc6 Bc4 Bc5 O-O)) == "e1g1"
      assert last_uci("r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1", ["O-O-O"]) == "e8c8"
      assert last_uci("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", ["0-0-0"]) == "e1c1"
    end

    test "promotion and under-promotion" do
      assert last_uci("3r3k/4P3/8/8/8/8/8/K7 w - - 0 1", ["e8=Q+"]) == "e7e8q"
      assert last_uci("3r3k/4P3/8/8/8/8/8/K7 w - - 0 1", ["exd8=N"]) == "e7d8n"
    end

    test "en passant" do
      assert last_uci(nil, ~w(e4 a6 e5 d5 exd6)) == "e5d6"
    end

    test "an illegal move names its ply" do
      assert {:error, {3, _}} = Analyzer.prepare(game(plies(~w(e4 e5 Ke3))))
    end
  end

  describe "the records" do
    test "one per ply, with the engine's lines, rank, gap and near count" do
      {:ok, records} = Analyzer.analyse(game(plies(@italian)), polite_engine(self()))

      assert length(records) == 20
      r = Enum.at(records, 16)

      assert %{
               ply: 17,
               colour: :white,
               move_number: 9,
               side_ply: 9,
               san: "Nbd2",
               played_uci: "b1d2",
               rating: 2000,
               material: 78,
               played_cp: 25,
               rank: 2,
               gap: 15,
               near_count: 2,
               skip: nil
             } = r

      assert r.fen_key == r.fen |> String.split(" ") |> Enum.take(4) |> Enum.join(" ")
      assert length(r.best) == 4

      # Only the counted plies were searched, from the start and the moves.
      assert_received {:asked, 17, %{start_fen: nil, moves: moves}}
      assert length(moves) == 16
      refute_received {:asked, 1, _}
    end

    test "a played move outside the lines takes the engine's separate price" do
      engine = fn _pos, _played ->
        {:ok, %{best: [%{move: "a1a1", cp: 50}, %{move: "b1b1", cp: 45}], played_cp: -80}}
      end

      {:ok, records} = Analyzer.analyse(game(plies(@italian)), engine)
      assert %{rank: nil, played_cp: -80, gap: 5, near_count: 1} = List.last(records)
    end

    test "a failed search leaves the ply out, and says why" do
      {:ok, records} = Analyzer.analyse(game(plies(@italian)), fn _, _ -> {:error, :timeout} end)
      assert List.last(records).skip == :no_analysis
    end

    test "the clock before the move, from board readings and from PGN clocks" do
      board =
        @italian
        |> Enum.with_index()
        |> Enum.map(fn {san, i} ->
          %{
            san: san,
            flags: [],
            clock: %{white_ms: 600_000 - i * 1000, black_ms: 500_000 - i * 1000}
          }
        end)

      {:ok, records} = Analyzer.prepare(game(board))
      # Ply 3 (white): the reading at ply 2 of white's clock.
      assert Enum.at(records, 2).clock_before_ms == 599_000
      assert hd(records).clock_before_ms == nil

      pgn =
        @italian
        |> Enum.with_index()
        |> Enum.map(&%{san: elem(&1, 0), flags: [], clock_ms: 1000 * elem(&1, 1)})

      {:ok, records} = Analyzer.prepare(game(pgn))
      # Ply 5 (white): white's own time after ply 3.
      assert Enum.at(records, 4).clock_before_ms == 2000
    end
  end

  describe "the skip rules" do
    test "moves 1-8 of each side are the opening" do
      {:ok, records} = Analyzer.analyse(game(plies(@italian)), polite_engine())
      assert skips(records) == List.duplicate(:opening, 16) ++ [nil, nil, nil, nil]
    end

    test "unrated players' moves do not count, the other side's do" do
      {:ok, records} = Analyzer.analyse(game(plies(@italian), black: nil), polite_engine())
      assert skips(Enum.drop(records, 16)) == [nil, :unrated, nil, :unrated]
    end

    test "a guessed ply and every ply after it" do
      plies = plies(@italian) |> List.update_at(17, &%{&1 | flags: [:guessed]})
      {:ok, records} = Analyzer.analyse(game(plies), polite_engine())

      assert skips(Enum.drop(records, 16)) == [
               nil,
               :tracker_guessed,
               :tracker_guessed,
               :tracker_guessed
             ]

      # A guess in the opening still poisons what follows.
      plies = plies(@italian) |> List.update_at(2, &%{&1 | flags: [:assumed]})
      {:ok, records} = Analyzer.analyse(game(plies), polite_engine())
      assert records |> Enum.drop(2) |> Enum.all?(&(&1.skip == :tracker_guessed))
      assert skips(Enum.take(records, 2)) == [:opening, :opening]
    end

    test "a reconstructed ply counts" do
      plies = plies(@italian) |> List.update_at(17, &%{&1 | flags: [:recovered]})
      {:ok, records} = Analyzer.analyse(game(plies), polite_engine())
      assert skips(Enum.drop(records, 16)) == [nil, nil, nil, nil]
    end

    test "a rewritten ply, until the result is confirmed" do
      plies = plies(@italian) |> List.update_at(18, &%{&1 | flags: [:rewritten]})

      {:ok, records} = Analyzer.analyse(game(plies), polite_engine())
      assert skips(Enum.drop(records, 16)) == [nil, nil, :tracker_rewritten, nil]

      {:ok, records} = Analyzer.analyse(game(plies, confirmed: true), polite_engine())
      assert skips(Enum.drop(records, 16)) == [nil, nil, nil, nil]
    end

    test "a position that stood before" do
      shuffle = @italian ++ ~w(Ng3 Rf8 Nf1 Re8 Ng3)
      {:ok, records} = Analyzer.analyse(game(plies(shuffle)), polite_engine())
      # After Nf1 Re8 the position after 20...Re8 is back; so are the two after it.
      assert skips(Enum.drop(records, 20)) == [nil, nil, nil, :repetition, :repetition]
    end

    test "time trouble, only when the clock is known" do
      plies =
        @italian
        |> Enum.with_index()
        |> Enum.map(fn {san, i} ->
          %{san: san, flags: [], clock_ms: if(i < 16, do: 59_000, else: nil)}
        end)

      {:ok, records} = Analyzer.analyse(game(plies), polite_engine())
      # Plies 17 and 18 had 59 s left after their previous moves; 19 and 20 cannot tell.
      assert skips(Enum.drop(records, 16)) == [:time_trouble, :time_trouble, nil, nil]
    end

    test "one legal move is forced" do
      # Black has Kb8 and nothing else.
      fen = "k7/8/1K6/8/8/8/8/7R b - - 0 40"
      {:ok, [record]} = Analyzer.prepare(game(plies(["Kb8"]), start_fen: fen))
      assert record.legal_count == 1
      assert record.skip == :forced
    end

    test "a decided position, and a best move two pawns better than the rest" do
      engine = fn lines -> fn _, _ -> {:ok, %{best: lines, played_cp: -500}} end end

      decided = [%{move: "a1a1", cp: 301}, %{move: "b1b1", cp: 290}]
      gap = [%{move: "a1a1", cp: 150}, %{move: "b1b1", cp: -50}]
      close = [%{move: "a1a1", cp: 150}, %{move: "b1b1", cp: -49}]
      mated = [%{move: "a1a1", cp: -9_998}]

      for {lines, expected} <- [
            {decided, :decided},
            {gap, :forced},
            {close, nil},
            {mated, :decided}
          ] do
        {:ok, records} = Analyzer.analyse(game(plies(@italian)), engine.(lines))
        assert List.last(records).skip == expected, inspect(lines)
      end
    end

    test "counts per reason" do
      plies = plies(@italian) |> List.update_at(19, &%{&1 | flags: [:guessed]})
      {:ok, records} = Analyzer.analyse(game(plies, black: 0), polite_engine())

      assert Selection.counts(records) == %{
               counted: 2,
               skipped: %{opening: 8, unrated: 10}
             }
    end
  end
end
