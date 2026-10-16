defmodule Alnasl.Repo.Migrations.AddLocaleToUsers do
  use Ecto.Migration

  # The language is a person's, not the box's: an account keeps the one it
  # chose. Empty means "whatever the box speaks by default" (Setup).
  def change do
    alter table(:users) do
      add :locale, :string
    end
  end
end
