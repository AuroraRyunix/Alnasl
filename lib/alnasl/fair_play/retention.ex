defmodule Alnasl.FairPlay.Retention do
  @moduledoc """
  How long fair-play data lives, and the job that ends it.

  The analysis rows (`fair_play_moves`) and the audit rows
  (`fair_play_views`) of a tournament are deleted once its **last round
  ended** more than `Alnasl.FairPlay.retention_days/0` days ago (thirty
  unless `ALNASL_FAIR_PLAY_RETENTION_DAYS` says otherwise) - unless the
  owner extended it (`Alnasl.FairPlay.extend/4`): a `fair_play_keeps` row
  whose `keep_until` is still in the future stops the deletion, and is itself
  deleted with the data once that date has passed. An extension reaches at
  most 365 days beyond the last round, and needs a reason.

  ## When did the last round end?

  Alnasl keeps no "round ended" mark, so it is the latest moment any game
  of the tournament was last settled: for each game its `finished_at`, or -
  for a game that never was finished - the last time it changed
  (`updated_at`). A game still being played therefore keeps the tournament
  young, and one abandoned months ago does not keep it alive for ever.
  A tournament with no games at all (they were deleted) has no last round,
  and its fair-play rows are deleted at once: there is nothing left they
  could be about. So are analysis rows whose game is gone.

  Reports are computed from the rows, so deleting the rows deletes the
  reports. The job runs once a day (the first time a minute after start);
  `purge/2` does the work and takes the time as an argument.

  The frozen copy a deleted analysis leaves (`Alnasl.FairPlay.Snapshot`)
  goes at the same moment the report would have: deleting it early would
  defeat it.

  ## Uploads, grants and the hall's audit

    * An uploaded PGN attached to a tournament (`Alnasl.FairPlay.Upload`)
      goes with the tournament: its games, their analysis, its audit and
      the grants of its report.
    * One on its own counts from the moment it was uploaded, as if that
      were its last round, and can be kept longer in the same way (up to
      365 days, with a reason).
    * The grants of a report go with the report. Grants of a whole hall,
      and the audit lines about the hall rather than a report (a grant of
      the hall, an upload deleted), are about the owner's choices, not
      about players: they stay `Alnasl.FairPlay.max_keep_days/0` days
      after the grant ended or the line was written, and then they go too.
  """

  use GenServer

  import Ecto.Query

  alias Alnasl.Repo
  alias Alnasl.FairPlay.{Grant, Keep, Move, Snapshot, Upload, UploadMove, Uploads, View}
  alias Alnasl.Games.Game

  require Logger

  @day_ms 86_400_000
  @first_ms 60_000

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The moment the tournament's last round ended (see the moduledoc), or `nil` when it has no games."
  @spec last_round_end(integer()) :: DateTime.t() | nil
  def last_round_end(tournament_id) do
    Repo.all(
      from g in Game,
        where: g.tournament_id == ^tournament_id,
        select: {g.finished_at, g.updated_at}
    )
    |> Enum.map(fn {finished, updated} -> finished || updated end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      times -> Enum.max(times, DateTime)
    end
  end

  @doc """
  Deletes what has outlived its time, as of `now`. Returns
  `%{tournaments: n, uploads: n, moves: n, views: n}`: how many
  tournaments and uploads were cleared and how many rows went.
  """
  @spec purge(DateTime.t(), pos_integer()) :: %{
          tournaments: integer(),
          uploads: integer(),
          moves: integer(),
          views: integer()
        }
  def purge(now \\ DateTime.utc_now(), days \\ Alnasl.FairPlay.retention_days()) do
    # Analysis of games that are gone.
    {orphans, _} =
      Repo.delete_all(
        from m in Move, where: m.game_id not in subquery(from g in Game, select: g.id)
      )

    {upload_orphans, _} =
      Repo.delete_all(
        from m in UploadMove, where: m.upload_id not in subquery(from u in Upload, select: u.id)
      )

    start = %{tournaments: 0, uploads: 0, moves: orphans + upload_orphans, views: 0}

    acc =
      Enum.reduce(tournament_ids(), start, fn id, acc ->
        if expired?(id, now, days), do: add(acc, purge_tournament(id)), else: acc
      end)

    acc =
      from(u in Upload, where: is_nil(u.tournament_id))
      |> Repo.all()
      |> Enum.reduce(acc, fn upload, acc ->
        if upload_expired?(upload, now, days) do
          gone = Uploads.purge(upload.id)

          %{
            acc
            | uploads: acc.uploads + 1,
              moves: acc.moves + gone.moves,
              views: acc.views + gone.views
          }
        else
          acc
        end
      end)

    hall_level(acc, now)
  end

  defp add(acc, gone) do
    %{
      acc
      | tournaments: acc.tournaments + 1,
        uploads: acc.uploads + gone.uploads,
        moves: acc.moves + gone.moves,
        views: acc.views + gone.views
    }
  end

  defp tournament_ids do
    [Move, View, Keep, Grant, UploadMove, Upload, Snapshot]
    |> Enum.flat_map(
      &Repo.all(
        from r in &1, where: not is_nil(r.tournament_id), distinct: true, select: r.tournament_id
      )
    )
    |> Enum.uniq()
  end

  defp purge_tournament(id) do
    {moves, _} = Repo.delete_all(from m in Move, where: m.tournament_id == ^id)
    {views, _} = Repo.delete_all(from v in View, where: v.tournament_id == ^id)
    Repo.delete_all(from k in Keep, where: k.tournament_id == ^id)
    Repo.delete_all(from s in Snapshot, where: s.tournament_id == ^id)
    Repo.delete_all(from g in Grant, where: g.tournament_id == ^id)

    uploads = Repo.all(from u in Upload, where: u.tournament_id == ^id, select: u.id)
    gone = Enum.map(uploads, &Uploads.purge/1)

    # Rows of an upload that was attached and is no more.
    {stray, _} = Repo.delete_all(from m in UploadMove, where: m.tournament_id == ^id)

    %{
      uploads: length(uploads),
      moves: moves + stray + Enum.sum(Enum.map(gone, & &1.moves)),
      views: views + Enum.sum(Enum.map(gone, & &1.views))
    }
  end

  defp expired?(tournament_id, now, days) do
    keep = Repo.get_by(Keep, tournament_id: tournament_id)

    cond do
      keep && DateTime.compare(keep.keep_until, now) == :gt ->
        false

      true ->
        case last_round_end(tournament_id) do
          nil -> true
          ended -> DateTime.diff(now, ended, :second) > days * 86_400
        end
    end
  end

  defp upload_expired?(%Upload{} = upload, now, days) do
    cond do
      upload.keep_until && DateTime.compare(upload.keep_until, now) == :gt -> false
      true -> DateTime.diff(now, upload.inserted_at, :second) > days * 86_400
    end
  end

  # The hall's own audit lines and its ended grants of the whole hall, a
  # year after.
  defp hall_level(acc, now) do
    cutoff = DateTime.add(now, -Alnasl.FairPlay.max_keep_days() * 86_400, :second)

    {views, _} =
      Repo.delete_all(
        from v in View,
          where: is_nil(v.tournament_id) and is_nil(v.upload_id) and v.at < ^cutoff
      )

    Repo.delete_all(
      from g in Grant,
        where: is_nil(g.tournament_id) and is_nil(g.upload_id),
        where: g.expires_at < ^cutoff or g.revoked_at < ^cutoff
    )

    %{acc | views: acc.views + views}
  end

  # --- the daily job -----------------------------------------------------------

  @impl true
  def init(opts) do
    if Keyword.get(opts, :timer, true), do: Process.send_after(self(), :purge, @first_ms)
    {:ok, %{timer: Keyword.get(opts, :timer, true)}}
  end

  @impl true
  def handle_info(:purge, state) do
    summary = purge()

    if summary.moves + summary.views + summary.uploads > 0 do
      Logger.info(
        "fair play: retention ended for #{summary.tournaments} tournaments and " <>
          "#{summary.uploads} uploads (#{summary.moves} analysed moves, #{summary.views} audit rows)"
      )
    end

    if state.timer, do: Process.send_after(self(), :purge, @day_ms)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("fair play: retention failed: #{Exception.message(error)}")
      if state.timer, do: Process.send_after(self(), :purge, @day_ms)
      {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
