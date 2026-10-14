defmodule Alnasl.Tournaments.Tournament do
  @moduledoc """
  One tournament the box serves.

  `kind` is `"local"` - the box's own, which is always there: pairings by
  hand or from a PGN, a results page typed in on Setup - or `"linked"`: a
  tournament of a pairing program, reached through a connect code
  (`link_id`, `remote_id`), whose pairings, rate of play and results page
  arrive by themselves.

  `document` is what the box knows of the pairings, as JSON in the shape of
  the board link's tournament document (`docs/board-link-api.md` in
  OpenPairings): `tournament`, `players`, `rounds`. It is kept so the box
  knows who sits where with the network gone.

  `round` is the round the box has on this tournament's boards;
  `remote_round` the one the pairing program last said was on. They differ
  when the arbiter chose to look elsewhere.

  `relay_key` and `lichess_token` are secrets: stored as given because they
  are sent, never logged, shown as a hint only.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "tournaments" do
    field :kind, :string, default: "local"
    field :link_id, :integer
    field :remote_id, :integer
    field :name, :string
    field :label, :string
    field :state, :string
    field :version, :string
    field :listed_version, :string
    field :document, :string
    field :document_at, :utc_datetime
    field :gone, :boolean, default: false
    field :round, :integer, default: 1
    field :remote_round, :integer
    field :auto_start, :boolean, default: true
    field :table_from, :integer
    field :table_to, :integer
    field :keep_matches, :boolean, default: true
    field :server_url, :string, default: ""
    field :slug, :string, default: ""
    field :relay_key, :string, default: "", redact: true
    field :lichess_round_id, :string
    field :lichess_token, :string, redact: true
    field :lichess_round, :integer
    timestamps(type: :utc_datetime)
  end

  def changeset(tournament, attrs) do
    # An empty string is a value here: "no relay key" is "", not nothing.
    tournament
    |> cast(attrs, fields(), empty_values: [])
    |> validate_number(:round, greater_than: 0, less_than: 1000)
    |> validate_number(:table_from, greater_than: 0, less_than: 10_000)
    |> validate_number(:table_to, greater_than: 0, less_than: 10_000)
  end

  defp fields do
    [
      :name,
      :label,
      :state,
      :version,
      :listed_version,
      :document,
      :document_at,
      :gone,
      :round,
      :remote_round,
      :auto_start,
      :table_from,
      :table_to,
      :keep_matches,
      :server_url,
      :slug,
      :relay_key,
      :lichess_round_id,
      :lichess_token,
      :lichess_round
    ]
  end
end
