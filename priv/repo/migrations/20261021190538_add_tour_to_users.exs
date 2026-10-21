defmodule Alnasl.Repo.Migrations.AddTourToUsers do
  use Ecto.Migration

  # The guided tour (`AlnaslWeb.Tour`): `nil` until it was offered and
  # answered, then "started", "dismissed" or "finished". Only `nil` gets the
  # offer, so nobody is asked twice. A box without accounts keeps the same
  # word in its settings instead.
  def change do
    alter table(:users) do
      add :tour, :string
    end
  end
end
