defmodule Alnasl.Repo.Migrations.TeamsAndOneRowATournament do
  use Ecto.Migration

  # `keep_matches`: in a team event, the tables of a tournament are counted
  # in matches and then boards, so a match sits side by side. On unless the
  # arbiter says otherwise; nothing but a team event reads it.
  #
  # `elsewhere`: the tournaments a connect code reaches that the box already
  # has through another code, as JSON (`Alnasl.OpenPairings.Duplicates`).
  # One tournament is one row, however many codes reach it.
  def change do
    alter table(:tournaments) do
      add :keep_matches, :boolean, null: false, default: true
    end

    alter table(:links) do
      add :elsewhere, :text
    end
  end
end
