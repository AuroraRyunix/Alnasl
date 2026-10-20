defmodule Alnasl.FairPlay do
  @moduledoc """
  Fair-play screening, as the rest of Alnasl meets it (`docs/plan-fair-play.md`).
  The statistics, the engine and the move selection are in
  `Alnasl.FairPlay.*` (the core); this module is the door: a hall's
  settings, installing its engine, being told that a game changed, the
  audit of who opened a report, and the owner's extension of retention.

  **Every function that reads or changes something of a hall's fair play
  takes a scope first and asks `Alnasl.FairPlay.Access.owner?/2`**, and
  answers `{:error, :forbidden}` to anybody else. The one exception is
  `game_changed/1`, which is the tracker's side of the door: it carries a
  game id, reads nothing back, and never blocks.

  ## Where the numbers come from

  `engine_count/0` is how many engines the live queue may run at once:
  `ALNASL_FAIR_PLAY_ENGINES`, else one on the hosted server, else the
  machine's schedulers less one (at least one). `retention_days/0` is
  `ALNASL_FAIR_PLAY_RETENTION_DAYS`, thirty unless told otherwise.
  """

  import Ecto.Query

  alias Alnasl.{Halls, Repo, Tournaments}
  alias Alnasl.FairPlay.{Access, Engines, Installer, Keep, Move, Pool, Queue, Setting, View}
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
  @spec game_changed(%{id: integer()}) :: :ok
  def game_changed(%{id: id}) when is_integer(id), do: Queue.enqueue(id)
  def game_changed(_other), do: :ok

  # --- the owner's pages -------------------------------------------------------

  @doc "The tournaments of a hall, newest first. Owner only."
  @spec tournaments(struct() | nil, integer()) :: {:ok, [struct()]} | {:error, :forbidden}
  def tournaments(scope, hall_id) do
    if Access.owner?(scope, hall_id) do
      own = Halls.own_id()

      {:ok,
       Repo.all(
         from t in Tournament,
           where: t.hall_id == ^hall_id or (is_nil(t.hall_id) and ^(hall_id == own)),
           order_by: [desc: t.id]
       )}
    else
      {:error, :forbidden}
    end
  end

  @doc """
  A tournament, when the scope may see its fair play (it owns the tournament's
  hall): `{:ok, tournament}`, else `{:error, :forbidden}`. A tournament that
  does not exist is forbidden too, so the answer does not tell which ids are used.
  """
  def tournament(scope, id) do
    with %Tournament{} = tournament <- Tournaments.get(id),
         true <- Access.owner?(scope, Halls.of(tournament)) do
      {:ok, tournament}
    else
      _no -> {:error, :forbidden}
    end
  end

  @doc "The hall a tournament's fair play belongs to."
  def hall_of(%Tournament{} = tournament), do: Halls.of(tournament)

  @doc "Writes down that the scope opened a report (or a player's page) of a tournament."
  @spec record_view(struct() | nil, struct(), integer() | nil, String.t() | nil) ::
          {:ok, struct()} | {:error, :forbidden}
  def record_view(scope, %Tournament{} = tournament, round, player_key) do
    if Access.owner?(scope, Halls.of(tournament)) do
      user = scope.user

      {:ok,
       Repo.insert!(%View{
         tournament_id: tournament.id,
         user_id: user && user.id,
         user_email: user && user.email,
         round: round,
         player_key: player_key,
         at: DateTime.utc_now(:second)
       })}
    else
      {:error, :forbidden}
    end
  end

  @doc "The latest openings of a tournament's reports, newest first. Owner only."
  def views(scope, %Tournament{} = tournament, limit \\ 20) do
    if Access.owner?(scope, Halls.of(tournament)) do
      {:ok,
       Repo.all(
         from v in View,
           where: v.tournament_id == ^tournament.id,
           order_by: [desc: v.at, desc: v.id],
           limit: ^limit
       )}
    else
      {:error, :forbidden}
    end
  end

  @doc "The rows of a tournament's analysis, `rounds` limiting them (`nil`: all). Owner only."
  def moves(scope, %Tournament{} = tournament, filter \\ []) do
    if Access.owner?(scope, Halls.of(tournament)) do
      query =
        from m in Move, where: m.tournament_id == ^tournament.id, order_by: [m.game_id, m.ply]

      query =
        case Keyword.get(filter, :through) do
          nil -> query
          round -> from m in query, where: m.round <= ^round
        end

      query =
        case Keyword.get(filter, :only) do
          nil -> query
          round -> from m in query, where: m.round == ^round
        end

      {:ok, Repo.all(query)}
    else
      {:error, :forbidden}
    end
  end

  @doc "The rounds a tournament has analysis for, ascending. Owner only."
  def rounds(scope, %Tournament{} = tournament) do
    if Access.owner?(scope, Halls.of(tournament)) do
      {:ok,
       Repo.all(
         from m in Move,
           where: m.tournament_id == ^tournament.id,
           distinct: true,
           select: m.round,
           order_by: m.round
       )}
    else
      {:error, :forbidden}
    end
  end

  # --- retention ---------------------------------------------------------------

  @doc "The keep of a tournament, if the owner set one. Owner only."
  def keep(scope, %Tournament{} = tournament) do
    if Access.owner?(scope, Halls.of(tournament)) do
      {:ok, Repo.get_by(Keep, tournament_id: tournament.id)}
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Keeps a tournament's analysis until `days` days after its last round
  (`Alnasl.FairPlay.Retention.last_round_end/1`), at most 365, for a reason
  that must be written. Owner only. `{:error, :reason}` for an empty reason,
  `{:error, :too_long}` for more than 365 days, `{:error, :no_rounds}` when
  the tournament has no game to count from.
  """
  @spec extend(struct() | nil, struct(), integer(), String.t()) ::
          {:ok, struct()} | {:error, :forbidden | :reason | :too_long | :no_rounds | :days}
  def extend(scope, %Tournament{} = tournament, days, reason) do
    cond do
      not Access.owner?(scope, Halls.of(tournament)) ->
        {:error, :forbidden}

      not is_integer(days) or days < 1 ->
        {:error, :days}

      days > @max_keep_days ->
        {:error, :too_long}

      String.trim(to_string(reason)) == "" ->
        {:error, :reason}

      true ->
        case Alnasl.FairPlay.Retention.last_round_end(tournament.id) do
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
  end
end
