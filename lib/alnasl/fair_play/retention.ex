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
  """

  use GenServer

  import Ecto.Query

  alias Alnasl.Repo
  alias Alnasl.FairPlay.{Keep, Move, View}
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
  `%{tournaments: n, moves: n, views: n}`: how many tournaments were
  cleared and how many rows went.
  """
  @spec purge(DateTime.t(), pos_integer()) :: %{
          tournaments: integer(),
          moves: integer(),
          views: integer()
        }
  def purge(now \\ DateTime.utc_now(), days \\ Alnasl.FairPlay.retention_days()) do
    # Analysis of games that are gone.
    {orphans, _} =
      Repo.delete_all(
        from m in Move, where: m.game_id not in subquery(from g in Game, select: g.id)
      )

    ids =
      [Move, View, Keep]
      |> Enum.flat_map(&Repo.all(from r in &1, distinct: true, select: r.tournament_id))
      |> Enum.uniq()

    Enum.reduce(ids, %{tournaments: 0, moves: orphans, views: 0}, fn id, acc ->
      if expired?(id, now, days) do
        {moves, _} = Repo.delete_all(from m in Move, where: m.tournament_id == ^id)
        {views, _} = Repo.delete_all(from v in View, where: v.tournament_id == ^id)
        Repo.delete_all(from k in Keep, where: k.tournament_id == ^id)

        %{
          acc
          | tournaments: acc.tournaments + 1,
            moves: acc.moves + moves,
            views: acc.views + views
        }
      else
        acc
      end
    end)
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

  # --- the daily job -----------------------------------------------------------

  @impl true
  def init(opts) do
    if Keyword.get(opts, :timer, true), do: Process.send_after(self(), :purge, @first_ms)
    {:ok, %{timer: Keyword.get(opts, :timer, true)}}
  end

  @impl true
  def handle_info(:purge, state) do
    summary = purge()

    if summary.moves + summary.views > 0 do
      Logger.info(
        "fair play: retention ended for #{summary.tournaments} tournaments " <>
          "(#{summary.moves} analysed moves, #{summary.views} audit rows)"
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
