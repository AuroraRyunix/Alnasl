defmodule Alnasl.Repo.Migrations.MoreThanOneGameABoard do
  use Ecto.Migration

  # A board of a round can see more than one game: friends playing blitz
  # game after game, a game started over. `game_no` counts them, from 1;
  # the highest is the one being played.
  def change do
    alter table(:games) do
      add :game_no, :integer, null: false, default: 1
    end

    drop unique_index(:games, [:round, :board_no])
    create unique_index(:games, [:round, :board_no, :game_no])
  end
end
