defmodule Alnasl.Repo.Migrations.CreateAlnaslTables do
  use Ecto.Migration

  def change do
    # What the arbiter set up: server, tournament, key, language. One row a
    # setting; the value is JSON.
    create table(:settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :text
    end

    # A physical board (or a simulator slot standing in for one) and the
    # game of the round it is linked to.
    create table(:boards) do
      add :name, :string, null: false
      add :driver, :string, null: false
      add :port, :string
      add :address, :integer
      add :options, :text
      add :flipped, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true
      add :round, :integer
      add :board_no, :integer
      add :serial, :string
      add :firmware, :string
      timestamps(type: :utc_datetime)
    end

    # One game of one round. `plies` is the whole move list as JSON, each
    # with its flags, its time and the clock when it was made.
    create table(:games) do
      add :round, :integer, null: false
      add :board_no, :integer, null: false
      add :white, :string
      add :black, :string
      add :start_fen, :string
      add :plies, :text, null: false, default: "[]"
      add :status, :string, null: false, default: "live"
      add :result, :string
      add :suggestion, :string
      add :paused, :boolean, null: false, default: false
      add :source, :string, null: false, default: "board"
      add :clock, :text
      add :seq, :integer, null: false, default: 0
      add :finished_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:games, [:round, :board_no])

    # What must reach the results server, in the order it happened. Written
    # before anything is sent; a row leaves `pending` only when the server
    # has answered for it.
    create table(:outbox) do
      add :game_id, references(:games, on_delete: :delete_all), null: false
      add :round, :integer, null: false
      add :board_no, :integer, null: false
      add :seq, :integer, null: false
      add :plies, :integer, null: false, default: 0
      add :replace, :boolean, null: false, default: false
      add :body, :text, null: false
      add :state, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :error, :string
      add :detail, :text
      add :sent_at, :utc_datetime
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:outbox, [:state, :id])
    create index(:outbox, [:game_id])

    # The log the arbiter reads: what happened, to which board, when.
    create table(:events) do
      add :at, :utc_datetime_usec, null: false
      add :level, :string, null: false
      add :kind, :string, null: false
      add :board_id, :integer
      add :round, :integer
      add :board_no, :integer
      add :data, :text
    end

    create index(:events, [:at])
  end
end
