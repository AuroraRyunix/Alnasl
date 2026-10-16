defmodule Alnasl.Repo.Migrations.CreateBridges do
  use Ecto.Migration

  # The bridges that bring boards here from elsewhere (`Alnasl.Bridges`),
  # and the join codes that let them in.
  def change do
    create table(:bridges) do
      # The bridge's own name for itself, made once on the bridge and kept:
      # a bridge that joins again is the same bridge.
      add :uid, :string, null: false
      add :name, :string, null: false
      add :software, :string
      # Only the hash: the key itself is the bridge's to keep.
      add :key_hash, :string, null: false
      # The highest event number taken; anything at or below it that comes
      # again is a resend, and is acknowledged without being applied twice.
      add :seen_seq, :integer, null: false, default: 0
      add :last_connected_at, :utc_datetime
      # Removed here: kept so that a bridge that dials in afterwards is told
      # to forget this server, rather than merely refused.
      add :revoked_at, :utc_datetime
      # Which hall it is in, once there are halls. Nothing yet.
      add :hall_id, :integer
      timestamps(type: :utc_datetime)
    end

    create unique_index(:bridges, [:uid])

    create table(:bridge_joins) do
      add :code, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :bridge_id, references(:bridges, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:bridge_joins, [:code])
  end
end
