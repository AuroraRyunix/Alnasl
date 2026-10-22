defmodule Alnasl.FairPlay do
  @moduledoc """
  Fair-play screening, as the rest of Alnasl meets it (`docs/plan-fair-play.md`).
  The statistics, the engine and the move selection are in
  `Alnasl.FairPlay.*` (the core); this module is the door: a hall's
  settings, installing its engine, being told that a game changed, the
  audit of who opened a report, and the owner's extension of retention.

  **Every function that reads or changes something of a hall's fair play
  takes a scope first and asks `Alnasl.FairPlay.Access.owner?/2`**, and
  answers `{:error, :forbidden}` to anybody else. Reading a report (its
  rows, its rounds, writing down that it was opened) asks `can_view?/2`
  instead: the owner, or an account the owner shared it with
  (`Alnasl.FairPlay.Grants`). The one exception is `game_changed/1`, which
  is the tracker's side of the door: it carries a game id, reads nothing
  back, and never blocks.

  Phase 2 is in `Alnasl.FairPlay.Uploads` (PGN files), `analyse_round/3`
  (a round on demand) and `Alnasl.FairPlay.Grants` (sharing).

  ## Where the numbers come from

  `engine_count/0` is how many engines the live queue may run at once:
  `ALNASL_FAIR_PLAY_ENGINES`, else one on the hosted server, else the
  machine's schedulers less one (at least one). `retention_days/0` is
  `ALNASL_FAIR_PLAY_RETENTION_DAYS`, thirty unless told otherwise.
  """

  import Ecto.Query

  alias Alnasl.{Games, Halls, Repo, Tournaments}

  alias Alnasl.FairPlay.{
    Access,
    Engines,
    Grants,
    Installer,
    Keep,
    Move,
    Pool,
    Queue,
    Report,
    Retention,
    Setting,
    Snapshot,
    Upload,
    UploadMove,
    View
  }

  alias Alnasl.Tournaments.Tournament

  @default_retention_days 30
  @max_keep_days 365

  # --- configuration -----------------------------------------------------------

  @doc "How many engines may run at once."
  def engine_count do
    case Application.get_env(:alnasl, :fair_play_engines) do
      n when is_integer(n) and n > 0 -> n
      _unset -> if(Alnasl.Accounts.server?(), do: 1, else: max(System.schedulers_online() - 1, 1))
    end
  end

  @doc "Days after a tournament's last round that its analysis is kept."
  def retention_days do
    case Application.get_env(:alnasl, :fair_play_retention_days) do
      n when is_integer(n) and n > 0 -> n
      _unset -> @default_retention_days
    end
  end

  @doc "The longest an owner may extend retention: days after the last round."
  def max_keep_days, do: @max_keep_days

  # --- settings ----------------------------------------------------------------

  @doc """
  The hall's settings; a hall with none has the defaults (off, no engine).
  Not scoped: it is what the queue and the pages ask after having asked
  `Access`; nothing here leaves the module's callers unchecked.
  """
  @spec settings(integer()) :: struct()
  def settings(hall_id) do
    Repo.get_by(Setting, hall_id: hall_id) || %Setting{hall_id: hall_id}
  end

  @doc "The settings of the hall a tournament belongs to."
  def settings_for_tournament(%Tournament{} = tournament),
    do: tournament |> Halls.of() |> settings()

  @doc "Switches fair play on or off in a hall. Owner only."
  @spec set_enabled(struct() | nil, integer(), boolean()) ::
          {:ok, struct()} | {:error, :forbidden}
  def set_enabled(scope, hall_id, enabled?) when is_boolean(enabled?) do
    if Access.owner?(scope, hall_id) do
      hall_id |> settings() |> save(%{enabled: enabled?})
    else
      {:error, :forbidden}
    end
  end

  defp save(%Setting{} = setting, attrs) do
    setting
    |> Setting.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Is fair play on in the hall, with an engine installed to do it?"
  def working?(%Setting{enabled: true} = setting), do: Setting.installed?(setting)
  def working?(_setting), do: false

  # --- the engine --------------------------------------------------------------

  @doc """
  Installs the pinned engine for a hall: `:download` or `{:file, path}`
  (`Alnasl.FairPlay.Installer`, whose `opts` are passed through). An engine
  another hall on this machine already installed, and which is still there
  with the right bench, is taken as it is: it is one binary per machine.
  Owner only.
  """
  @spec install(struct() | nil, integer(), :download | {:file, String.t()}, keyword()) ::
          {:ok, struct()} | {:error, :forbidden | Installer.reason()}
  def install(scope, hall_id, source, opts \\ []) do
    cond do
      not Access.owner?(scope, hall_id) ->
        {:error, :forbidden}

      other = existing_engine(opts) ->
        adopt(hall_id, other)

      true ->
        with {:ok, installed} <- Installer.install(source, opts) do
          Pool.stop_all()

          hall_id
          |> settings()
          |> save(%{
            engine_id: installed.engine,
            engine_path: installed.path,
            engine_version: installed.version,
            engine_bench: installed.bench
          })
        end
    end
  end

  defp existing_engine(opts) do
    engine = Keyword.get(opts, :engine, Engines.default())

    Repo.all(
      from s in Setting, where: s.engine_id == ^engine.id and s.engine_bench == ^engine.bench
    )
    |> Enum.find(&Setting.installed?/1)
  end

  defp adopt(hall_id, other) do
    hall_id
    |> settings()
    |> save(%{
      engine_id: other.engine_id,
      engine_path: other.engine_path,
      engine_version: other.engine_version,
      engine_bench: other.engine_bench
    })
  end

  @doc """
  Why this machine cannot run the engine at all, or `nil`: `{:macos, version}`.
  Today that is a Mac older than macOS 10.15. `config :alnasl,
  :fair_play_macos_version` (a function) stands in for the system in tests.
  """
  def platform_problem do
    version =
      case Application.get_env(:alnasl, :fair_play_macos_version) do
        fun when is_function(fun, 0) -> fun.()
        _system -> Engines.macos_version()
      end

    if Engines.macos_problem(version), do: {:macos, version}
  end

  @doc "The options `install/4` passes to the installer: the application's own, for tests."
  def install_options, do: Application.get_env(:alnasl, :fair_play_install_opts, [])

  # --- the tracker's side ------------------------------------------------------

  @doc """
  A game changed (a move became final, it finished, its result was set):
  tell the live queue. Fire and forget: when the queue is not running
  (fair play unused, or a test) this does nothing, and it never waits for
  anything. Whether the hall has fair play on is the queue's question, not
  the tracker's.
  """
  @spec game_changed(term()) :: :ok
  def game_changed(%{id: id}) when is_integer(id), do: Queue.enqueue(id)
  def game_changed(_other), do: :ok

  # --- the reports -------------------------------------------------------------
  #
  # A report is about a subject: a tournament (`%Tournament{}`) or an
  # uploaded PGN (`%Upload{}`). Seeing one is for the hall's owner and for
  # whoever the owner shared it with (`Alnasl.FairPlay.Grants`); changing
  # anything about it - and seeing who else looked - is for the owner alone.

  @doc "The hall a report belongs to."
  def hall_of(%Tournament{} = tournament), do: Halls.of(tournament)
  def hall_of(%Upload{hall_id: hall_id}), do: hall_id

  @doc """
  May the scope see this report: its hall's owner, or an account holding a
  grant for it that is in force?
  """
  def can_view?(scope, subject),
    do: Access.owner?(scope, hall_of(subject)) or Grants.active?(scope, subject)

  @doc "Is the scope the owner of the report's hall?"
  def owner_of?(scope, subject), do: Access.owner?(scope, hall_of(subject))

  defp viewing(scope, subject, fun),
    do: if(can_view?(scope, subject), do: fun.(), else: {:error, :forbidden})

  defp owning(scope, subject, fun),
    do: if(owner_of?(scope, subject), do: fun.(), else: {:error, :forbidden})

  @doc "The tournaments of a hall, newest first. Owner only."
  @spec tournaments(struct() | nil, integer()) :: {:ok, [struct()]} | {:error, :forbidden}
  def tournaments(scope, hall_id) do
    if Access.owner?(scope, hall_id),
      do: {:ok, hall_tournaments(hall_id)},
      else: {:error, :forbidden}
  end

  @doc """
  The tournaments of a hall whose fair play was shared whole with the
  scope (a grant of the hall, in force). The list a grantee is shown;
  not the way into the settings, which stay the owner's.
  """
  @spec shared_tournaments(struct() | nil, integer()) :: {:ok, [struct()]} | {:error, :forbidden}
  def shared_tournaments(scope, hall_id) do
    if Grants.hall_active?(scope, hall_id),
      do: {:ok, hall_tournaments(hall_id)},
      else: {:error, :forbidden}
  end

  defp hall_tournaments(hall_id) do
    own = Halls.own_id()

    Repo.all(
      from t in Tournament,
        where: t.hall_id == ^hall_id or (is_nil(t.hall_id) and ^(hall_id == own)),
        order_by: [desc: t.id]
    )
  end

  @doc """
  A tournament, when the scope may see its fair play (it owns the
  tournament's hall, or the report was shared with it): `{:ok, tournament}`,
  else `{:error, :forbidden}`. A tournament that does not exist is
  forbidden too, so the answer does not tell which ids are used.
  """
  def tournament(scope, id) do
    with %Tournament{} = tournament <- Tournaments.get(id),
         true <- can_view?(scope, tournament) do
      {:ok, tournament}
    else
      _no -> {:error, :forbidden}
    end
  end

  @doc """
  Writes down that the scope opened a report (or a player's page). Anybody
  who may see it; refused, and nothing written, for anybody else.
  """
  @spec record_view(struct() | nil, struct(), integer() | nil, String.t() | nil) ::
          {:ok, struct()} | {:error, :forbidden}
  def record_view(scope, subject, round, player_key) do
    viewing(scope, subject, fn ->
      {:ok, audit(scope, ids(subject), "view", round: round, player_key: player_key)}
    end)
  end

  @doc """
  Writes one line of the audit: `ids` are the subject's (`hall_id`,
  `tournament_id`, `upload_id`), `action` one of `Alnasl.FairPlay.View.actions/0`.
  Asks nobody: the callers have.
  """
  def audit(scope, ids, action, opts \\ []) when is_binary(action) do
    user = scope && scope.user

    Repo.insert!(%View{
      hall_id: ids[:hall_id],
      tournament_id: ids[:tournament_id],
      upload_id: ids[:upload_id],
      user_id: user && user.id,
      user_email: user && user.email,
      action: action,
      round: opts[:round],
      player_key: opts[:player_key],
      detail: opts[:detail] && String.slice(opts[:detail], 0, 250),
      at: DateTime.utc_now(:second)
    })
  end

  defp ids(%Tournament{id: id} = t), do: %{hall_id: Halls.of(t), tournament_id: id}
  defp ids(%Upload{id: id, hall_id: hall_id}), do: %{hall_id: hall_id, upload_id: id}

  @doc """
  The latest lines of a report's audit, newest first: openings, grants,
  revocations, uploads, rounds analysed. Owner only - who looked is not the
  grantees' business.
  """
  def views(scope, subject, limit \\ 20) do
    owning(scope, subject, fn ->
      query =
        case subject do
          %Tournament{id: id} -> from v in View, where: v.tournament_id == ^id
          %Upload{id: id} -> from v in View, where: v.upload_id == ^id
        end

      {:ok, Repo.all(from v in query, order_by: [desc: v.at, desc: v.id], limit: ^limit)}
    end)
  end

  @doc "The latest lines of the hall's own audit (grants of the whole hall, uploads deleted). Owner only."
  def hall_audit(scope, hall_id, limit \\ 20) do
    if Access.owner?(scope, hall_id) do
      {:ok,
       Repo.all(
         from v in View,
           where: v.hall_id == ^hall_id and is_nil(v.tournament_id) and is_nil(v.upload_id),
           order_by: [desc: v.at, desc: v.id],
           limit: ^limit
       )}
    else
      {:error, :forbidden}
    end
  end

  @doc """
  The rows of a report's analysis, `filter` limiting them to rounds
  (`through: r` or `only: r`). A tournament's report counts the games of
  uploads attached to it too. Anybody who may see the report.
  """
  def moves(scope, subject, filter \\ []) do
    viewing(scope, subject, fn ->
      queries =
        case subject do
          %Tournament{id: id} ->
            [
              from(m in Move, where: m.tournament_id == ^id, order_by: [m.game_id, m.ply]),
              from(m in UploadMove, where: m.tournament_id == ^id, order_by: [m.game_id, m.ply])
            ]

          %Upload{id: id} ->
            [from(m in UploadMove, where: m.upload_id == ^id, order_by: [m.game_id, m.ply])]
        end

      {:ok, Enum.flat_map(queries, &(&1 |> rounds_filter(filter) |> Repo.all()))}
    end)
  end

  defp rounds_filter(query, filter) do
    query =
      case Keyword.get(filter, :through) do
        nil -> query
        round -> from m in query, where: m.round <= ^round
      end

    case Keyword.get(filter, :only) do
      nil -> query
      round -> from m in query, where: m.round == ^round
    end
  end

  @doc "The rounds a report has analysis for, ascending. Anybody who may see it."
  def rounds(scope, subject) do
    viewing(scope, subject, fn ->
      queries =
        case subject do
          %Tournament{id: id} ->
            [
              from(m in Move, where: m.tournament_id == ^id),
              from(m in UploadMove, where: m.tournament_id == ^id)
            ]

          %Upload{id: id} ->
            [from(m in UploadMove, where: m.upload_id == ^id)]
        end

      {:ok,
       queries
       |> Enum.flat_map(&Repo.all(from m in &1, distinct: true, select: m.round))
       |> Enum.uniq()
       |> Enum.sort()}
    end)
  end

  # --- rounds on demand --------------------------------------------------------

  @doc "The rounds of a tournament that have games on the box. Owner only."
  def played_rounds(scope, %Tournament{} = tournament) do
    owning(scope, tournament, fn -> {:ok, Games.rounds(tournament.id)} end)
  end

  @doc """
  Has every game of a round of a tournament analysed again, or for the
  first time: a round played while fair play was off, before the engine was
  installed, or whose queue was full. What is already analysed with this
  engine stays (`Alnasl.FairPlay.Analysis` reuses it), so this only costs
  what is missing. The games go through the live queue, behind the live
  games. Owner only, in a hall where fair play works.

  `{:ok, games_queued}`, `{:error, :not_working}` or `{:error, :forbidden}`.
  """
  def analyse_round(scope, %Tournament{} = tournament, round) when is_integer(round) do
    owning(scope, tournament, fn ->
      if working?(settings_for_tournament(tournament)) do
        games = tournament.id |> Games.all(round) |> Enum.filter(&Games.begun?/1)
        Enum.each(games, &Queue.enqueue({:game, &1.id}))

        audit(scope, ids(tournament), "analyse_round",
          round: round,
          detail: "#{length(games)} games"
        )

        {:ok, length(games)}
      else
        {:error, :not_working}
      end
    end)
  end

  # --- retention ---------------------------------------------------------------

  @doc """
  How long a report is kept beyond the usual, if the owner said so:
  `%{keep_until, reason, set_by}` or `nil`. An upload attached to a
  tournament is kept as long as the tournament: `{:ok, :with_tournament}`.
  Owner only.
  """
  def keep(scope, subject) do
    owning(scope, subject, fn ->
      case subject do
        %Tournament{id: id} ->
          {:ok, Repo.get_by(Keep, tournament_id: id)}

        %Upload{tournament_id: tid} when is_integer(tid) ->
          {:ok, :with_tournament}

        %Upload{keep_until: nil} ->
          {:ok, nil}

        %Upload{} = u ->
          {:ok, %{keep_until: u.keep_until, reason: u.keep_reason, set_by: u.keep_set_by}}
      end
    end)
  end

  @doc """
  Keeps a report's analysis until `days` days after its last round (an
  upload: after it was uploaded; `Alnasl.FairPlay.Retention.last_round_end/1`),
  at most 365, for a reason that must be written. Owner only.
  `{:error, :reason}` for an empty reason, `{:error, :too_long}` for more
  than 365 days, `{:error, :no_rounds}` when the tournament has no game to
  count from, `{:error, :attached}` for an upload that lives as long as its
  tournament.
  """
  @spec extend(struct() | nil, struct(), integer(), String.t()) ::
          {:ok, struct()}
          | {:error, :forbidden | :reason | :too_long | :no_rounds | :days | :attached}
  def extend(scope, subject, days, reason) do
    cond do
      not owner_of?(scope, subject) ->
        {:error, :forbidden}

      not is_integer(days) or days < 1 ->
        {:error, :days}

      days > @max_keep_days ->
        {:error, :too_long}

      String.trim(to_string(reason)) == "" ->
        {:error, :reason}

      true ->
        keep_until(scope, subject, days, String.trim(to_string(reason)))
    end
  end

  @doc """
  Deletes a tournament's analysis on request, and keeps a frozen copy of
  what the report said first: the players and their numbers, who deleted it,
  when, and why if a reason was given (`Alnasl.FairPlay.Snapshot`). The copy
  is the owner's alone and lives as long as the report would have; the audit
  says it was deleted. Games analysed again afterwards (a changed move, a
  round asked for) make a new analysis. Owner only.

  `{:ok, snapshot}`, `{:error, :forbidden}`, or `{:error, :nothing}` when
  there is no analysis to delete.
  """
  def delete_analysis(scope, %Tournament{} = tournament, reason \\ nil) do
    owning(scope, tournament, fn ->
      {:ok, rows} = moves(scope, tournament)

      if rows == [] do
        {:error, :nothing}
      else
        model = Report.model(settings_for_tournament(tournament))
        user = scope.user
        hall_id = Halls.of(tournament)
        reason = reason |> to_string() |> String.trim() |> String.slice(0, 1000)

        snapshot =
          Repo.insert!(%Snapshot{
            hall_id: hall_id,
            tournament_id: tournament.id,
            title: Tournaments.title(tournament),
            deleted_by: user && user.email,
            deleted_by_id: user && user.id,
            deleted_at: DateTime.utc_now(:second),
            reason: reason,
            moves: length(rows),
            report: rows |> Report.build(model) |> Enum.map(&frozen/1) |> Jason.encode!()
          })

        id = tournament.id
        Repo.delete_all(from m in Move, where: m.tournament_id == ^id)
        Repo.delete_all(from m in UploadMove, where: m.tournament_id == ^id)

        audit(scope, ids(tournament), "delete_analysis",
          detail: "#{length(rows)} moves" <> if(reason != "", do: ": #{reason}", else: "")
        )

        {:ok, snapshot}
      end
    end)
  end

  @doc "The frozen copies of a tournament's deleted analyses, newest first. Owner only."
  def snapshots(scope, %Tournament{id: id} = tournament) do
    owning(scope, tournament, fn ->
      {:ok, Repo.all(from s in Snapshot, where: s.tournament_id == ^id, order_by: [desc: s.id])}
    end)
  end

  # A report line as plain JSON: atoms as words, the interval as a list.
  defp frozen(player) do
    Map.new(player, fn {key, value} -> {to_string(key), jsonable(value)} end)
  end

  defp jsonable(value) when is_boolean(value) or is_nil(value), do: value
  defp jsonable(value) when is_atom(value), do: Atom.to_string(value)
  defp jsonable(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&jsonable/1)
  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)

  defp jsonable(%{} = value) when not is_struct(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), jsonable(v)} end)

  defp jsonable(value) when is_number(value) or is_binary(value), do: value
  defp jsonable(value), do: inspect(value)

  defp keep_until(scope, %Tournament{} = tournament, days, reason) do
    case Retention.last_round_end(tournament.id) do
      nil ->
        {:error, :no_rounds}

      ended ->
        keep =
          Repo.get_by(Keep, tournament_id: tournament.id) ||
            %Keep{tournament_id: tournament.id}

        keep
        |> Keep.changeset(%{
          keep_until: DateTime.add(ended, days * 86_400, :second),
          reason: reason,
          set_by: scope.user && scope.user.email
        })
        |> Repo.insert_or_update()
    end
  end

  defp keep_until(_scope, %Upload{tournament_id: tid}, _days, _reason) when is_integer(tid),
    do: {:error, :attached}

  defp keep_until(scope, %Upload{} = upload, days, reason) do
    upload
    |> Ecto.Changeset.change(
      keep_until: DateTime.add(upload.inserted_at, days * 86_400, :second),
      keep_reason: String.slice(reason, 0, 1000),
      keep_set_by: scope.user && scope.user.email
    )
    |> Repo.update()
  end
end
