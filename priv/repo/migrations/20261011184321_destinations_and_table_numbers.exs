defmodule Alnasl.Repo.Migrations.DestinationsAndTableNumbers do
  use Ecto.Migration

  def change do
    # How far each destination other than the results server has got with
    # each game: the game's own counter (`games.seq`) at the last push that
    # destination answered for. A game whose counter is ahead of this is
    # waiting for that destination, and for that destination only.
    create table(:destination_cursors) do
      add :destination, :string, null: false
      add :game_id, references(:games, on_delete: :delete_all), null: false
      add :acked_seq, :integer, null: false, default: 0
      add :error, :text
      # What was last sent, as a hash: a change that leaves the PGN as it was
      # (a clock refresh between moves) is not sent again.
      add :digest, :string
      add :sent_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:destination_cursors, [:destination, :game_id])

    # The number on the sticker: which table this physical board stands on.
    # Set once for a hall; `board_no` stays what it was, the round's board.
    alter table(:boards) do
      add :table_no, :integer
    end

    create index(:boards, [:serial])
  end
end
