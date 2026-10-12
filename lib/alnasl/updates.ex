defmodule Alnasl.Updates do
  @moduledoc """
  Whether a newer Alnasl is out, and - only when the arbiter says so -
  getting it.

  ## What it does by itself: one small question

  Every half hour (`Alnasl.Updates.Checker`) the box asks GitHub for the
  latest release of this program: one request, a few kilobytes, with the
  ETag of the last answer so that "nothing changed" costs nothing. That is
  all it ever does unasked. Offline, a timeout and GitHub's rate limit are
  the same answer - nothing to show - and none of them is an error an
  arbiter has to read in the middle of a round.

  The question itself is a setting (`update_check`: `"ask"` or `"never"`,
  Setup > Updates). There is no third value: nothing is ever installed
  without a person saying yes.

  ## What it does when told to

  The hall may be on a phone's hotspot, and the boards are being read. So
  the notice says how big the download is before anything is fetched, and
  `apply/1` refuses while a board has a game in progress - an update stops
  the program for about a minute, and the moves played in that minute are
  not read. The refusal can be overridden, by a second, explicit yes
  (`force: true`), and by nothing else.

  How it is applied depends on how the program was installed
  (`install_kind/0`):

    * `:velopack` - the Windows installer. This program stops with exit code
      90; `rel/windows/launcher.c`, which started it, sees that code,
      asks Velopack for the update, and starts the new version - or the old
      one again when anything at all went wrong.
    * `:systemd` - the Linux installer. This program writes the version it
      wants into a file; a systemd path unit sees the file and runs
      `/opt/alnasl/update.sh` as root, which downloads, verifies, switches
      and restarts - or switches back.
    * `:manual` - a portable zip, a checkout. The notice says what to do.

  Neither the data directory nor anything in it is part of an update on
  either road; see `Alnasl.DataHome`.
  """

  require Logger

  alias Alnasl.{Boards, Paths, Settings}
  alias Alnasl.Updates.Checker

  @repo "AuroraRyunix/Alnasl"
  @latest_url "https://api.github.com/repos/#{@repo}/releases/latest"
  @releases_page "https://github.com/#{@repo}/releases"
  @user_agent "Alnasl-UpdateCheck"

  # The code rel/windows/launcher.c waits for (ALNASL_UPDATE_EXIT_CODE
  # there). Two files that cannot share a constant share a comment.
  @update_exit_code 90

  @topic "updates"

  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(Alnasl.PubSub, @topic)
  def releases_page, do: @releases_page
  def update_exit_code, do: @update_exit_code

  @doc "The version that is running."
  def current_version, do: to_string(Application.spec(:alnasl, :vsn))

  # --- the setting ---------------------------------------------------------------

  @doc "`\"ask\"` (look, and say so when there is one) or `\"never\"`."
  def mode do
    case Settings.get("update_check") do
      "never" -> "never"
      _ask -> "ask"
    end
  end

  def put_mode(mode) when mode in ["ask", "never"] do
    Settings.put("update_check", mode)
    broadcast()
  end

  @doc "\"Later\": the notice stays away until tomorrow, for this version."
  def later(version) when is_binary(version) do
    until = System.os_time(:second) + 20 * 3600
    Settings.put("update_later", %{"version" => version, "until" => until})
    broadcast()
  end

  defp snoozed?(version) do
    case Settings.get("update_later") do
      %{"version" => ^version, "until" => until} when is_integer(until) ->
        System.os_time(:second) < until

      _other ->
        false
    end
  end

  # --- what the site shows -------------------------------------------------------

  @doc """
  The newer release the checker knows of, or `nil`: `%{version, tag, url,
  size, asset}` with `size` the bytes of what this installation would
  download (`nil` when the release does not say).
  """
  def available, do: Checker.current()

  @doc "What the banner on every page shows, or `nil`: not when switched off, not when put off until later."
  def notice do
    with "ask" <- mode(),
         %{version: version} = info <- available(),
         false <- snoozed?(version) do
      info
    else
      _nothing -> nil
    end
  end

  @doc "Tells every open page to look at `notice/0` again."
  def broadcast, do: Phoenix.PubSub.broadcast(Alnasl.PubSub, @topic, :update_changed)

  # --- asking GitHub -------------------------------------------------------------

  @doc """
  One conditional request for the latest release.

    * `{:ok, info, etag}` - a newer release than this program
    * `{:current, etag}` - reached GitHub; nothing newer
    * `:not_modified` - the answer of `etag` still stands
    * `:error` - offline, a timeout, a refusal, an answer that makes no
      sense. Logged at debug level and nowhere else.
  """
  def check(etag \\ nil) do
    headers =
      [{"accept", "application/vnd.github+json"}, {"user-agent", @user_agent}] ++
        if(etag, do: [{"if-none-match", etag}], else: [])

    # Not `Alnasl.Http.request/1`: the tests' stand-in for the results
    # server would answer for GitHub.
    request =
      [url: @latest_url, headers: headers, receive_timeout: 10_000, retry: false]
      |> Keyword.merge(Application.get_env(:alnasl, :updates_req_options, []))
      |> Req.new()

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: %{"tag_name" => tag} = release} = response} ->
        read_release(tag, release, List.first(Req.Response.get_header(response, "etag")))

      {:ok, %Req.Response{status: 304}} ->
        :not_modified

      {:ok, %Req.Response{status: status}} ->
        # 404 is a repository without a release; 403 and 429 are the rate
        # limit every unauthenticated caller shares. None is news.
        Logger.debug("Update check: GitHub answered #{status}")
        :error

      {:error, reason} ->
        Logger.debug("Update check: #{inspect(reason)}")
        :error
    end
  end

  defp read_release(tag, release, etag) do
    with false <- release["draft"] == true or release["prerelease"] == true,
         {:ok, version} <- Version.parse(String.trim_leading(to_string(tag), "v")),
         {:ok, current} <- Version.parse(current_version()) do
      if Version.compare(version, current) == :gt do
        asset = asset_for(release["assets"], to_string(version))

        {:ok,
         %{
           version: to_string(version),
           tag: tag,
           url: release["html_url"] || "#{@releases_page}/tag/#{tag}",
           asset: asset && asset["name"],
           size: asset && asset["size"]
         }, etag}
      else
        {:current, etag}
      end
    else
      _unusable ->
        Logger.debug("Update check: a release that cannot be read (#{inspect(tag)})")
        :error
    end
  end

  # The file this installation would fetch, to say its size before asking.
  # Velopack may fetch a smaller delta instead; the full package is the
  # honest upper bound.
  defp asset_for(assets, version) when is_list(assets) do
    name = asset_name(install_kind(), version)
    Enum.find(assets, &(is_map(&1) and &1["name"] == name and is_integer(&1["size"])))
  end

  defp asset_for(_none, _version), do: nil

  @doc "The release asset an installation of `kind` downloads for `version`."
  def asset_name(:velopack, version), do: "#{Alnasl.DataHome.pack_id()}-#{version}-full.nupkg"

  def asset_name(_kind, _version) do
    case :os.type() do
      {:win32, _} -> "alnasl-windows-x86_64-portable.zip"
      _unix -> "alnasl-linux-#{arch()}.tar.gz"
    end
  end

  @doc "`x86_64` or `aarch64`, as the release assets are named."
  def arch do
    architecture = to_string(:erlang.system_info(:system_architecture))

    cond do
      String.starts_with?(architecture, ["aarch64", "arm64"]) -> "aarch64"
      true -> "x86_64"
    end
  end

  # --- how this copy was installed -----------------------------------------------

  @doc """
  `:velopack`, `:systemd` or `:manual` - see the moduledoc. Both installers
  say who they are in `ALNASL_UPDATER` (the launcher, the unit); the layout
  on disk is checked as well, so that a copied folder or a hand-set variable
  does not offer a button that cannot work.
  """
  def install_kind do
    case Application.get_env(:alnasl, :install_kind) do
      nil -> detect_kind()
      kind when kind in [:velopack, :systemd, :manual] -> kind
    end
  end

  defp detect_kind do
    case System.get_env("ALNASL_UPDATER") do
      "velopack" -> if velopack_layout?(), do: :velopack, else: :manual
      "systemd" -> if File.dir?(request_dir()), do: :systemd, else: :manual
      _none -> :manual
    end
  end

  # <install root>\current\ is the release, <install root>\Update.exe is
  # Velopack's. Anything else is not an installation Velopack can update.
  defp velopack_layout? do
    with root when is_binary(root) <- System.get_env("RELEASE_ROOT"),
         expanded = Path.expand(root),
         "current" <- Path.basename(expanded) do
      File.exists?(Path.join(Path.dirname(expanded), "Update.exe"))
    else
      _other -> false
    end
  end

  # --- games that an update would interrupt --------------------------------------

  @doc """
  The boards an update would interrupt: connected, in a game with moves and
  without a result. `[%{board_no, table_no, round}]`.
  """
  def games_in_progress do
    for board <- Boards.snapshots(),
        board.running?,
        board.game_status == "live",
        board.plies != [],
        board.result in [nil, "*"] do
      %{board_no: board.board_no, table_no: board.table_no, round: board.round}
    end
  end

  # --- applying ------------------------------------------------------------------

  @doc """
  Downloads and installs the update the checker found, and restarts.

    * `{:error, :nothing}` - no newer release is known
    * `{:error, :manual}` - this copy cannot update itself
    * `{:error, {:games, boards}}` - games are in progress and `force: true`
      was not given
    * `:ok` - under way. The program stops shortly; the page reconnects to
      whatever comes back.
  """
  def apply(opts \\ []) do
    kind = install_kind()
    games = if opts[:force], do: [], else: games_in_progress()

    case {available(), kind, games} do
      {nil, _kind, _games} ->
        {:error, :nothing}

      {_info, :manual, _games} ->
        {:error, :manual}

      {_info, _kind, [_ | _] = boards} ->
        {:error, {:games, boards}}

      {info, kind, []} ->
        Alnasl.Log.add(:info, "update.requested", %{
          version: info.version,
          forced: opts[:force] == true
        })

        hand_over(kind, info)
    end
  end

  # Velopack: stop, cleanly - `System.stop/1` takes the supervision tree
  # down in order, so the database is closed before any file is swapped -
  # and let the launcher do the rest. A moment first, so the page that asked
  # can still be told.
  defp hand_over(:velopack, _info) do
    stop = Application.get_env(:alnasl, :updates_stop_fun, &System.stop/1)

    Task.Supervisor.start_child(Alnasl.TaskSupervisor, fn ->
      Process.sleep(Application.get_env(:alnasl, :updates_stop_delay, 500))
      stop.(@update_exit_code)
    end)

    :ok
  end

  # systemd: the version, in a file that a path unit watches. The file says
  # which version and nothing else; update.sh takes it for a version number
  # or not at all.
  defp hand_over(:systemd, info) do
    dir = request_dir()

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(Path.join(dir, "request"), info.version <> "\n") do
      :ok
    else
      {:error, reason} -> {:error, {:request, reason}}
    end
  end

  @doc "Where the Linux installation leaves its request for the updater."
  def request_dir, do: Path.join(Paths.data(), "update")

  @doc """
  What the Linux updater said about its last run, or `nil`: `{:ok,
  version}` or `{:failed, version, words}`. It writes one line to the file
  the unit names in `ALNASL_UPDATE_STATUS`.
  """
  def last_result do
    path =
      Application.get_env(:alnasl, :update_status_file) || System.get_env("ALNASL_UPDATE_STATUS")

    with path when is_binary(path) <- path,
         {:ok, text} <- File.read(path),
         [word, version | rest] <- text |> String.trim() |> String.split(" ", parts: 3) do
      case word do
        "ok" -> {:ok, version}
        "failed" -> {:failed, version, List.first(rest) || ""}
        _other -> nil
      end
    else
      _none -> nil
    end
  end
end
