defmodule Alnasl.FairPlay.View do
  @moduledoc """
  One line of fair play's audit (`fair_play_views`): who did what to which
  report, and when. The name is from when it only recorded openings.

  `action` is one of:

    * `"view"` - a report or a player's page was opened (by its owner or
      by somebody it was shared with);
    * `"grant"`, `"revoke"` - the owner shared a report, or the hall's fair
      play, with an account, or stopped (`detail`: the account and the
      expiry);
    * `"upload"`, `"delete_upload"` - a PGN was uploaded or deleted
      (`detail`: the file's name);
    * `"analyse_round"` - the owner had a round analysed again (`round`);
    * `"delete_analysis"` - the owner deleted a tournament's analysis; a
      frozen copy of the report is kept (`Alnasl.FairPlay.Snapshot`).

  The subject is a tournament (`tournament_id`), an upload (`upload_id`),
  or neither: the hall's fair play as a whole (`hall_id`). `user_id` and
  `user_email` are `nil` on a box with no accounts.
  """
  use Ecto.Schema

  @actions ~w(view grant revoke upload delete_upload analyse_round delete_analysis)

  @doc "The actions an audit line can record."
  def actions, do: @actions

  schema "fair_play_views" do
    field :hall_id, :integer
    field :tournament_id, :integer
    field :upload_id, :integer
    field :user_id, :integer
    field :user_email, :string
    field :action, :string, default: "view"
    field :round, :integer
    field :player_key, :string
    field :detail, :string
    field :at, :utc_datetime
  end
end
