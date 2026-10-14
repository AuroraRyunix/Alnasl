defmodule Alnasl.Tournaments.Link do
  @moduledoc """
  A connect code of a pairing program, as the box keeps it: the address the
  code named (`root`) and the secret to send there. One code reaches one
  tournament or a group of them; the tournaments it reaches are rows of
  their own (`Alnasl.Tournaments.Tournament`).

  The secret is stored as given, because the box has to send it with every
  request and the pairing program keeps only a hash. It is never logged and
  never shown again: `Alnasl.Tournaments.secret_hint/1` is all the site
  gives of it.

  `state` is how the last conversation went: `new` (never asked), `ok`,
  `unauthorized` (the code is wrong or was withdrawn), `unsupported` (the
  program speaks a version of the link this box does not know) or
  `unreachable`.

  `elsewhere` is what the code reaches that the box already has through
  another code: JSON, `{"<id there>": {"tournament_id", "name"}}`. Those
  tournaments are not made a second time (`Alnasl.OpenPairings.Duplicates`).
  """
  use Ecto.Schema

  schema "links" do
    field :elsewhere, :string
    field :root, :string
    field :secret, :string, redact: true
    field :kind, :string
    field :group_name, :string
    field :etag, :string
    field :poll_seconds, :integer, default: 5
    field :server_name, :string
    field :server_version, :string
    field :state, :string, default: "new"
    field :error, :string
    field :last_ok_at, :utc_datetime
    field :last_try_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
