defmodule Alnasl.Repo.Migrations.AccountsAndHalls do
  use Ecto.Migration

  # Accounts, halls and who may do what where (`Alnasl.Accounts`,
  # `Alnasl.Halls`). A box upgraded to this has no accounts and therefore
  # behaves as it did: open to the hall's network, behind the PIN if one is
  # set. Its one hall is made here - "this box's own boards" - and every
  # board, tournament, code and bridge it already has goes into it.
  def change do
    create table(:users) do
      add :email, :string, null: false
      # Nothing for an account that only ever signs in with 02cloud.
      add :hashed_password, :string
      add :keycloak_sub, :string
      # Everything on the box, every hall. The first account of a box is
      # one; on a server the addresses in ALNASL_ADMIN_EMAILS are as well,
      # without a row saying so.
      add :admin, :boolean, null: false, default: false
      # Set by an admin's temporary password: the next sign-in asks for a
      # new one.
      add :must_change_password, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:keycloak_sub])

    # Sessions (kept, so that one can be ended) and the one-time sign-in
    # links of the QR code on Setup. Only a hash of a link's token is kept.
    create table(:users_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :used_at, :utc_datetime
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])

    create table(:halls) do
      add :name, :string, null: false
      # The hall of the box's own serial ports. Exactly one.
      add :own, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create table(:hall_members) do
      add :hall_id, references(:halls, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:hall_members, [:hall_id, :user_id])
    create index(:hall_members, [:user_id])

    # An invitation: an address, a hall and a role, and the hash of the
    # token in the link. Good once.
    create table(:invitations) do
      add :email, :string, null: false
      add :hall_id, references(:halls, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :token, :binary, null: false
      add :invited_by_id, references(:users, on_delete: :nilify_all)
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:invitations, [:token])

    alter table(:boards) do
      add :hall_id, :integer
    end

    alter table(:tournaments) do
      add :hall_id, :integer
    end

    alter table(:links) do
      add :hall_id, :integer
    end

    alter table(:bridge_joins) do
      add :hall_id, :integer
    end

    create index(:boards, [:hall_id])
    create index(:tournaments, [:hall_id])

    # The box's own hall, and everything there is into it. A box with a
    # name gives the hall that name; the site can rename it.
    execute(
      """
      INSERT INTO halls (name, own, inserted_at, updated_at)
      VALUES (
        COALESCE((SELECT json_extract(value, '$') FROM settings WHERE key = 'box_name'), 'Alnasl'),
        1, datetime('now'), datetime('now'))
      """,
      "DELETE FROM halls"
    )

    for table <- ~w(boards tournaments links bridges bridge_joins) do
      execute(
        "UPDATE #{table} SET hall_id = (SELECT id FROM halls WHERE own = 1) WHERE hall_id IS NULL",
        "SELECT 1"
      )
    end
  end
end
