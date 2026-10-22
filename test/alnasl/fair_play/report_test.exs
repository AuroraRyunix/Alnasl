defmodule Alnasl.FairPlay.ReportTest do
  use ExUnit.Case, async: true

  alias Alnasl.FairPlay.{Move, Report, UploadMove}

  defp row(kind, game_id, colour, rating),
    do: struct(kind, game_id: game_id, colour: colour, rating: rating)

  test "the opponent's rating comes from the other colour's rows of the same game" do
    rows = [
      row(Move, 1, "white", 1800),
      row(Move, 1, "black", 2100),
      row(Move, 2, "white", 1500),
      row(Move, 2, "black", nil),
      # An uploaded game with the same id is another game.
      row(UploadMove, 1, "white", 2400)
    ]

    opponents = Report.opponent_ratings(rows)

    assert opponents[{Move, 1, "black"}] == 2100
    assert opponents[{Move, 1, "white"}] == 1800
    assert opponents[{UploadMove, 1, "white"}] == 2400
    refute Map.has_key?(opponents, {Move, 2, "black"})
  end
end
